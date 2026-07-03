# Caramel DB 쿼리 레퍼런스

caramel-prod DB 분석 쿼리 시 반드시 따를 규칙. `grafana-audit/CLAUDE.md`와 함께 참조.

---

## 0. 모든 쿼리 체크리스트

모든 쿼리를 짜기 전 아래 세 가지를 반드시 확인한다.

- **테스터 제외** — `deleted_yn=0, test_yn=0, temp_yn=0` (앱 유저 기준). 디테일러는 → §3a
- **UTC→KST 변환** — DB 전체 UTC 저장. 날짜 집계 전 반드시 변환 → §5a
- **유령예약 제거** — CONFIRMED 포함 예약 집계 시 `user_service` + `car` 존재 여부 확인 → §2b
- **차량/타겟(고가차) 분석** — `reservation`엔 car_id 없음. **`reservation_car` 경유**가 정본 → §2d (⚠️ `user_service.applicable_car_id`는 ~60% NULL 함정). 타겟 판별 = `car_model_target.is_target` → §2d

---

## 1. 핵심 테이블 맵

`reservation`을 중심으로 한 연결 구조:

```
app_user (고객. NOT user/users — 그 테이블명 없음)
    │
    ├── user_address (주소/좌표. r.latitude deprecated → COALESCE 필수 → §2e)
    │
    └── subscription (구독. status=ACTIVE 필터 → §5d)

reservation
    │
    ├── user_service  ← 허브: 세차권·구독·결제 모두 연결
    │       ├── service (서비스명)
    │       ├── subscription_id (NULL이면 1회권)
    │       └── coupon_code_reward_id (쿠폰 경로)
    │
    ├── reservation_car → car  (car_id 직접 없음! → §2d)
    │       ├── car_brand (브랜드. car.brand 레거시 → §2d)
    │       └── car_model → car_model_target (타겟 판별 뷰)
    │
    ├── user_address (address_id 경유. 작업주소 스냅샷은 reservation.location → §2e)
    │
    └── wash_result → wash_result_image (사진. status='BEFORE'/'AFTER')
            └── report → report_card (리포트/타이어)
```

---

## 2. 예약 쿼리 필수 패턴

### 2a. 상태 필터

| 목적 | 조건 |
|------|------|
| 세차 완료 | `status IN ('WASHED', 'REPORT_SENT')` |
| 확정 예약(미완료) | `status = 'CONFIRMED'` |
| 유효 예약 전체 | `status IN ('WASHED', 'REPORT_SENT', 'CONFIRMED')` |
| 취소 | `status = 'CANCELED'` (제외할 것) |
| 미확정 | `status = 'CREATED'` (제외할 것) |

⚠️ `NOT IN ('CANCELED')` 사용 금지 — CREATED가 포함되어 데이터 왜곡됨.

### 2b. 유령예약 제거 (CONFIRMED 집계 시 필수)

반복구독 고객의 미래 예약은 배치 생성되는데, 세차권(`user_service`)이 없거나 차량(`car`)이 삭제된 상태로 CONFIRMED가 남아 있을 수 있음. 이 유령예약이 집계에 포함되면 과다 카운트.

**예약수 세는 모든 쿼리에 아래 두 조건 추가 필수:**
```sql
AND EXISTS (SELECT 1 FROM user_service us WHERE us.reservation_id = r.id AND us.deleted_yn = 0)
AND EXISTS (SELECT 1 FROM reservation_car rc JOIN car c ON rc.car_id = c.id WHERE rc.reservation_id = r.id AND c.deleted_yn = 0)
```

WASHED 완료 건만 세는 쿼리엔 실질적 영향 없음. CONFIRMED 포함 집계에서 특히 중요.

### 2c. 완료 시각 vs 예약 시각 (washed_at vs reservation_datetime)

- **`washed_at`**: 실제 세차 완료 처리 시각(UTC). 완료 건 날짜별 집계의 기준 컬럼.
  ```sql
  DATE(CONVERT_TZ(r.washed_at, '+00:00', '+09:00')) AS wash_date
  ```
- **`reservation_datetime`**: 고객이 예약한 시작 시각(UTC). 실제 완료 시각이 아님.
- `washed_at`은 `status IN ('WASHED', 'REPORT_SENT')`일 때만 NOT NULL 보장.
- **"예약 시점" 일수 측정** (가입→예약 며칠, 당일 예약 비중 등)은 `created_at`(예약을 *잡은* 시각) 기준. `reservation_datetime`(세차 *예정일*)로 재면 왜곡 — "가입 당일 예약" 71%가 14%로 추락한다.

### 2d. 차량 조인 (reservation_car 경유)

`reservation` 테이블엔 차량 FK가 없다. **가장 깔끔한 경로 = `reservation_car`** (reservation_id↔car_id, 거의 1:1):
```sql
JOIN (SELECT reservation_id, MAX(car_id) car_id FROM reservation_car GROUP BY reservation_id) rc
  ON rc.reservation_id = r.id
JOIN car c ON c.id = rc.car_id AND c.deleted_yn = 0
```

대안: `checkup.car_id`(WASHED만), `subscription.represent_car_id`(구독세차 7.5%만). `user_service.applicable_car_id`는 ~60%가 NULL이라 부적합(직관적이라 빠지기 쉬운 함정 — reservation_car는 100% 커버). 검증 2026-06-26.

**차량 브랜드 필터 — `car.brand`는 레거시 nullable**
- `car.brand`는 레거시 VARCHAR 컬럼으로 NULL인 차량이 존재. `brand IN ('포르쉐','벤츠',...)` 단독으로 쓰면 `brand_id`만 세팅된 차량이 누락됨.
- **올바른 패턴:**
  ```sql
  JOIN car_brand cb ON cb.id = c.brand_id
  WHERE cb.name IN ('포르쉐', '벤츠', 'BMW', ...)
  ```
- ⚠️ 조건 충족 차량이 결과에서 누락되면 첫 의심은 `car.brand` 직접 필터. 쿼리 수정(`JOIN car_brand`)으로 포함.
- **국산차 브랜드 목록** (`car_brand.name` 기준): `'현대', '기아', '제네시스', 'KGM', 'KGM(쌍용)', '르노', '쉐보레', '캠시스', 'GM', '르노삼성', '대우', '삼성'` — 쌍용은 `'KGM(쌍용)'`으로 저장됨 주의.

