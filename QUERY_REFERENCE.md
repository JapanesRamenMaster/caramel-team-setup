# Caramel DB 쿼리 레퍼런스

caramel-prod DB 분석 쿼리 시 반드시 따를 규칙. `grafana-audit/CLAUDE.md`와 함께 참조.

## 필터 기준 (Grafana 대시보드와 일치)

### 디테일러
- **코드 기준 active 4조건**: `booking_yn=1, retired_yn=0, deleted_yn=0, direct_yn=1`
- `detailer.name != '이상민'` (테스트 계정), `detailer.id != 159` (성지원, supply_sheet 미등록 테스터)
- `detailer_supply_sheet.status = '현직'`은 40명, Grafana 기준(위 조건)은 60명 — **Grafana 기준 사용할 것**
- **파견 디테일러**: `supply_sheet.status='파견'` 기준 (현재 7명). 대부분 work_schedule_rule 없음 (15명 중 13명).
  - **포함 정책**: capacity 쿼리, "근무 디테일러수" 메트릭 모두 세차 발생 여부와 무관하게 UNION으로 합산 (= 워크 발생 디테일러 ∪ 현재 파견자)
  - **시점 추적 한계**: `supply_sheet`에 status 변경 이력 없음. 파견↔현직 전환이 발생하면 12개월 시계열 전체가 retroactive하게 변동됨. 파견자가 잦은 운영 변경 대상이면 별도 이력 테이블 필요
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
- **날짜를 결과로 내보낼 땐 `DATE()` 말고 `DATE_FORMAT(... , '%Y-%m-%d')`로 문자열 반환할 것** (★함정)
  - `DATE(ts + INTERVAL 9 HOUR)`는 `DATE` 타입을 반환하는데, mysql2(node) 드라이버가 이를 **UTC 자정 ISO**로 직렬화 → KST 날짜가 화면상 **−9시간(전날 15:00Z)** 으로 밀려 보임. 일자별 집계가 +1일 어긋난 것처럼 오해하게 됨
  - 예: `DATE_FORMAT(reservation_datetime + INTERVAL 9 HOUR, '%Y-%m-%d') AS kst_date` → `"2026-05-28"` 그대로

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
- **`work_schedule_rule`은 슬롯 생성의 필수 조건** — rule 없으면 코드에서 슬롯 자체가 안 생김 (fallback 없음). capacity 쿼리에서도 `day_of_week` 매칭 필수
- **`effective_from~to` 범위만 체크하면 과대 카운트** — 반드시 해당 요일의 rule 존재 여부를 함께 확인할 것

### Fill Rate 계산
- `fill_rate = 실제 예약 디테일러 수 / 스케줄 기반 공급 가능 디테일러 수`
- 분모를 "그날 예약이 있는 전체 디테일러"로 추정하면 부정확 — 반드시 스케줄 테이블 사용

### detailer_holiday (off/비활성화) 처리
- **테이블 용도가 혼재**: 연차/결근, 파견 차단, 퇴사 차단, 부분 시간 비활성화, 존 변경 메모 등이 모두 `detailer_holiday`에 저장됨
- **off 판단 기준**: 기간으로 구분
  - **단기(≤7일) full-day** (`from ≤ 당일 00:00` AND `to ≥ 익일 00:00`) → 실제 off (연차/결근)
  - **장기(>7일)** → 무시 (파견/퇴사 등 운영 메모. capacity에서 빼면 안 됨)
  - **부분 시간** (full-day 아님) → 겹치는 슬롯 수만큼 차감
- **`v_detailer_holiday_daily` 뷰의 한계**: rule 있는 장기 파견자의 holiday를 못 잡는 케이스 존재. capacity 쿼리에서는 뷰 대신 `detailer_holiday` 직접 조회 권장
- `from`/`to`는 UTC DateTime — **부분 시간 차단도 지원** (예: 08~10시 KST만 비활성화)

## 마케팅 데이터 소스

광고비 + Attribution 데이터는 외부 소스(Meta, Naver, Airbridge)에서 동기화되어 별도 일별 집계 테이블에 적재됨. 분석 쿼리는 이 테이블들을 사용.

| 테이블 | 출처 | 주요 컬럼 | 적재 |
|---|---|---|---|
| `meta_daily_performance` | Meta Ads API | `date`, `total_spending`, impressions/clicks 등 | Apps Script (마케팅 대시보드) |
| `naver_daily_performance` | Naver Search Ads API | `date`, `total_cost`, impressions/clicks/conversions | Apps Script `SyncNaverSpend.gs` |
| `airbridge_daily_install` | Airbridge MMP | `event_date`, `install_users` | Apps Script `SyncAirbridgeInstall.gs` (매일 11:00 KST) |
| `user_attribution` | App SDK (Airbridge attribution) | `user_id`, `source`, `channel`, `campaign` | NestJS app 직접 적재 (가입 시점) |

