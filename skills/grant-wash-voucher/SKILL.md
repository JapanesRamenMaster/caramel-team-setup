---
name: grant-wash-voucher
description: 고객에게 세차권(user_service)을 지급한다. 특히 "티어 상관없는 세차권"(tier_id=null service). 전화번호/userId + 세차권 종류 + 개수를 받아 caramel-api로 발급하고 DB로 검증까지. Use when 사용자가 "세차권 지급", "세차권 넣어줘", "티어 무관 세차권", "외부만 N개 지급", "무료 세차권 지급", "이분한테 세차권" 등을 요청할 때. (tier별 가격 세차권 카탈로그 조회만 필요하면 reference_wash_pass_voucher_catalog / 이용내역 조회는 ticket-audit.)
---

# grant-wash-voucher — 세차권 지급

고객에게 세차권을 `serviceId`로 직접 지급한다. caramel-api 게이트웨이
`POST /careplus/users-admin/{userId}/services {serviceId}` 를 호출한다.
호출 1회 = `user_service` 1행: **ended_at=2999-12-31(무기한), paid_yn=1(무료지만 사용가능), product_id=null(차량 미고정)**.

## 세차권 카탈로그 (tier 무관 = tier_id NULL)

가장 자주 쓰는 tier-무관 세차권. **어느 tier 차량에도 사용 가능**(예약 시 tier 검사 안 함 — cross-tier 소모 실증됨).

| serviceId | 이름 | wash_type | 기본가 | 비고 |
|---|---|---|---|---|
| **135** | 외부만 | OUTSIDE | 37,000 | **기본값. "키 전달 없이 가볍게 외부만"** |
| 1 | 올클린 케어 | BOTH | 60,000 | 내·외부 (외부+내부) — 지급 전 현행 여부 확인 권장 |
| 8 | 내부 디테일링 | INSIDE | 70,000 | 내부만 — 지급 전 현행 여부 확인 권장 |

- **⚠️ "티어 상관없는 외부만" = serviceId 135**. tier별 가격 세차권(car_tier_product의 15/18/21/24/27/30/33)과 별개다. 상세 [[reference_tier_independent_wash_voucher_service135]].
- 135 외의 세차권을 지급할 땐 serviceId를 DB로 먼저 확인:
  `~/claude/mysql-query.sh "SELECT id,name,wash_type,price FROM service WHERE type='CAR_WASH' AND tier_id IS NULL AND deleted_yn=0 ORDER BY id;"`

## 워크플로우

### 1. 고객 식별 (전화번호 → userId)
```bash
~/claude/mysql-query.sh "SELECT id, name, phone FROM app_user WHERE phone IN ('010-1234-5678','01012345678') AND deleted_yn=0 AND test_yn=0 AND temp_yn=0;"
```
- 하이픈 유/무 둘 다 시도. 이미 userId를 받았으면 생략.

### 2. Confirm (prod 고객 쓰기 — 필수)
지급 전 **대상 userId · serviceId · 개수**를 사용자에게 재확인하고 명시적 승인을 받는다.
승인 발화("ㅇㅇ/응/넣어/yes") 없이 실행 금지.

### 3. 지급
```bash
~/claude/scripts/grant-wash-voucher.sh --user <userId> --service 135 --count <N>
```
- `--service` 생략 시 기본 135(외부만). `--count` 생략 시 1.
- `--dry-run` : 로그인·엔드포인트만 확인하고 지급 안 함.
- 결과 JSON(stdout): `{user, service, requested, success, ids[], fails[]}`. 진행 로그는 stderr.

### 4. DB 검증 (지급 후 필수 — "지급했습니다"만 쓰지 말 것)
```bash
~/claude/mysql-query.sh "SELECT COUNT(*) cnt, SUM(paid_yn=1) paid, SUM(used_yn=0) unused, SUM(deleted_yn=0) alive, MIN(ended_at) end FROM user_service WHERE user_id=<userId> AND service_id=<serviceId> AND id >= <첫 us_id>;"
```
- 지급 전 baseline count와 비교해 정확히 N개 늘었는지, paid/unused/alive/무기한 확인.
- 결과를 표로 보고 (userId, serviceId, 개수, us_id 범위, 만료).

## 주의
- **prod 즉시 반영.** 되돌리려면 발급된 us_id를 `deleted_yn=1`로(어드민 API 티켓 수정 경로).
- 인증: `~/.config/caramel/admin.env` (계정 gobul21, CARAMEL_GATEWAY). lms 스킬과 동일.
- 이 엔드포인트는 **caramel-api** 게이트웨이다. zero-api 어드민 헬퍼(`caramel-admin-api.sh`)의 `tickets {productIds}`로는 service 135를 못 넣는다(135는 product 없음).
- 대량(수십 개+) 지급 전 개수·비용 한 번 더 환기.