**차량 모델 조인 — `car.car_model_id` 없음**
- FK 컬럼명은 **`car.model_id`** — `car_model_id`는 존재하지 않아 "Unknown column" 오류 발생.
- 올바른 조인: `LEFT JOIN car_model cm ON c.model_id = cm.id`

**S·A 타겟(신차 출고가 6,500만↑) 판별 — `car_model_target` 뷰**
- `JOIN car_model_target cmt ON cmt.id = c.model_id WHERE cmt.is_target = 1`
- ❌ `car_brand.target_yn`(수입차 브랜드 21개 단위)은 부정확 — 제네시스 G90·GV80 누락 + BMW 1시리즈·벤츠 A클래스 오포함.
- `car_tier`(T1~T7)도 차 크기 기준이라 출고가 대리변수로 못 씀.
- 뷰 `is_target=1` = 220개 모델(2026-06 기준).

### 2e. 주소/좌표 COALESCE 패턴

`reservation.latitude/longitude`는 @deprecated (Prisma 스키마 2026-04-28~). 신규 예약은 `user_address`에만 좌표가 있을 수 있음. Zone 매핑·좌표 쿼리는 반드시 COALESCE:
```sql
JOIN user_address ua ON ua.id = r.address_id
LEFT JOIN zone z ON ST_Contains(z.area,
  ST_GeomFromText(CONCAT('POINT(',
    COALESCE(r.longitude, ua.longitude), ' ',
    COALESCE(r.latitude, ua.latitude), ')'), 0))
```

`r.latitude` 단독 사용 시 신규 예약이 NULL로 처리돼 zone 매핑에서 누락됨.

**`reservation.location` 이중 의미 — 반드시 구분해서 사용**
- `reservation.location` = **작업주소 텍스트 스냅샷** (업무용 주소 문자열, 디테일러 앱·알림이 읽음)
  - geometry가 **아니라 text** 타입이며 인코딩이 깨져 있음 (`ST_AsText`/`ST_SRID` 시도 시 `Geometry byte string must be little endian` 오류)
  - 업무 주소로는 쓰되, 좌표 파싱 불가
- **위치 파악용 좌표** = `latitude`/`longitude` (decimal(11,8), deprecated → COALESCE with `user_address`)

**일회성 작업지 변경(이번 건만 다른 주소):**
- `reservation`의 `location`/`detailed_location`/`latitude`/`longitude` 4필드만 UPDATE.
- `address_id`·`user_address`는 건드리지 말 것 — 고객 저장 주소(집)를 고치면 향후 예약까지 오염.
- 새 좌표: NAVER 지오코딩 `GET https://naveropenapi.apigw.ntruss.com/map-geocode/v2/geocode?query=<주소>`, 헤더 `x-ncp-apigw-api-key-id` / `x-ncp-apigw-api-key` (키: caramel-zero `.env.dev`의 `NAVER_MAPS_GEOCODE_CLIENT_ID/SECRET`). 응답 `addresses[0].x`=lng, `.y`=lat.

### 2f. Zone 매핑 (ST_Contains)

- `reservation`엔 `zone_id` 없음. `zone.area`는 polygon(SRID 0, 좌표 순서 **(lng lat)**)
- 경로: reservation → COALESCE 좌표(§2e) → `ST_Contains(zone.area, POINT(lng lat))`
- 어느 zone에도 안 들어가면 z가 NULL → 미커버/이탈 후보

### 2g. source_type 능동/자동 구분

- **고객 직접(능동)**: `source_type IS NULL OR source_type = 'CUSTOMER_DIRECT'` — 대부분의 고객 예약 (NULL이 절대다수, 약 85%)
- **제외 대상(자동/관리자)**:
  - `CHECKOUT_SETTLEMENT`: 구독 결제 시 자동 배치 예약
  - `RAIN_RETOUCH`: 비 오는 날 재세차 자동 배정
  - `MANUAL_EVENT_IMPORT`: 관리자 수동 입력
- ⚠️ `reserved_with_date` 컬럼은 레거시 — 능동/자동 구분에 사용 불가. 실제 분포: 0=~12500건, 1=98건뿐.

---

## 3. 디테일러 쿼리 필수 패턴

### 3a. Active 4조건 + 테스터 제외

**코드 기준 active 4조건**: `booking_yn=1, retired_yn=0, deleted_yn=0, direct_yn=1`

테스터 제외:
- `detailer.name != '이상민'` (테스트 계정)
- `detailer.id != 159` (성지원, supply_sheet 미등록 테스터)

참고: `detailer_supply_sheet.status = '현직'`은 40명, Grafana 기준(위 조건)은 60명 — **Grafana 기준 사용할 것**

**파견 디테일러**: `supply_sheet.status='파견'` 기준 (현재 7명). 대부분 work_schedule_rule 없음 (15명 중 13명).
- capacity 쿼리, "근무 디테일러수" 메트릭 모두 UNION으로 합산 (= 워크 발생 디테일러 ∪ 현재 파견자)
- `supply_sheet`에 status 변경 이력 없음 — 파견↔현직 전환이 발생하면 12개월 시계열 전체가 retroactive하게 변동됨.

두 테이블 JOIN 시 `COLLATE utf8mb4_general_ci` 필수.

### 3b. Zone 배정 조인 체인

배정은 `detailer_work_schedule_rule.zone_id`로 결정.

```sql
-- 현재 유효 zone 배정
JOIN detailer_work_schedule ws ON ws.detailer_id = d.id
  AND UTC_TIMESTAMP() BETWEEN ws.effective_from AND ws.effective_to
JOIN detailer_work_schedule_rule r ON r.schedule_id = ws.id
  AND r.deleted_at IS NULL          -- ⚠️ deleted_yn 없음 — deleted_at IS NULL 사용
JOIN zone z ON z.id = r.zone_id     -- ⚠️ service_zone 테이블 없음 — zone 테이블만 있음
```

