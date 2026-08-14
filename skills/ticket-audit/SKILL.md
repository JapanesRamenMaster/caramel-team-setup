---
name: ticket-audit
version: 1.0.0
description: |
  구독 고객의 세차권 이용내역 + 결제 패턴 조회 및 이상 원인 분석.
  전화번호 입력 → 구독별 세차권 발급/사용 타임라인 + 결제 타임라인 + 교차검증 + 원인 분석.
  세차권 소실, 결제 금액이 매달 다름, 특정 월 결제 누락, 일시정지/해지 혼동을 다룬다.
  Use when: "세차권 확인", "티켓 조회", "구독 이용내역", "세차권 소실", "결제 패턴", "왜 이렇게 결제됐지", "구독 해지했다는데", "ticket audit".
allowed-tools:
  - Read
  - Bash
  - Grep
  - AskUserQuestion
---

# /ticket-audit — 구독 세차권 이용내역 조회 및 소실 분석

구독 고객의 세차권 발급/사용 타임라인을 정리하고, 교차검증으로 소실을 자동 탐지하며, 원인을 분석한다.

## 입력

- 인자로 전화번호를 받는다 (예: `/ticket-audit 010-1234-5678`)
- 인자가 없으면 AskUserQuestion으로 전화번호를 요청한다

## DB 쿼리 방법

- `./mysql-query.sh "SQL"` 로 실행 (워크스페이스 루트 기준)
- cs-team-setup에서 실행 시: 같은 디렉토리에 `mysql-query.sh` 있음
- DateTime은 UTC 저장 → KST 변환 필수 (`+ INTERVAL 9 HOUR`)
  - 🔴 **`subscription.ended_at`·`paused_at`도 UTC다 — 반드시 변환할 것 (2026-08-14 실측으로 교정).** 이전 버전은 "이미 KST라 변환하지 말 것"이라고 안내했고, 그건 **틀렸다.**
    - 근거 ① `paused_at` raw 시각 분포(257건): 피크 **03~04시**, 최저 **16~20시(0~1건)**. raw가 KST면 "새벽 3시에 구독 정지를 제일 많이 누른다"가 되어 비현실 → +9h면 **12~13시 피크**로 정상.
    - 근거 ② `ended_at` raw 시:분: **`15:00` 1,134건** + `14:59` 119건 = KST 자정/23:59를 UTC로 저장한 지문.
    - 🔴 **영향이 시각에서 안 끝난다.** `ended_at` raw `2026-12-05 15:00`은 실제 **12/06 00:00 KST**다. 변환 없이 읽으면 **다음 결제일을 하루 앞당겨 안내**하게 된다.
  - 시각을 고객에게 안내할 땐 `DATE_FORMAT(col + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i')` 문자열로 뽑을 것 — 컬럼을 그냥 SELECT하면 헬퍼 JSON이 9시간 어긋나게 렌더한다.

## 분석 프로토콜 (5단계 — 순서대로 실행, 생략 불가)

### Step 1: 고객 식별

```sql
SELECT u.id, u.name, u.phone,
       DATE_FORMAT(u.created_at + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS created_kst,
       u.utm_source,
       (SELECT COUNT(*) FROM payment  WHERE user_id = u.id AND status = 'PAID') AS pay_cnt,
       (SELECT COUNT(*) FROM reservation   WHERE user_id = u.id) AS resv_cnt,
       (SELECT COUNT(*) FROM user_service  WHERE user_id = u.id AND deleted_yn = 0) AS us_cnt
FROM app_user u
WHERE REPLACE(u.phone, '-', '') = REPLACE('{phone}', '-', '')
  AND u.deleted_yn = 0 AND u.test_yn = 0 AND u.temp_yn = 0
ORDER BY pay_cnt DESC, u.id DESC;
```

