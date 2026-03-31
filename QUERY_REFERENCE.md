# Caramel DB 쿼리 레퍼런스

caramel-prod DB 분석 쿼리 시 반드시 따를 규칙. `grafana-audit/CLAUDE.md`와 함께 참조.

## 필터 기준 (Grafana 대시보드와 일치)

### 디테일러
- `detailer.direct_yn = 1 AND detailer.booking_yn = 1`
- `detailer.name != '이상민'` (테스트 계정)
- `detailer_supply_sheet.status = '현직'`은 40명, Grafana 기준(위 조건)은 60명 — **Grafana 기준 사용할 것**
- 두 테이블 JOIN 시 `COLLATE utf8mb4_general_ci` 필수

### 예약 상태
- 세차 완료: `status IN ('WASHED', 'REPORT_SENT')` — 실제 세차가 수행된 건
- 확정 예약(미완료): `CONFIRMED` — 예약은 잡혔지만 아직 세차 전. 파이프라인/수요 분석에 사용
- 완료+확정: `status IN ('WASHED', 'REPORT_SENT', 'CONFIRMED')` — 유효 예약 전체 (취소/미확정 제외)
- `CREATED`는 미확정 예약, `CANCELED`는 취소 — 둘 다 **제외**
- `NOT IN ('CANCELED')` 사용 금지 — CREATED가 포함되어 데이터 왜곡됨

### 시간 변환
- DB는 UTC 저장 → `CONVERT_TZ(reservation_datetime, '+00:00', '+09:00')` 또는 `+ INTERVAL 9 HOUR`
- GROUP BY에 날짜 쓸 때 반드시 KST 변환 후 사용

## 공급량 (슬롯 가용성) 산출

### 테이블 구조
- `detailer_work_schedule`: detailer_id, effective_from, effective_to (스케줄 유효 기간)
- `detailer_work_schedule_rule`: schedule_id, day_of_week(MON~SUN), start_time, end_time (UTC)
  - `deleted_at IS NULL` 조건 필수

### 슬롯 타임 (TARGET_TIMES, UTC → KST)
| UTC | KST |
|-----|-----|
| 23:00 | 08:00 |
| 01:00 | 10:00 |
| 03:00 | 12:00 |
| 05:00 | 14:00 |
| 07:00 | 16:00 |
| 09:00 | 18:00 |
| 11:00 | 20:00 |
| 13:00 | 22:00 |

### 슬롯 가용 판단
- X시 슬롯 공급 가능 = rule의 `start_time(KST) ≤ X시` AND `end_time(KST) ≥ X+1시`
- 18시 세차는 end_time KST 19시(UTC 10:00)면 가능 (세차 ~1시간 소요)
- 일별 공급 = 해당 요일 rule이 있고, schedule이 해당 날짜에 유효한 디테일러 수

### Fill Rate 계산
- `fill_rate = 실제 예약 디테일러 수 / 스케줄 기반 공급 가능 디테일러 수`
- 분모를 "그날 예약이 있는 전체 디테일러"로 추정하면 부정확 — 반드시 스케줄 테이블 사용

## 매출 계산

### 절대 하지 말 것
- `payment.amount` 직접 사용 금지 — 구독/횟수권 고객(~75%)은 payment 레코드 없음
- `subscription.price / monthly_count` 같은 추정도 부정확

### 정확한 방식 (개발팀 CBR 정산 쿼리)
1. `user_service` + `service` → 서비스 기본가
2. `user_option` + `options` → 옵션 추가가
3. `cart_item` → `cart` → `payment` → `payment.metadata` JSON_TABLE로 실결제 항목 추출
4. 포인트 차감: 비례 배분 (`item_price / total_price * point_amount`)
5. 최종: `sale_price = base_price - point_alloc`

## Grafana 참조

- 디테일러 가동률 대시보드: uid `fe6dr4x83wwlca`
- Grafana API: `https://thetrive.grafana.net`
- 가동률 공식: `count(*) / (5 * count(distinct detailer_id))` — 총 예약 / (5슬롯 × 디테일러 수)
- 서플라이 쇼티지: `$WEEKDAY_TOTAL_MAX` Grafana 변수 사용

## 주말 데이터 주의

- 주말 디테일러 2~3명 → 매진율/fill rate 스윙이 큼
- 평일만 분석하거나, 8+ 디테일러 운영일 필터 적용 권장

## Invariant (불변 조건)

분석 결과가 아래를 위반하면 쿼리 로직에 버그가 있는 것:

1. **예약 수 ≤ 공급 수**: 어떤 날/시간대든 예약 디테일러 수가 스케줄 공급보다 클 수 없음
2. **Fill Rate 0~100%**: 분자(예약) ≤ 분모(공급)이므로 100% 초과 불가
3. **일 최대 슬롯 ≤ 7**: 디테일러 1인당 하루 최대 예약 7건 (API 코드 상한)
4. **CREATED 미포함**: 분석 대상 예약에 status='CREATED'가 섞이면 안 됨
5. **start_time 매칭**: `HOUR(start_time) <= 23` 같은 항상-참 조건은 버그. 슬롯별 정확한 UTC 시간만 매칭할 것

## 검증 스크립트

```bash
./scripts/validate-analysis.sh                      # 이번 달
./scripts/validate-analysis.sh 2026-03-01 2026-03-23  # 기간 지정
```

검증 항목: 예약≤공급, 상태 분포, 디테일러 필터 수, Fill Rate 범위, start_time 분포