⚠️ `detailer_region` 테이블 쓰지 말 것 — `service_region_id` 기반 구식 구조.

**zone id → name 매핑:**

| id | name |
|----|------|
| 1  | Z0 (경기 성남시) |
| 2  | Z1 (마포구/용산구) |
| 3  | Z3 (강남구/송파구) |
| 4  | Z4 (강서구/경기김포시) |
| 5  | Z5 (서초구/용산구) |
| 6  | Z6 (인천 연수구/인천 서구) |
| 7  | Z7 (경기 안양시/경기 과천시) |
| 8  | Z9 (성동구/성북구) |
| 9  | Z10 (영등포구/금천구) |
| 10 | Z12 (강남구/서초구) |
| 11 | Z14 (경기 용인시/경기 화성시) |
| 12 | Z16 (강동구/송파구) |
| 13 | Z17 (경기 고양시/경기 파주시) |

---

## 4. 검증 기준 (Invariant)

분석 결과가 아래를 위반하면 쿼리 로직에 버그가 있는 것:

1. **예약 수 ≤ 공급 수**: 어떤 날/시간대든 예약 디테일러 수가 스케줄 공급보다 클 수 없음
2. **Fill Rate 0~100%**: 분자(예약) ≤ 분모(공급)이므로 100% 초과 불가
3. **일 최대 슬롯 ≤ 7**: 디테일러 1인당 하루 최대 예약 7건 (API 코드 상한)
4. **CREATED 미포함**: 분석 대상 예약에 `status='CREATED'`가 섞이면 안 됨
5. **start_time 매칭**: `HOUR(start_time) <= 23` 같은 항상-참 조건은 버그. 슬롯별 정확한 UTC 시간만 매칭할 것

**검증 스크립트:**
```bash
./scripts/validate-analysis.sh                        # 이번 달
./scripts/validate-analysis.sh 2026-03-01 2026-03-23  # 기간 지정
```
검증 항목: 예약≤공급, 상태 분포, 디테일러 필터 수, Fill Rate 범위, start_time 분포

---

## 5. 공통 패턴

### 5a. KST 변환

DB는 UTC 저장 → `CONVERT_TZ(col, '+00:00', '+09:00')` 또는 `+ INTERVAL 9 HOUR`

GROUP BY에 날짜 쓸 때 반드시 KST 변환 후 사용.

예외: `paused_at`, `ended_at`은 코드에서 KST(`Asia/Seoul`)로 할당 → UTC +9H 변환 불필요.

### 5b. 테스터/테스트 계정 제외

```sql
-- 앱 유저 (live_users CTE 패턴)
WHERE au.deleted_yn = 0 AND au.test_yn = 0 AND au.temp_yn = 0

-- 디테일러
WHERE d.name != '이상민' AND d.id != 159
```

### 5c. 유료 예약 판정

**유료 예약** (프로모션 무료 제외): `user_service.paid_yn = 1` + 0원 VOUCHER 프로모션 제외:
```sql
AND r.id NOT IN (
  SELECT p.reservation_id FROM payment p
  WHERE p.type = 'VOUCHER' AND p.amount = 0 AND p.status = 'PAID'
    AND p.reservation_id IS NOT NULL
)
```

**취소율 측정 함정**: `user_service`는 예약 취소 시 `deleted_yn=1`로 soft-delete됨. 취소 건을 분모에 넣으려면 `deleted_yn` 필터를 빼야 함 — 안 그러면 취소가 통째로 빠져 취소율이 0%로 왜곡.

### 5d. 구독 status=ACTIVE 필터

- `status='ACTIVE'` 단독 조건은 일시정지 포함 → "현재 세차 가능한 활성 구독자" 집계 시 왜곡
- **실사용 구독자(일시정지 제외)**: `status='ACTIVE' AND paused_at IS NULL`
- `status='ACTIVE' AND paused_at IS NOT NULL` = 일시정지 상태 (세차 불가, 구독료 정지)

**1회권 vs 구독 구분:**
- **1회권**: `user_service.subscription_id IS NULL`
- **구독 세차**: `user_service.subscription_id IS NOT NULL`

**구독 첫 세차 식별** (user_id + subscription_id 기준):
```sql
first_sub_reservations AS (
  SELECT MIN(r.id) AS reservation_id, us.user_id, us.subscription_id
  FROM reservation r
  JOIN user_service us ON us.reservation_id = r.id AND us.deleted_yn = 0
  WHERE us.subscription_id IS NOT NULL
  GROUP BY us.user_id, us.subscription_id
)
```
`MIN(r.id)` 사용 이유: 같은 `created_at` 충돌 방지.

---

## 6. 도메인별 심화

### 6a. Zone (날씨 조인)

**예약 → 날씨 조인 (forecast_log dedup 필수)**
- 같은 zone+date에 row가 여러 개 쌓임 → `ROW_NUMBER() OVER (PARTITION BY zone_id, forecast_date ORDER BY forecasted_at DESC)` 로 dedup 필수.
- ⚠️ `zone_rain_log` 테이블은 드롭됨 — `forecast_log`만 사용.
- 경로: `reservation` → zone(polygon join, COALESCE 패턴 §2e) → `forecast_log`(zone_id + forecast_date)

**야외/실내 주차장 필터**
- 주차장 유형은 `reservation`에 없고 `user_address.parking_lot_type`에 있음.
- 값: `'OUTDOOR'`(야외), `'INDOOR'`(실내), **`NULL`(48k건, 미등록)**.
- ⚠️ NULL ≠ OUTDOOR — 야외 필터 시 `= 'OUTDOOR'` 명시 필수. `!= 'INDOOR'`로 쓰면 미등록 주소가 모두 포함됨.
- 패턴: `JOIN user_address ua ON r.address_id = ua.id WHERE ua.parking_lot_type = 'OUTDOOR'`