- 결과 없으면: "해당 전화번호의 고객을 찾을 수 없습니다" 안내 후 종료 (하이픈은 위 `REPLACE`가 이미 흡수하므로 재시도 불필요)
- 🔴 **`phone`은 UNIQUE가 아니다 — 여러 행이 나오면 아무거나 고르지 말 것 (2026-08-14 실측).** 재가입·현장 중복가입으로 한 번호에 계정이 쌓인다. 중복 대부분은 `deleted_yn=1`이라 위 필터로 걸러지지만, **필터를 통과하고도 계정이 2개 이상인 번호가 69개**이고 **그중 36개는 결제·예약이 두 계정에 실제로 갈라져 있다.** 한쪽만 보면 이력이 반토막 난다.
  - ⟹ 위 쿼리의 `pay_cnt`/`resv_cnt`/`us_cnt`로 **활동이 있는 계정**을 고른다.
  - ⟹ **여러 계정에 활동이 흩어져 있으면 합쳐서 본다** — `WHERE user_id IN (…전부…)`. 한 사람인데 계정만 갈린 것이므로 한쪽만 보면 이력이 반토막 난다.
  - ⟹ 보고 시 **"계정 N개 존재"를 반드시 명시**한다. CS가 어드민에서 다른 계정을 보고 있을 수 있다.
- 확정한 user_id(들)를 기억 — 이후 모든 쿼리에 사용

### Step 2: 구독 이력 조회

```sql
SELECT
  s.id AS subscription_id,
  p.name AS product_name,
  s.status,
  DATE_FORMAT(s.started_at + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS started_kst,
  DATE_FORMAT(s.ended_at   + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS next_billing_kst,  -- ⚠️해지일 아님 = 다음 결제일
  DATE_FORMAT(s.stopped_at + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS stopped_kst,       -- 실제 해지일
  DATE_FORMAT(s.paused_at  + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS paused_kst,
  s.period, s.period_unit,
  pr.offer_kind,   -- CATALOG=일반상품 / CUSTOM_PAYMENT_LINK=영업이 만든 전용 링크
  c.plate_number
FROM subscription s
JOIN product pr ON s.product_id = pr.id
LEFT JOIN car c ON s.represent_car_id = c.id
WHERE s.user_id IN ({user_ids})
ORDER BY s.started_at DESC;
```

- 구독이 없으면: "구독 이력이 없습니다. 단건 세차 이용 고객입니다." 안내 후 종료
- 모든 상태(ACTIVE, STOPPED, ENDED, CREATED) 포함 — 과거 구독도 소실 분석 대상
- 🔴 **`status='ACTIVE'` + `paused_at IS NOT NULL` = 해지가 아니라 일시정지다.** `PAUSED`라는 status 값은 존재하지 않으므로 status만 보면 구분이 안 된다. **"해지했다"고 안내하면 오답** — 실사례로 영업이 해지로 오독한 건이 있었다. 일시정지는 결제만 멈춘 상태이고 `next_billing_kst`에 자동 재개된다.
- 🔑 `offer_kind='CUSTOM_PAYMENT_LINK'`면 카탈로그 상품이 아니라 **영업이 그 고객만 위해 만든 전용 결제링크 구독**이다(상품명이 `[카라멜] OOO님 결제링크` 형태). 정가·플랜 비교 대상이 없으므로 "왜 이 가격인가"는 DB가 아니라 영업 담당자에게 물어야 한다.

### Step 2.5: 구독별 결제 내역 (기대 세차권 수 산출용)

```sql
SELECT
  p.subscription_id,
  p.id AS payment_id,
  p.amount,
  IFNULL(p.cancel_amount, 0) AS cancel_amount,
  p.status,
  DATE_FORMAT(p.created_at + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS paid_kst
FROM payment p
WHERE p.user_id IN ({user_ids})
  AND p.subscription_id IS NOT NULL
  AND p.deleted_yn IS NOT TRUE
  AND p.status = 'PAID'
ORDER BY p.subscription_id, p.created_at;
```

**기대 세차권 수 계산**:
- 상품명에서 횟수를 추출한다: "월 4회(외부만)" → 4, "월 2회(외부만)" → 2
- 기대 세차권 = 결제 횟수 × 회당 세차권 수
- 예: 월4회 상품 결제 2회 = 8장, 월2회 상품 결제 2회 = 4장