### Mixed CAC 분모 옵션

- **설치**: `airbridge_daily_install.install_users` (모든 채널 합산, paid + organic, unique user)
- **회원가입**: `app_user.created_at` 기준 신규 가입자 수
- **차량 등록**: `car.created_at` 첫 차 등록 시점
- **주소 등록**: `user_address.created_at` 첫 주소
- **첫 결제**: `payment.paid_at` 첫 결제 (`status IN ('PAID','PARTIAL_CANCELED')`, `amount > 0`)

각 funnel 단계별 CAC = (Meta + Naver 광고비 합산) / 해당 단계 unique user 수.

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

## 정비(수리) 정산 — `crm_repair_order`

수리 대시보드(`caramel_sales_admin`)의 정비 건. status: `NOT_STARTED / IN_PROGRESS / COMPLETED / PAID(정산완료) / CANCELLED`.

### 정산 완료일 = activity log 기준 + modified_at 폴백 (★함정)
- `crm_repair_order`에 **정산완료일 컬럼이 없다**. `modified_at` 단독은 메모 수정에도 갱신돼 부정확.
- 정본 = `crm_activity_log` 의 `activity_type='REPAIR_ORDER_STATUS_PAID'` 행 `created_at` (`activity_record_id`=`crm_repair_order.id`). 재-PAID 있으니 **`MIN(created_at)`**.
- **그러나 로그 커버리지 ~99%**: 화면 플로우 안 거치고 직접 PAID 입력한 백엔트리(created=modified)는 로그가 없다. `JOIN`(inner)으로 짜면 이들이 통째로 누락된다 (실제로 1~4월 추출에서 2건 떨어진 사고 있었음).
- → **`LEFT JOIN` 후 `COALESCE(MIN(log), modified_at)`** 로 폴백. 로그 있으면 로그, 없으면 modified_at.
```sql
LEFT JOIN (SELECT activity_record_id, MIN(created_at) paid_at
           FROM crm_activity_log WHERE activity_type='REPAIR_ORDER_STATUS_PAID'
           GROUP BY activity_record_id) paid ON paid.activity_record_id = ro.id
WHERE ro.status='PAID' AND ro.deleted_yn=0
  AND COALESCE(paid.paid_at, ro.modified_at) >= :from
  AND COALESCE(paid.paid_at, ro.modified_at) <  :to
```

### 금액 필드 매핑
- `suggested_price` = 매출액(고객 청구 = 안내가격), `cost` = 정산금액(수리업체 지급 = 원가), `delivery_fee` = 탁송비
- 정비마진 = `suggested_price - cost - delivery_fee` (마이너스 정상적으로 존재)
- `repair_shop_id`는 입력률 낮음(~1/3만) → 수리업체 NULL 다수

### 디테일러 영업 건 (★함정)
- `crm_repair_order` ↔ 디테일러 직접 FK 없음. `partner`는 디테일러가 아니라 **정비데스크 운영자**.
- 영업 출처 = 이슈에 있음: `crm_repair_order_issue` → `crm_issue.source_type='DETAILER'` 이면 디테일러 영업 건.
- 디테일러 이름 = `crm_issue.source_record_id` = `detailer.id` 조인. (source_type 값엔 `DETAILER`, `CUSTOMER_INQUIRY`, `REPAIR_RESERVATION`, `RESTORATION` 등 자유입력 혼재)

## Grafana 참조

- 디테일러 가동률 대시보드: uid `fe6dr4x83wwlca`
- Grafana API: `https://thetrive.grafana.net`
- 가동률 공식: `count(*) / (5 * count(distinct detailer_id))` — 총 예약 / (5슬롯 × 디테일러 수)
- 서플라이 쇼티지: `$WEEKDAY_TOTAL_MAX` Grafana 변수 사용

### CBR 6w 패널 cutoff 정책 (2026-04-28~)

- CBR은 수요일 진행 → 진행중 주 데이터(월~화)는 false drop을 만드는 노이즈
- **모든 6w(주간) 패널은 outer wrap으로 진행중 주 제외**: `SELECT * FROM (...) cbr_cutoff_wrap WHERE cbr_cutoff_wrap.<time_col> < 이번_주_월요일`
- 마커 `cbr_cutoff_wrap`이 idempotency 가드 (이미 들어있으면 재변환 skip)
- 12m(월간) 패널은 그대로 (이번 달 진행중 데이터 노출 OK — 사용자 결정)
- 일괄 적용 스크립트: `grafana-audit/apply_cbr_cutoff.py`

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