**서비스 가능 지역 조회 (service_region)**
- 컬럼: `sido`, `sigungu`, `dong`, `available_yn` (1=가능)
- ⚠️ `city`, `district`, `name` 컬럼 없음 — 사용 금지
- ⚠️ `sigungu` 통합값 함정: `"화성시"` 단독 행 없음. `"화성시 동탄구"` 형태. `= '화성시'` 사용 시 누락 → **`LIKE '%화성%'`** 사용
- 표준 조회 패턴:
  ```sql
  SELECT srg.name AS srg_name, sr.sido, sr.sigungu, sr.dong, sr.available_yn
  FROM service_region sr
  JOIN service_region_group srg ON srg.id = sr.service_region_group_id
  WHERE sr.sigungu LIKE '%화성%' AND sr.available_yn = 1
  ```

### 6b. 공급량

**테이블 구조**
- `detailer_work_schedule`: detailer_id, effective_from, effective_to
- `detailer_work_schedule_rule`: schedule_id, day_of_week(MON~SUN), start_time, end_time (UTC), zone_id
  - `deleted_at IS NULL` 조건 필수

**슬롯 타임 (TARGET_TIMES, UTC → KST)**

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

**슬롯 가용 판단**
- X시 슬롯 공급 가능 = rule의 `start_time(KST) ≤ X시` AND `end_time(KST) ≥ X+1시`
- **`effective_from~to` 범위만 체크하면 과대 카운트** — 반드시 해당 요일의 rule 존재 여부를 함께 확인
- Fill Rate = `실제 예약 디테일러 수 / 스케줄 기반 공급 가능 디테일러 수`

**detailer_holiday 처리**
- 단기(≤7일) full-day (`from ≤ 당일 00:00` AND `to ≥ 익일 00:00`) → 실제 off
- 장기(>7일) → 무시 (파견/퇴사 등 운영 메모)
- 부분 시간 → 겹치는 슬롯만 차감
- `v_detailer_holiday_daily` 뷰 한계 있음 — capacity 쿼리에서는 `detailer_holiday` 직접 조회 권장

**주말 데이터 주의**
- 주말 디테일러 2~3명 → fill rate 스윙이 큼
- 평일만 분석하거나 8+ 디테일러 운영일 필터 적용 권장

**Grafana 참조**
- 디테일러 가동률 대시보드: uid `fe6dr4x83wwlca`
- Grafana API: `https://thetrive.grafana.net`
- 가동률 공식: `count(*) / (5 * count(distinct detailer_id))` — 총 예약 / (5슬롯 × 디테일러 수)

### 6c. 마케팅

⚠️ `utm_source`만 있음. **`utm_medium`, `utm_campaign` 컬럼 없음** — 쓰면 에러.

**마케팅 데이터 소스 테이블**

| 테이블 | 출처 | 주요 컬럼 | 적재 |
|--------|------|-----------|------|
| `meta_daily_performance` | Meta Ads API | `date`, `total_spending`, `total_purchase_value`, `total_purchase`, `avg_cac` | Apps Script |
| `naver_daily_performance` | Naver Search Ads API | `date`, `total_cost`, `impressions`, `clicks`, `conversions` | Apps Script `SyncNaverSpend.gs` |
| `google_daily_performance` | Google Ads API | `date`, `total_cost`, `impressions`, `clicks` | Apps Script `syncGoogleAdsSpendToDB` (매일 10:00 KST) |
| `airbridge_daily_install` | Airbridge MMP | `event_date`, `install_users` | Apps Script `SyncAirbridgeInstall.gs` (매일 11:00 KST) |
| `user_attribution` | App SDK (Airbridge attribution) | `user_id`, `source`, `channel`, `campaign` | NestJS app 직접 적재 (가입 시점) |

**⚠️ `user_attribution` fan-out 함정 (2026-07-01 실사례 — 같은 질문에 3연속 다른 오답)**
- **유저 1명당 여러 row**가 있다 (`source`별: `airbridge_sdk`/`offline`/`deeplink` 등). 예: `thehyundai_seoul_popup` 캠페인 = 978 row인데 **distinct 유저는 318명** (유저당 평균 3행).
- 따라서 **`payment` 등 다른 테이블에 직접 JOIN 후 SUM/COUNT 하면 row 수만큼 뻥튀기**된다 (attribution 3행 × 결제 5건 = 15배로 카운트). 실사례: 실제 766만원이 3,641만원으로, 유료 OPTION 4만원이 2만원으로 — 매번 틀림.
- **규칙: attribution은 반드시 `SELECT DISTINCT user_id`로 먼저 접어 `IN (…)` 서브쿼리로만 연결한다. 절대 직접 JOIN해서 집계하지 않는다.**

**박제 쿼리 — 특정 채널·캠페인 유입 고객의 결제 집계 (검증 SQL, 탐색 없이 그대로 실행)**
```sql
-- 유형별 결제 집계 (fan-out 없음). :channel/:campaign 만 바꿔 쓴다.
SELECT p.type,
       COUNT(DISTINCT p.user_id)                  AS users,
       COUNT(*)                                   AS payments,
       SUM(p.amount - IFNULL(p.cancel_amount, 0)) AS net_amount
FROM payment p
WHERE p.status IN ('PAID','PARTIAL_CANCELED')
  AND p.amount > 0            -- amount=0 무료 번들 옵션(휠분진·유막제거 등) 제외
  AND p.deleted_yn = 0
  AND p.user_id IN (
    SELECT DISTINCT user_id FROM user_attribution
    WHERE channel = :channel AND campaign = :campaign
  )
GROUP BY p.type ORDER BY net_amount DESC;
```
- 총 결제고객·총액은 위 쿼리에서 `GROUP BY p.type`를 빼고 `COUNT(DISTINCT p.user_id)`, `SUM(...)`.
- **신규 여부 주의**: attribution은 재유입(deeplink)도 잡으므로, 결제자 중 **캠페인 시작 전 첫 결제자는 기존고객**일 수 있다. 순수 신규 매출은 `AND p.paid_at >= '<캠페인 시작일>'`을 추가로 건다. (실사례: 팝업 결제자 28명 중 2명은 올해 1월·작년 첫결제 기존고객 → 순수 신규 26명 / 750.6만원.)