### Step 2.6: 결제가 이상해 보일 때만 — 3갈래 진단 (2026-08-14 신설)

"왜 이렇게 결제됐냐"류 질문이면 여기까지 본다. **이 3개는 각각 다른 테이블이 정본이고, `payment`만 보면 전부 알 수 없다.**

**(a) 금액이 매달 다르다 → 가격 변경 아니라 포인트 상계**
```sql
SELECT DATE_FORMAT(up.updated_at + INTERVAL 9 HOUR, '%Y-%m-%d') AS burned_kst,
       SUM(up.point) AS points_burned
FROM user_point up
WHERE up.user_id IN ({user_ids}) AND up.left_point = 0 AND up.deleted_yn = 0
GROUP BY burned_kst ORDER BY burned_kst;
```
결제일과 같은 날 소진된 포인트 합 = 그 결제의 차감액. `정가 − 포인트 = payment.amount`가 맞아떨어지면 확정.
⚠️ `user_point_history`엔 `type` 컬럼이 **없다**. 적립 원천은 만료 유무로 갈린다 — 리뷰 리워드 3,000원(만료 있음) / 세차권 티어 차액 6,000원(만료 NULL).

**(b) 특정 월 결제가 통째로 없다 → 실패가 아니라 대개 일시정지**
```sql
SELECT cp.payment_id, cp.amount, cp.status, cp.fail_reason,
       DATE_FORMAT(cp.created_at + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS tried_kst
FROM card_payment cp
WHERE cp.subscription_id IN ({subscription_ids}) ORDER BY cp.id;
```
- **row 자체가 없는 달 = 청구를 시도조차 안 한 것.** 실패라면 row가 남고 `fail_reason`이 채워진다.
- 미시도의 원인 = 일시정지가 `ended_at`(다음 결제일)을 밀었기 때문. **정지 기간 = (밀린 `ended_at` 차이) ÷ `period`**, 고객이 앱에서 1~4주기를 직접 고른다.
- ⚠️ `card_payment.status`는 **소문자 `'paid'`** (`payment`는 대문자 `'PAID'`).

**(c) 과거에 일시정지한 적 있나 → 현재 행엔 안 남는다**
```sql
SELECT record_id, old_value, new_value, type, created_by,
       DATE_FORMAT(created_at + INTERVAL 9 HOUR, '%Y-%m-%d %H:%i') AS changed_kst
FROM log
WHERE table_name = 'subscription' AND column_name = 'ended_at'
  AND record_id IN ({subscription_ids}) ORDER BY id;
```
- 재개하면 `paused_at`이 NULL로 덮이므로 **과거 정지 이력은 이 로그가 유일**하다. `type='USER'`면 고객 본인이 누른 것.
- 🔴 **단, 이 로그는 2026-06에 사실상 죽었다** (월별 04:519 → 05:191 → 06:13 → 07:4). **"로그에 없다 = 정지한 적 없다"가 아니다.** 2026-06 이후 구간은 이력이 DB에 없으니 `paused_at`·`ended_at` 현재값에서 역산하고, **모르는 건 모른다고 보고**할 것.

### Step 3: 세차권 사용 내역 (삭제된 것 포함)

```sql
SELECT
  us.id AS user_service_id,
  us.subscription_id,
  us.reservation_id,
  us.used_yn,
  us.deleted_yn,
  us.started_at + INTERVAL 9 HOUR AS issued_kst,
  us.ended_at + INTERVAL 9 HOUR AS used_kst,
  r.status AS reservation_status,
  r.reservation_datetime + INTERVAL 9 HOUR AS reservation_kst,
  r.canceled_at + INTERVAL 9 HOUR AS canceled_kst,
  r.cancel_reason,
  sv.name AS service_name,
  c.plate_number
FROM user_service us
LEFT JOIN reservation r ON us.reservation_id = r.id
LEFT JOIN service sv ON us.service_id = sv.id
LEFT JOIN reservation_car rc ON rc.reservation_id = r.id
LEFT JOIN car c ON rc.car_id = c.id
WHERE us.user_id IN ({user_ids})
  AND us.subscription_id IS NOT NULL
ORDER BY us.subscription_id, us.started_at;
```

