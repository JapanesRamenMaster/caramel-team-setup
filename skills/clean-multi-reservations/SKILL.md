---
name: clean-multi-reservations
description: |
  동일차량 다중예약 정리. 슬랙 알림 확인 → 취소 대상 분석 → 사용자 승인 후 취소 실행.
  Use when: "다중 예약 정리", "중복 예약 정리", "clean multi", "clean-multi-reservations", "예약 정리".
scope: team
owner: sungjiwon
side-effects:
  - db-write
  - notification
disable-model-invocation: true
tags:
  - 예약
  - 고객관리
allowed-tools:
  - Read
  - Bash
  - Grep
  - Glob
  - AskUserQuestion
  - mcp__claude_ai_Slack__slack_read_channel
  - mcp__claude_ai_Slack__slack_read_thread
  - mcp__claude_ai_Slack__slack_search_public
---

# /clean-multi-reservations — 동일차량 다중예약 정리

매일 18시 `#caramel_세차신청_알림` 채널에 올라오는 예약 이상 감지 알림 중
"동일차량 다중예약"을 확인하고, 불필요한 예약을 분석하여 사용자 승인 후 취소한다.

## 핵심 원칙

- **무단 취소 절대 금지** — 취소 대상을 보고하고 사용자가 승인한 예약만 취소한다
- **고객이 불편하지 않도록** — 고객이 인지하지 못하는 예약(후불, 미노출)을 우선 취소한다
- 취소 사유: `CARAMEL_PROBLEM` + detailReason `"동일 차량 다중 예약"`

---

## 정리 프로토콜 (6단계 — 순서대로 실행, 생략 불가)

### Step 1: 슬랙 메시지 읽기

1. `slack_read_channel`로 채널 `C07V42NDM4Y` (`#caramel_세차신청_알림`)의 최근 메시지를 읽는다
2. "예약 이상 감지 알림"이 포함된 부모 메시지를 찾는다
   - **오늘(KST) 18:00 이후**: 오늘 날짜의 메시지
   - **오늘(KST) 18:00 이전**: 어제 날짜의 메시지
   - 못 찾으면: "알림 메시지를 찾을 수 없습니다" 안내 후 종료
3. `slack_read_thread`로 해당 메시지의 스레드 전체를 읽는다

### Step 2: 동일차량 다중예약만 파싱

스레드 메시지 중 `:car: 동일차량 다중예약`이 포함된 메시지만 추출한다.

**필터링 규칙**:
- `:busts_in_silhouette: 중복 예약` → 무시
- `:clock3: 근무시간 외 예약` → 무시
- `:no_entry: 차단 디테일러 배정` → 무시

**제외 대상 (제휴업체)**:
- 고객명에 다음이 포함되면 제외: **한남 테슬라**, **마이바흐**, **벤틀리**

각 메시지에서 예약ID 목록을 파싱한다.
메시지 형식:
```
:car: *동일차량 다중예약*
동일 차량({차량번호}) 3일 이내 다중 예약 {N}건
- 예약ID: {id} | {MM/DD HH:MM} | 디테일러: {name} | 고객: {name}({phone}) | 차량: {plate}
```

**파싱 결과**: 차량번호별 예약ID 목록을 정리한다.

### Step 3: DB 조회로 추가 정보 수집

#### 3a. 예약 상세 조회

파싱한 전체 예약ID를 한 번에 조회:

```sql
SELECT
  r.id AS reservation_id,
  r.reservation_datetime + INTERVAL 9 HOUR AS reservation_kst,
  r.status,
  r.car_id,
  r.user_id,
  u.name AS customer_name,
  u.phone,
  c.plate_number,
  us.id AS user_service_id,
  us.postpaid_yn,
  us.subscription_id,
  p.name AS product_name,
  (SELECT COUNT(*) FROM user_option uo
   WHERE uo.reservation_id = r.id AND uo.deleted_yn = 0) AS option_count,
  sub_product.name AS subscription_product_name
FROM reservation r
JOIN app_user u ON r.user_id = u.id
LEFT JOIN reservation_car rc ON rc.reservation_id = r.id
LEFT JOIN car c ON rc.car_id = c.id
LEFT JOIN user_service us ON us.reservation_id = r.id AND us.deleted_yn = 0
LEFT JOIN product p ON us.product_id = p.id
LEFT JOIN subscription sub ON us.subscription_id = sub.id
LEFT JOIN product sub_product ON sub.product_id = sub_product.id
WHERE r.id IN ({예약ID_목록})
  AND r.status IN ('CONFIRMED', 'IN_PROGRESS')
  AND r.deleted_yn = 0
```