**총 광고비 집계 (반드시 3개 채널 합산)**
```sql
SELECT DATE(date) AS dt, SUM(cost) AS total_cost FROM (
  SELECT date, total_spending AS cost FROM meta_daily_performance WHERE date BETWEEN :from AND :to
  UNION ALL
  SELECT date, total_cost AS cost FROM naver_daily_performance WHERE date BETWEEN :from AND :to
  UNION ALL
  SELECT date, total_cost AS cost FROM google_daily_performance WHERE date BETWEEN :from AND :to
) sub GROUP BY dt ORDER BY dt
```
⚠️ `meta + naver`만 합산하면 Google 누락으로 20~30% 과소 집계됨 (2026-06-08 실사례: Meta 19.3만 + Naver 7.7만 = 27만, 실제 47만. Google 20.7만 누락).

**Mixed CAC 분모 옵션**
- **설치**: `airbridge_daily_install.install_users`
- **회원가입**: `app_user.created_at` 기준 신규 가입자 수
- **첫 결제**: `payment.paid_at` 첫 결제 (`status IN ('PAID','PARTIAL_CANCELED')`, `amount > 0`)
  - 세차 서비스 신규 고객 기준이면 `type IN ('VOUCHER','SUBSCRIPTION')`도 추가할 것. OPTION/PACKAGE가 먼저 들어올 수 있어 단순 `MIN(paid_at)`이 틀린 결과를 낸다.

**알라미 리포트 데이터 소스**
- `데일리 캠페인 트래커` Google Sheets에서 읽음 (DB 직접 조회 아님)
- 광고비 적재 타이밍: Meta/Naver는 09:00 KST, Google은 10:00 KST

**시계열 교란변수 — 외부만구독 런칭(2025-10-05)**
- 2025-10 전후 단순 비교 시 재방문율, 외부만 비중, 디테일러 생산성, 세차당 소요시간이 왜곡됨
- **외부만구독 필터**: `service.wash_type = 'OUTSIDE' AND reservation.subscription_id IS NOT NULL`

**CBR 6w 패널 cutoff 정책 (2026-04-28~)**
- CBR은 수요일 진행 → 진행중 주 데이터(월~화)는 false drop을 만드는 노이즈
- **모든 6w(주간) 패널은 outer wrap으로 진행중 주 제외**: `SELECT * FROM (...) cbr_cutoff_wrap WHERE cbr_cutoff_wrap.<time_col> < 이번_주_월요일`
- 마커 `cbr_cutoff_wrap`이 idempotency 가드 (이미 들어있으면 재변환 skip)
- 12m(월간) 패널은 그대로
- 일괄 적용 스크립트: `grafana-audit/apply_cbr_cutoff.py`
- ⚠️ cutoff 연산자는 `<` (strictly less than). `<=` 금지.

### 6d. 정비·리포트

**정비(수리) 정산 — `crm_repair_order`**
- status: `NOT_STARTED / IN_PROGRESS / COMPLETED / PAID(정산완료) / CANCELLED`
- 금액 필드: `suggested_price`(매출액/고객 청구), `cost`(정산금액/원가), `delivery_fee`(탁송비)
- 정비마진 = `suggested_price - cost - delivery_fee`

**정산 완료일 = activity log 기준 + modified_at 폴백**
- `crm_repair_order`에 정산완료일 컬럼이 없음. `modified_at` 단독은 메모 수정에도 갱신돼 부정확.
- 정본 = `crm_activity_log`의 `activity_type='REPAIR_ORDER_STATUS_PAID'` 행 `created_at` (`MIN`).
- 로그 커버리지 ~99% — 화면 플로우 안 거친 백엔트리는 로그 없음. INNER JOIN으로 짜면 통째 누락.
- **`LEFT JOIN` 후 `COALESCE(MIN(log), modified_at)` 폴백:**
  ```sql
  LEFT JOIN (SELECT activity_record_id, MIN(created_at) paid_at
             FROM crm_activity_log WHERE activity_type='REPAIR_ORDER_STATUS_PAID'
             GROUP BY activity_record_id) paid ON paid.activity_record_id = ro.id
  WHERE ro.status='PAID' AND ro.deleted_yn=0
    AND COALESCE(paid.paid_at, ro.modified_at) >= :from
    AND COALESCE(paid.paid_at, ro.modified_at) <  :to
  ```

**디테일러 영업 건**
- `crm_repair_order` ↔ 디테일러 직접 FK 없음. `partner`는 정비데스크 운영자.
- 영업 출처 = `crm_repair_order_issue` → `crm_issue.source_type='DETAILER'`
- 디테일러 이름 = `crm_issue.source_record_id` = `detailer.id` 조인

**타이어 마모도 조인 경로**
- `report_card`에 `reservation_id` 없음. 경로: `reservation → report(reservation_id) → report_card(report_id)`
- 타이어 마모도 타입: `rc.type IN ('TIRE_TREAD', 'TIRE_SUMMARY')`. 값은 JSON `data` 컬럼.
- 완료 전 예약은 `report` 자체가 없음 → 반드시 `LEFT JOIN`
  ```sql
  LEFT JOIN report rp ON rp.reservation_id = r.id AND rp.deleted_yn = 0
  LEFT JOIN report_card rc ON rc.report_id = rp.id AND rc.deleted_yn = 0
    AND rc.type IN ('TIRE_TREAD', 'TIRE_SUMMARY')
  ```

**세차 내용(서비스명) 조회 — `reservation_care.name`은 항상 NULL**
- `reservation_care.name` / `content` 컬럼은 전량 NULL. `care_item_id`도 대부분 미매핑.
- 올바른 경로: `user_service` → `service.name`
  ```sql
  SELECT s.name AS service_name
  FROM user_service us
  JOIN service s ON s.id = us.service_id
  WHERE us.reservation_id = :rid AND us.deleted_yn = 0
  LIMIT 1
  ```
- 값 예시: `'외부만'`, `'외부 + 내부'`, `'[리터치] 외부만'`, `'월 2회(외부만)'`

**서비스 상품 이름 동일해도 내용 다를 수 있음**
- 같은 이름이라도 `description`이 다름. 예: `올클린 케어 (29)`는 왁스코팅 포함, `(55)`/`(35)`는 미포함.
- 상품 비교·집계 시 `name`만 보고 "동일"로 단정 금지. `description`도 함께 조회·확인.