**중요**: `deleted_yn = 1`인 레코드도 반드시 포함한다 — 소실 추적에 필수.

### Step 4: 교차검증 (CRITICAL — 절대 생략 불가)

**이 단계를 건너뛰면 안 된다. "정상입니다"라고 먼저 말하지 말 것.**

구독별로 다음을 계산하고 **반드시 명시적으로 보고**:

```
각 구독에 대해:
  기대 발급량 = Step 2.5의 결제 횟수 × 상품명에서 추출한 회차 수
  실제 활성 세차권 = Step 3 결과에서 해당 subscription_id의 user_service 중
                    deleted_yn=0 인 건수
  실제 사용(WASHED/CONFIRMED) = 그 중 reservation.status IN ('WASHED','REPORT_SENT','CONFIRMED')
  취소건 소모 = 그 중 reservation.status = 'CANCELED' AND used_yn=1 AND deleted_yn=0

  IF 기대 발급량 ≠ 실제 활성 세차권 → ⚠️ 불일치
  취소 예약에 묶인 세차권이 있으면 → ⚠️ 추가 플래그
```

**세차권 상태 분류** (user_service 기준):
| deleted_yn | used_yn | reservation.status | 분류 |
|---|---|---|---|
| 0 | 1 | WASHED/REPORT_SENT | ✅ 정상 사용 |
| 0 | 1 | CONFIRMED | 📋 예약 대기 (선불) |
| 0 | 1 | CANCELED | ⚠️ 취소됐는데 세차권 미복원 |
| 0 | 0 | NULL | 💰 미사용 잔여 |
| 1 | * | * | 🗑️ 삭제된 세차권 (소실 후보) |

**규칙**:
- 숫자를 먼저 보여주고, 그 다음 일치/불일치를 판정한다
- 불일치가 없어도 검증 결과를 명시한다
  - 예: "✅ 교차검증 통과: 기대 12장, 활성 12장 (사용 9 + 예약 1 + 미사용 2)"
- 불일치가 있으면 반드시 Step 5로 진행한다
- 삭제된 세차권(deleted_yn=1)이 있으면 항상 별도로 보고한다

### Step 5: 소실 원인 패턴 매칭

불일치 발견 시, Step 3의 데이터를 기반으로 아래 패턴 순서로 원인을 탐색한다:

#### 패턴 1: 취소 예약에 묶인 세차권
- **탐지**: user_service.reservation_id가 있고, 해당 reservation.status = 'CANCELED'
- **세부 확인**: user_service.used_yn=1 (사용처리됨)이면 "취소됐는데 세차권 미복원"
- **설명**: "예약#{id} 취소됐으나 세차권이 복원되지 않음"

#### 패턴 2: 삭제된 세차권
- **탐지**: user_service.deleted_yn = 1 AND subscription_id IS NOT NULL
- **설명**: "세차권(user_service #{id})이 소프트 삭제됨"
- 삭제된 세차권이 있으면 해당 예약 상태도 함께 보고

#### 패턴 3: 구독 해지/만료 시 잔여권 소멸
- **탐지**: subscription.status = 'STOPPED' 또는 'ENDED'
- **설명**: "구독 종료 시점에 남은 세차권이 자동 소멸 (정상 동작)"
- 이 경우 "보상 불필요"로 분류

#### 패턴 4: 세차권 유효기간 만료
- **탐지**: user_service.ended_at이 현재보다 과거이고, 해당 세차권이 미사용 상태였을 것
- **설명**: "세차권 유효기간 만료로 소멸 (정상 동작)"

#### 패턴 5: 원인 불명
- 위 패턴에 해당하지 않는 불일치
- **설명**: "원인 파악 불가 — 개발팀 확인 필요"
- 관련 user_service, reservation 데이터를 모두 나열

