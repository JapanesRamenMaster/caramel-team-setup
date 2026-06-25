---
entry_id: REFUND-014
title: 웰컴 쿠폰 만료 후 예외 재발급 처리
category: 결제/환불
source_file: 신규-가입-웰컴-쿠폰-안내-및-만료-문의-응대-기준.md
source_section: CS 처리 기준 > 케이스 3: 미수긍 시 예외 재발급
last_verified: 2026-06-25
source_content_hash: 10683de035fe2f4f
---

## 적용 조건 (when_to_use)
1차 재발급 불가 안내 후 고객이 수긍하지 않고 재발급을 재요청하는 경우로, 예외 재발급 조건(예약 이력 없음 + CS 판단 상 합리적 사유) 충족 여부를 확인해야 할 때.

## 비적용 조건 (not_when_to_use)
- ⛔ 1차 안내 단계에서 먼저 이 entry를 사용하는 것은 금지 — 반드시 '웰컴 쿠폰 만료 후 재발급 불가 안내(1차 안내)' entry를 먼저 적용
- ⛔ 고객에게 예약 이력이 1건이라도 있는 경우 (예약건수 > 0이면 재발급 불가, 이 entry 처리 종료)
- ⛔ 구독 상품 쿠폰 적용 문의인 경우 (→ '웰컴 쿠폰 구독 상품 적용 불가 안내' entry 사용)

## 처리 방법
다음 조건 모두 충족 시에만 예외 재발급 가능:
- 예약 이력 없음 (첫 예약 전 고객)
- CS 판단 상 합리적인 사유

예약 이력 확인 방법 (mysql-query.sh):
```sql
SELECT COUNT(*) AS 예약건수
FROM reservation
WHERE user_id = {유저ID}
  AND deleted_yn = 0;
```
→ 예약건수 > 0이면 재발급 불가
재발급 실행: /coupon-grant 스킬 사용

## 주의사항
재발급 시 채널톡 메모에 사유 기록 필수