**사진 테이블 구조**
세차 전/후 사진은 `wash_result_image`가 메인(신규), `reservation_image`는 구버전.

| 테이블 | 전/후 구분 컬럼 | 값 |
|--------|----------------|-----|
| `wash_result_image` | `status` | `'BEFORE'` / `'AFTER'` |
| `reservation_image` | `type` | `'BEFORE_WASH'` / `'AFTER_WASH'` |

```sql
-- wash_result_image → reservation 경로
JOIN wash_result wr ON wr.id = wri.wash_result_id AND wr.deleted_yn = 0
JOIN reservation r ON r.id = wr.reservation_id
WHERE wri.deleted_yn = 0
```

BEFORE/AFTER 섹션 종류:
- 외부: `OUTSIDE_FRONT`, `OUTSIDE_DRIVER_SIDE`, `OUTSIDE_PASSENGER_SIDE`, `OUTSIDE_FRONT_GLASS`, `OUTSIDE_DRIVER_SIDE_WHEEL`
- 내부: `INSIDE_DRIVER_SEAT`, `INSIDE_CENTER_FASCIA`
- 평가 컬럼(`evaluation_status`, `evaluated_at`, `evaluator`)은 현재 전량 `PENDING` — 미사용 상태.

### 6e. 쿠폰

- 테이블: `coupon_code`(개별 코드), `coupon_campaign`(파트너 캠페인 — **`partner_name`** 필드), `coupon_code_reward`(보상 정의), `coupon_code_usage`(사용 이벤트). **`coupon`/`discount` 테이블은 없다.**
- ⚠️ 코드명 LIKE 검색 오탐: `code LIKE '%KCC%'`는 랜덤 발급코드(예: `YKCCHAZB`)가 대량 매칭됨. 파트너 프로모션은 정확 매칭으로 특정.
- 쿠폰 → 발급 세차권 조인: `coupon_code_reward.id` → `user_service.coupon_code_reward_id`
- ⚠️ **캠페인→예약전환 조회 시 발급경로 2가지 다 확인**: 코드 등록이 `coupon_code_reward` 경유로 세차권을 주는 캠페인도 있지만, 캠페인이 특정 `service`에 직결돼 코드 등록 즉시 그 서비스가 바로 지급되는 캠페인도 있다(예: "자스민 전용 무료 세차권" = `service.id=140` 직결, `coupon_code_reward` 레코드 자체가 0건). `coupon_code_reward` 경로가 0건이라고 "예약 전환 0건"으로 단정하지 말 것 — 캠페인명으로 `service.name`을 먼저 찾아 `user_service.service_id`로도 교차 확인.
- **전환 퍼널 = 발급≠사용**: ① `coupon_code_usage`(수령) → ② `user_service.reservation_id IS NOT NULL`(예약) → ③ `reservation.status='WASHED'`(완료). 무료 쿠폰은 ①→②에서 대량 이탈.
- 리텐션/매출은 `user_service.paid_amount`와 `payment`(status='PAID') 양쪽으로 교차검증. 무료세차 당일 결제는 현장 옵션 업셀 — `payment.paid_at > 무료세차 washed_at`로 진짜 재방문만 분리.
- **쉘 계정 어뷰징**: 무료 쿠폰 코호트엔 `app_user.phone IS NULL` + 랜덤 이름(`name REGEXP '^[A-Za-z0-9]{6,8}$'`) + 예약 0건인 가짜 계정이 섞임. 실사용자 모수는 **`phone IS NOT NULL`** 필터.
  - 어뷰징 점검: `user_address.address`+`detail_address`로 세대 묶기, 같은 주소 생성 버스트 탐지, `app_user.dealer_id`/`created_by`로 딜러 경유 확인, `app_user.phone`과 `detailer.phone` 대조(디테일러 셀프-어뷰징).

### 6f. 분석 코호트

**주행거리**
- `car.mileage` = 가장 최근 주행거리 스냅샷 (단일 조회용)
- `car_mileage` 테이블 = 이력 레코드(`car_id`, `mileage`, `record_date`, `type`) (시계열 비교용)
- ⚠️ **커버리지 함정**: `car.mileage` 단독은 전체 차량 ~39%(타겟차 ~36%)만 채워짐 — 이것만 쓰면 모수 절반 누락. 차량별 "현재 주행거리"는 3단 fallback으로 복구:
  `COALESCE(NULLIF(car.mileage,0), 최신 checkup.mileage, 최신 car_mileage.mileage)` — checkup=`ORDER BY checkup_datetime DESC LIMIT 1`(방문 실측), car_mileage=`ORDER BY record_date DESC LIMIT 1`. fallback 포함 시 타겟차 커버리지 ~36%→~51%.

**세차 횟수 — 고객 기준 vs 차량 기준**
- **고객 총 세차** (기본 해석): `COUNT(*) FROM reservation r2 WHERE r2.user_id = r.user_id AND r2.status IN ('WASHED','REPORT_SENT') AND r2.deleted_yn = 0`
- **특정 차량 세차**: `reservation_car` CTE로 `car_id` 기준 집계 → 이 차가 몇 번 세차됐나
- ⚠️ "세차 횟수" 요청 시 기준이 명시 안 되면 고객 총 세차(user_id 기준)가 기본. 차량 단위 요청엔 `reservation_car` 경유 필요.
- 완료 상태 필터: `status IN ('WASHED', 'REPORT_SENT')` (REPORT_SENT도 세차 완료로 처리됨)

**`reservation.key_direct_handover_yn`**
- "세차 당일 다른 사람이 키를 전달할거예요" 체크박스. TinyInt: 1=대리 전달, 0=본인 직접, null=미설정(구버전).