**확인 사항**:
- `status`가 `CONFIRMED` 또는 `IN_PROGRESS`가 아닌 예약은 이미 처리됨 → 제외
- 제외된 예약이 있으면 "예약ID #{id}는 이미 {status} 상태입니다" 안내

#### 3b. 해당 차량의 향후 전체 예약 조회

슬랙에 표시되지 않은 예약도 있을 수 있으므로, 관련 차량의 전체 향후 예약을 조회:

```sql
SELECT
  r.id AS reservation_id,
  r.reservation_datetime + INTERVAL 9 HOUR AS reservation_kst,
  r.status,
  us.postpaid_yn,
  (SELECT COUNT(*) FROM user_option uo
   WHERE uo.reservation_id = r.id AND uo.deleted_yn = 0) AS option_count
FROM reservation r
LEFT JOIN reservation_car rc ON rc.reservation_id = r.id
LEFT JOIN user_service us ON us.reservation_id = r.id AND us.deleted_yn = 0
WHERE rc.car_id IN ({car_id_목록})
  AND r.status IN ('CONFIRMED', 'IN_PROGRESS')
  AND r.deleted_yn = 0
  AND r.reservation_datetime + INTERVAL 9 HOUR > NOW() + INTERVAL 9 HOUR
ORDER BY r.car_id, r.reservation_datetime
```

### Step 4: 취소 대상 판별

#### 4a. 최소 간격 기준

구독 상품명에서 간격을 결정:

| subscription_product_name 패턴 | 최소 간격 |
|-------------------------------|-----------|
| "월 4회" 포함 | 6일 |
| "월 2회" 포함 | 12일 |
| "월 1회" 포함 | 25일 |
| 그 외 / NULL | 6일 (기본값, 보수적) |

#### 4b. 취소 우선순위

같은 차량의 예약이 최소 간격 미만으로 붙어있을 때, 아래 순서로 취소 대상 결정:

1. **후불 예약 우선 취소** — `postpaid_yn = 1`인 예약은 고객 앱에서 안 보임
2. **옵션/내부세차 없는 예약 취소** — `option_count > 0`이거나 product_name에 "내부"가 포함된 예약은 보존
3. **늦은 날짜 예약 취소** — 가장 빠른(가까운) 예약을 보존 (고객이 인지하고 있을 확률 높음)

#### 4c. 판별 절차

1. 차량별로 모든 향후 예약을 날짜순 정렬
2. 앞에서부터 순서대로 인접 예약 간 간격 체크
3. 간격이 최소 기준 미만인 쌍 발견 시, 위 우선순위에 따라 취소 대상 선정
4. 취소 대상을 제거한 후, 남은 예약 간 간격을 재검증
5. 여전히 위반이 있으면 반복

**판별 시 특수 규칙**:
- 이미 지난 예약(reservation_kst < 현재시각)은 취소 대상에서 제외
- 오늘 예약(reservation_kst의 날짜 = 오늘)은 취소 대상에서 제외 (세차 진행 가능성)
- 내일 예약은 취소 가능하나, 선불이면 고객 인지 가능성이 높으므로 주의 표시

### Step 5: 사용자에게 보고

아래 형식으로 고객별 그룹핑하여 보고:

```
## 동일차량 다중예약 정리 ({알림날짜} 알림 기준)

분석 대상: {N}건 (제외: 제휴업체 {M}건, 이미 처리 {K}건)

---

### {고객명} | {차량번호} | {구독유형} | 최소간격: {N}일

| 예약ID | 날짜 | 유형 | 옵션 | 디테일러 | 판단 |
|--------|------|------|------|---------|------|
| {id} | {MM/DD 요일} | 선불 | ✅ 내부세차 | {name} | ✅ 유지 |
| {id} | {MM/DD 요일} | 후불 | - | {name} | ❌ 취소 (후불, {N}일 간격) |
| {id} | {MM/DD 요일} | 선불 | - | {name} | ✅ 유지 |

→ 취소 대상: #{id} (사유: {사유})

---

### {다음 고객} | ...

---

## 요약

| 고객 | 차량 | 취소 대상 | 사유 |
|------|------|----------|------|
| {고객명} | {차량번호} | #{id} | {사유} |
| {고객명} | {차량번호} | #{id} | {사유} |

총 취소 대상: {N}건
```

**보고 후 AskUserQuestion으로 확인**:
- "전체 실행" — 모든 취소 대상 실행
- "선택 실행" — 특정 예약만 선택하여 실행
- "취소" — 아무것도 실행하지 않음

**사용자가 "취소"하면 즉시 중단.**
**사용자가 특정 예약을 제외하거나 추가하면 반영.**

### Step 6: 승인된 예약 취소 실행

> **중요**: 사용자가 승인한 예약만 취소한다. 승인 없이 실행하면 안 된다.

#### 6a. JWT 토큰 생성

```bash
TOKEN=$(node -e "
const crypto = require('crypto');
const h = Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
const p = Buffer.from(JSON.stringify({sub:'2'})).toString('base64url');
const s = crypto.createHmac('sha256','secret1').update(h+'.'+p).digest('base64url');
console.log(h+'.'+p+'.'+s);
")
```

#### 6b. 예약 취소 (건별 실행)

각 예약에 대해:

```bash
curl -s -X POST \
  'https://gateway-prod.thetrive.com/careplus/reservations-admin/{reservationId}/cancel' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"reason":"CARAMEL_PROBLEM","detailReason":"동일 차량 다중 예약"}'
```

**응답 처리**:
- 200: 성공 → ✅ 표시
- 404: 예약 없음 → ⚠️ "예약을 찾을 수 없습니다" (이미 취소됐을 수 있음)
- 500: 서버 오류 → ❌ 에러 메시지 표시
- 한 건이 실패해도 나머지는 계속 진행

#### 6c. 결과 보고

```
## 취소 결과

| # | 예약ID | 고객 | 차량 | 결과 |
|---|--------|------|------|------|
| 1 | {id} | {고객명} | {차량번호} | ✅ 취소 완료 (세차권 반환) |
| 2 | {id} | {고객명} | {차량번호} | ❌ 실패: {에러메시지} |

성공: {N}건 / 실패: {M}건
```

---

## 엣지 케이스

| 시나리오 | 감지 시점 | 대응 |
|---------|----------|------|
| 알림 메시지 없음 | Step 1 | "알림을 찾을 수 없습니다" 종료 |
| 동일차량 다중예약 0건 | Step 2 | "동일차량 다중예약이 없습니다" 종료 |
| 전부 제휴업체 | Step 2 | "처리할 건이 없습니다" 종료 |
| 예약이 이미 취소됨 | Step 3 | 해당 건 제외 안내 |
| 구독유형 판별 불가 | Step 4 | 기본 6일 적용 + 경고 |
| 모든 예약이 선불 + 옵션 있음 | Step 4 | 자동 판별 어려움 → 사용자에게 선택 요청 |
| API 인증 실패 | Step 6 | 에러 안내 + 수동 취소 방법 제시 |
| 같은 날 같은 시간 2건 | Step 4 | 후불 우선 취소, 둘 다 선불이면 사용자 선택 |

## 주의사항

- `reservation_datetime`은 UTC → KST 변환 필수 (`+ INTERVAL 9 HOUR`)
- `user_service.postpaid_yn`으로 선불/후불 판별
- 옵션 존재 여부는 `user_option` 테이블에서 확인
- 내부세차는 `product.name`에 "내부" 포함 여부로 판별
- DB 쿼리는 `./mysql-query.sh "SQL"` 로 실행 (워크스페이스 루트 기준)
- **DB는 조회(SELECT)만** — UPDATE/DELETE/INSERT 절대 금지
- 예약 취소는 반드시 admin API로 실행