---

## 출력 포맷

아래 형식으로 정리하여 출력한다. 이모지는 가독성을 위해 사용.

```
## 고객 정보
이름: {name} | 전화: {phone} | 가입일: {created_at_kst}

## 구독 이력 요약
| # | 상품명 | 상태 | 기간 | 차량 |
|---|--------|------|------|------|
| 1 | {product_name} | ✅ ACTIVE | 2025.01~ | {plate_number} |
| 2 | {product_name} | ⛔ ENDED | 2024.06~12 | {plate_number} |

## 구독별 세차권 상세

### 구독 #{n}: {product_name} ({status})
발급: {total_times} | 사용: {used_count} | 잔여: {left_times}
교차검증: ✅ 일치 ({total_times}-{left_times}={expected}, 실제 {actual}건)
  또는
교차검증: ⚠️ 불일치 ({total_times}-{left_times}={expected}인데 실제 {actual}건, {diff}회 차이)

사용 내역:
| 날짜 | 예약# | 상태 | 서비스 | 차량 | 비고 |
|------|-------|------|--------|------|------|
| 2025-12-28 | 1234 | WASHED | 기본세차 | 12가3456 | |
| 2025-12-15 | 1200 | CANCELED | 기본세차 | 12가3456 | ⚠️ 취소 |

[불일치 시]
소실 원인 분석:
• {N}회: {날짜} {원인 설명}
  └ 근거: {reservation/user_service 상태값}

## 종합 판단
총 소실: {N}회
• 시스템 이슈 (보상 검토 권장): {N}회 — {사유 요약}
• 정상 소멸 (보상 불필요): {N}회 — {사유 요약}
[불일치 없으면]
✅ 모든 구독의 세차권이 정상입니다. 교차검증 통과.
```

---

## 엣지 케이스

- **전화번호 포맷**: 하이픈 유무 모두 시도 (010-1234-5678, 01012345678)
- **구독 없는 고객**: "구독 이력이 없습니다" 안내 후 종료
- **구독은 있지만 사용 0건**: "아직 세차권을 사용하지 않은 구독입니다" 안내
- **다차량/다구독 고객**: 구독별로 분리 분석, 차량 번호로 구분
- 🔴 **구독 일시정지 중** (`status='ACTIVE'` + `paused_at IS NOT NULL`): **"해지"라고 쓰지 말 것.** 결제만 멈춘 상태이고 `ended_at`(다음 결제일)에 자동 재개된다. 정지 시작일과 **재개 예정일을 함께** 안내한다
- **전화번호에 계정이 2개 이상**: 활동 있는 계정을 골라 합산하고, 보고에 "계정 N개 존재"를 명시 (Step 1 참조)
- **결제 금액이 매달 다름 / 특정 월 결제 없음**: Step 2.6으로 갈 것. 각각 포인트 상계·일시정지가 원인인 경우가 대부분이고, 결제 실패로 단정하면 오답
- **상품 변경 고객** (월4회 → 월2회 등): 각 구독 ID를 별도로 분석. 이전 구독이 STOPPED이고 새 구독이 ACTIVE인 패턴
- **subscription_service 비어있음**: 대부분의 구독에서 subscription_service 테이블이 비어있음. 반드시 결제 내역(payment) 기반으로 기대 세차권 수를 산출할 것

## 주의사항

- `reservation.subscription_id`는 98% NULL이므로 구독 여부 판단에 사용하지 말 것
- `user_service.subscription_id`를 사용하여 구독 세차권을 식별할 것
- `subscription_service` 테이블은 대부분 비어있음 — 세차권 추적은 `user_service` + `payment` 기반으로
- 매출/결제 관련 상세 분석은 이 스킬의 범위가 아님 — 결제 건수는 기대 세차권 수 산출 용도로만 사용
- 상품명에서 회차 수 추출 시: "월 4회(외부만)" → 4, "월 2회(외부만)" → 2, "월 8회" → 8 등