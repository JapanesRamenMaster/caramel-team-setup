---
name: ticket-audit
version: 1.0.0
description: |
  구독 고객의 세차권 이용내역 조회 및 소실 원인 분석.
  전화번호 입력 → 구독별 세차권 발급/사용 타임라인 + 교차검증 + 소실 원인 분석.
  Use when: "세차권 확인", "티켓 조회", "구독 이용내역", "세차권 소실", "ticket audit".
allowed-tools:
  - Read
  - Bash
  - Grep
  - AskUserQuestion
scope: team
owner: juseong
side-effects:
  - db-read
tags:
  - 구독
  - 세차권
  - 고객관리
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
  - **예외**: `subscription.ended_at`, `subscription.paused_at`은 이미 KST — 변환하지 말 것

## 분석 프로토콜 (5단계 — 순서대로 실행, 생략 불가)

### Step 1: 고객 식별

```sql
SELECT id, name, phone,
       created_at + INTERVAL 9 HOUR AS created_at_kst
FROM app_user
WHERE phone = '{phone}'
  AND deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0;
```

- 결과 없으면 하이픈 제거 또는 추가하여 재시도 (010-1234-5678 ↔ 01012345678)
- 여전히 없으면: "해당 전화번호의 고객을 찾을 수 없습니다" 안내 후 종료
- user_id를 기억 — 이후 모든 쿼리에 사용

### Step 2: 구독 이력 조회

```sql
SELECT
  s.id AS subscription_id,
  p.name AS product_name,
  s.status,
  s.started_at + INTERVAL 9 HOUR AS started_kst,
  s.ended_at AS ended_kst,
  s.stopped_at + INTERVAL 9 HOUR AS stopped_kst,
  s.paused_at AS paused_kst,
  c.plate_number
FROM subscription s
JOIN product p ON s.product_id = p.id
LEFT JOIN car c ON s.represent_car_id = c.id
WHERE s.user_id = {user_id}
ORDER BY s.started_at DESC;
```

- 구독이 없으면: "구독 이력이 없습니다. 단건 세차 이용 고객입니다." 안내 후 종료
- 모든 상태(ACTIVE, STOPPED, ENDED, CREATED) 포함 — 과거 구독도 소실 분석 대상

### Step 2.5: 구독별 결제 내역 (기대 세차권 수 산출용)

```sql
SELECT
  p.subscription_id,
  p.id AS payment_id,
  p.amount,
  IFNULL(p.cancel_amount, 0) AS cancel_amount,
  p.status,
  p.created_at + INTERVAL 9 HOUR AS paid_kst
FROM payment p
WHERE p.user_id = {user_id}
  AND p.subscription_id IS NOT NULL
  AND p.deleted_yn = 0
  AND p.status = 'PAID'
ORDER BY p.subscription_id, p.created_at;
```

**기대 세차권 수 계산**:
- 상품명에서 횟수를 추출한다: "월 4회(외부만)" → 4, "월 2회(외부만)" → 2
- 기대 세차권 = 결제 횟수 × 회당 세차권 수
- 예: 월4회 상품 결제 2회 = 8장, 월2회 상품 결제 2회 = 4장

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
WHERE us.user_id = {user_id}
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
- **구독 일시정지 중**: paused_at 표시, 정지 상태 명시
- **상품 변경 고객** (월4회 → 월2회 등): 각 구독 ID를 별도로 분석. 이전 구독이 STOPPED이고 새 구독이 ACTIVE인 패턴
- **subscription_service 비어있음**: 대부분의 구독에서 subscription_service 테이블이 비어있음. 반드시 결제 내역(payment) 기반으로 기대 세차권 수를 산출할 것

## 주의사항

- `reservation.subscription_id`는 98% NULL이므로 구독 여부 판단에 사용하지 말 것
- `user_service.subscription_id`를 사용하여 구독 세차권을 식별할 것
- `subscription_service` 테이블은 대부분 비어있음 — 세차권 추적은 `user_service` + `payment` 기반으로
- 매출/결제 관련 상세 분석은 이 스킬의 범위가 아님 — 결제 건수는 기대 세차권 수 산출 용도로만 사용
- 상품명에서 회차 수 추출 시: "월 4회(외부만)" → 4, "월 2회(외부만)" → 2, "월 8회" → 8 등