**매출 계산**
- ⚠️ `payment.amount` 직접 사용 금지 — 구독/횟수권 고객(~75%)은 payment 레코드 없음
- 정확한 방식 (개발팀 CBR 정산 쿼리):
  1. `user_service` + `service` → 서비스 기본가
  2. `user_option` + `options` → 옵션 추가가
  3. `cart_item` → `cart` → `payment` → `payment.metadata` JSON_TABLE로 실결제 항목 추출
  4. 포인트 차감: 비례 배분 (`item_price / total_price * point_amount`)
  5. 최종: `sale_price = base_price - point_alloc`

### 6g. CRM 메시지 발송 로그 (`message`)

CRM·트랜잭션 메시지 발송 기록 테이블.

- **컬럼 의미**: 수신자=`customer_id`(→`app_user.id`, ⚠️ `user_id` 아님), 발송시각=`created_at`(UTC), 채널=`lms_type`(`ALIMTALK`/`PUSH`/`MMS`/`SMS`/`LMS`), 캠페인 식별=`type`(varchar 200, 예 `reservationGuide002`·`firstWash_expire`), 발송상태=`status`(기본 `REQUESTED`).
- ⚠️ **`sent_yn` 함정**: **ALIMTALK은 발송돼도 `sent_yn=0`·`status='REQUESTED'` 고정**(PUSH만 `sent_yn=1`). `sent_yn=1`로 필터하면 알림톡이 통째 누락된다. **행 존재 = 발송요청**으로 집계(도달 확정 아님 — BizM 도달 콜백 미반영).
- 채널은 `type`별로 대체로 고정(윈백·구독갱신·자동예약=ALIMTALK, 쿠폰만료는 알림톡/푸시가 별도 `type`).
- **CRM 7일 예약전환 측정**: received(테스터 제외 live_users §5b) → 발송 후 7일 내 `reservation` 생성(`r.user_id = m.customer_id`, `r.created_at` 기준, `r.deleted_yn=0`. raw·비인과). `(customer_id, type)`별 첫 발송 dedup. 상세·재현쿼리 = caramel-api `docs/superpowers/specs/2026-06-30-crm-kill-keep-map.md` §2/§6.

---

## 7. 주요 테이블 컬럼 치트시트

> DESCRIBE 없이 바로 쿼리 작성하기 위한 핵심 컬럼 목록. 전체 스키마는 `DB_SCHEMA.md` 참조.

### car
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| plate_number | varchar(10) | 차량번호 |
| model_year | int | 연식 (NULL 약 12%) |
| brand | varchar(15) | 브랜드명 **레거시 — 99% NULL. `brand_id` 사용** |
| brand_id | int | FK → car_brand.id (name 컬럼으로 JOIN) |
| model | varchar(100) | 모델명 레거시. `model_id` 우선 |
| model_id | int | FK → car_model.id (name 컬럼으로 JOIN) |
| mileage | int | 최근 주행거리 스냅샷 |
| user_id | int | FK → app_user.id |
| deleted_yn | tinyint | 0=정상 |
| temp_yn | tinyint | 1=임시 차량 (필터 제거 권장) |

**국산차 브랜드 제외 패턴:**
```sql
JOIN car_brand cb ON cb.id = c.brand_id
WHERE cb.name NOT IN ('현대','기아','제네시스','KGM','KGM(쌍용)','르노','쉐보레','캠시스','GM','르노삼성','대우','삼성')
```

---

### reservation
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| reservation_datetime | datetime | 예약 일시 **UTC 저장 → KST: CONVERT_TZ(...,'+00:00','+09:00')** |
| washed_at | datetime | 세차 완료 시각 UTC |
| status | varchar(25) | 완료: `WASHED` / `REPORT_SENT`. `COMPLETED` 미사용 |
| user_id | int | FK → app_user.id |
| detailer_id | int | FK → detailer.id |
| address_id | int | FK → user_address.id |
| subscription_id | int | **98% NULL — 구독 여부 판단에 사용 불가** |
| location | text | 주소 문자열 |
| detailed_location | text | 상세 주소 (동/호수) |
| parking_info_content | text | 주차 안내 메모 |
| deleted_yn | tinyint | 0=정상 |
| allow_shuffle_yn | tinyint | 1=리배정 허용 |

**차량 조인 (car_id 직접 없음 → reservation_car 경유):**
```sql
JOIN (SELECT reservation_id, MAX(car_id) car_id FROM reservation_car GROUP BY reservation_id) rc
  ON rc.reservation_id = r.id
JOIN car c ON c.id = rc.car_id AND c.deleted_yn = 0
```

---

### reservation_car
| 컬럼 | 타입 | 설명 |
|------|------|------|
| reservation_id | int | FK → reservation.id |
| car_id | int | FK → car.id |
| confirmed_yn | tinyint | **⚠️ 대부분 0 — 차량 조인 시 이 컬럼으로 필터 금지** |

---

### app_user
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| name | varchar(50) | 이름 |
| phone | varchar(15) | 전화번호 (하이픈 없음) |
| uuid | varchar(50) | UUID (Amplitude userId) |
| utm_source | text | 유입 채널 (`utm_medium`·`utm_campaign` 컬럼 없음) |
| referrer | text | 유입 referrer |
| test_yn | tinyint | 1=테스트 계정 |
| temp_yn | tinyint | 1=임시 계정 |
| deleted_yn | tinyint | 0=정상 |
| deleted_at | datetime(3) | 삭제일 |
| promotion_group_id | int | 프로모션 그룹 |

**테스터 제외 패턴:** `u.deleted_yn = 0 AND u.test_yn = 0 AND u.temp_yn = 0`

---

### detailer
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| name | varchar(100) | 디테일러 이름 |
| user_id | int | FK → app_user.id |
| deleted_yn | tinyint | 0=정상 |
| retired_yn | tinyint | 1=퇴사 |
| booking_yn | tinyint | 1=예약 가능 |
| admin_yn | tinyint | 1=관리자 계정 |
| tier | int | 티어 |
| slack_member_id | varchar(100) | 슬랙 멤버 ID |

**Active 디테일러 필터:** `d.deleted_yn=0 AND d.retired_yn=0 AND d.admin_yn=0`

---

### subscription
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| user_id | int | FK → app_user.id |
| status | varchar(25) | `ACTIVE` / `STOPPED` / `PAUSED` |
| represent_car_id | int | FK → car.id (구독 대표 차량) |
| product_id | int | FK → product.id |
| started_at | datetime | 구독 시작일 |
| ended_at | datetime | 구독 종료일 |
| deleted_yn | tinyint | 0=정상 |
| period | int | 주기 (숫자, period_unit과 조합) |
| period_unit | varchar(15) | `'week'` / `'month'` |

---

### user_service (예약-서비스 연결)
| 컬럼 | 타입 | 설명 |
|------|------|------|
| reservation_id | int | FK → reservation.id |
| user_id | int | FK → app_user.id |
| service_id | int | FK → service.id |
| deleted_yn | tinyint(1) | 0=정상 |
| postpaid_yn | tinyint(1) | 0=선불, 1=후불 |
| applicable_car_id | int | 차량 FK **⚠️ 15%만 채워짐 — 차량 조인 부적합** |

**세차 내용(서비스명) 조회:**
```sql
LEFT JOIN (
  SELECT reservation_id, MIN(service_id) AS service_id
  FROM user_service WHERE deleted_yn = 0 GROUP BY reservation_id
) us ON us.reservation_id = r.id
LEFT JOIN service s ON s.id = us.service_id
-- s.name 예시: '외부만', '외부 + 내부', '[리터치] 외부만'
```

---

### service
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| name | varchar(25) | 서비스명 (`'외부만'`, `'외부 + 내부'` 등) |
| deleted_yn | tinyint(1) | 0=정상 |
| price | int | 기본가 |
| wash_type | varchar(15) | 세차 유형 |

---

### payment
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| user_id | int | FK → app_user.id |
| type | varchar(25) | `VOUCHER`=1회권, `SUBSCRIPTION`=구독, `OPTION`=옵션, `PACKAGE`=패키지 |
| status | varchar(25) | 집계 대상: `IN ('PAID','PARTIAL_CANCELED')` |
| amount | int | 결제금액 **⚠️ 구독/횟수권 고객 75%는 payment 없음** |
| cancel_amount | int | 취소금액 (PARTIAL_CANCELED 시 `amount-cancel_amount`=실매출) |
| paid_at | datetime | 결제 완료일 |
| name | varchar(250) | 상품명 (구독은 플랜명 포함, `'외 N개'` suffix 주의) |
| deleted_yn | tinyint(1) | NULL 가능 — `IS NOT TRUE` 패턴 사용 |

---

## 8. 박제 쿼리 (그대로 실행 — 탐색·DESCRIBE 금지)

> 아래는 **고정 형태로 반복되는 질문**이다. 질문이 트리거와 맞으면 **스키마 탐색·DESCRIBE 없이 아래 SQL을 그대로 한 번에 실행**하고, 날짜 등 변수만 치환하라. 여러 턴에 걸쳐 탐색하지 마라 — 이미 검증된 쿼리다.

### 8a. 정비 타겟 일일 리스트 (수입차·연식 5년↑ 당일 예약 고객)

**트리거**: "N월 N일 예약 고객 중 … 국산차 제외 / 수입차 / 연식 5년 이상 … 차량명·차량번호·주행거리·세차 시작시간·담당 디테일러·예약 주소지·세차 내용·세차 횟수" 형태의 **일일 리스트** 요청 (정비 담당자가 매일 날짜만 바꿔 요청).

**규칙**:
- `<DATE>`(2곳)를 요청 날짜(KST, `YYYY-MM-DD`)로만 치환해 그대로 실행.
- 연식 5년 이상 = `model_year <= 조회연도 - 5` (쿼리가 `<DATE>`에서 자동 계산).
- 연식(`model_year`) NULL 차량은 결과 맨 뒤 별도 그룹(`분류='연식미상'`)으로 나옴 → "Null 따로 분류" 충족.
- 세차 횟수 = 그 고객의 누적 세차완료(`WASHED`/`REPORT_SENT`) 횟수.
- 취소(`CANCELED`)·테스터(`app_user.test_yn=1`)·임시차(`car.temp_yn=1`) 제외 포함됨. 정렬=연식 오래된 순.

```sql
SELECT
  CASE WHEN c.model_year IS NULL THEN '연식미상' ELSE '연식확인' END AS 분류,
  cm.name AS 차량명, c.plate_number AS 차량번호, c.mileage AS 주행거리,
  DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%Y-%m-%d %H:%i') AS 세차시작,
  d.name AS 담당디테일러, r.location AS 예약주소지, s.name AS 세차내용,
  (SELECT COUNT(*) FROM reservation r2
     WHERE r2.user_id=r.user_id AND r2.status IN ('WASHED','REPORT_SENT') AND r2.deleted_yn=0) AS 세차횟수,
  c.model_year AS 연식, cb.name AS 브랜드
FROM reservation r
JOIN (SELECT reservation_id, MAX(car_id) car_id FROM reservation_car GROUP BY reservation_id) rc ON rc.reservation_id=r.id
JOIN car c ON c.id=rc.car_id AND c.deleted_yn=0 AND c.temp_yn=0
JOIN car_brand cb ON cb.id=c.brand_id
LEFT JOIN car_model cm ON cm.id=c.model_id
LEFT JOIN detailer d ON d.id=r.detailer_id
LEFT JOIN user_service us ON us.reservation_id=r.id AND us.deleted_yn=0
LEFT JOIN service s ON s.id=us.service_id
JOIN app_user au ON au.id=r.user_id AND au.deleted_yn=0 AND au.test_yn=0
WHERE DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'))='<DATE>'
  AND r.deleted_yn=0 AND r.status IN ('CONFIRMED','WASHED','REPORT_SENT')
  AND cb.name NOT IN ('현대','기아','제네시스','KGM','KGM(쌍용)','르노','쉐보레','캠시스','GM','르노삼성','대우','삼성')
  AND (c.model_year <= YEAR('<DATE>') - 5 OR c.model_year IS NULL)
ORDER BY (c.model_year IS NULL), c.model_year ASC;
```
- 행이 5개 이상이면 자동으로 스프레드시트로 내보내진다(정상). 검증 기준: 2026-06-26 → 41건(연식확인 32 + 연식미상 9).
