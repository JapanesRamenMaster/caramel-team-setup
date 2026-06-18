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

### 유료 예약 정의 + 취소율 측정 (★함정: user_service 취소는 soft-delete, DS-1055)
- **유료 예약**(프로모션 무료 제외): `user_service.paid_yn=1` + **0원 VOUCHER 프로모션 제외**(`payment WHERE type='VOUCHER' AND amount=0 AND status='PAID'`인 `reservation_id` 제외). 프로모션 0원 유입이 전환율을 부풀림(단 5/22~6/1 코호트선 1~2%로 작았음 — 채널 뚫리면 커짐).
- **취소율 측정 함정**: `user_service`는 예약 취소 시 `deleted_yn=1`로 **soft-delete**된다. 취소 건을 분모에 넣으려면 **`deleted_yn` 필터를 빼야** 한다 — 안 그러면 취소가 통째로 빠져 취소율이 0%로 왜곡.

### 세차 완료 시각 컬럼 (★함정: reservation_datetime ≠ 완료 시각)
- **`washed_at`**: 실제 세차 완료 처리 시각(UTC). 완료 건 날짜별 집계의 기준 컬럼.
  `DATE(CONVERT_TZ(r.washed_at, '+00:00', '+09:00')) AS wash_date`
- **`reservation_datetime`**: 고객이 예약한 시작 시각(UTC). 실제 완료 시각이 아님.
- 세차 완료수를 날짜별로 집계할 때 `reservation_datetime` 기준으로 짜면 예약일 집계가 된다.
  디테일러가 예약 시간 이후 완료 처리하면 `washed_at`이 다음날 0시 이후일 수도 있음.
- `washed_at`은 status=`WASHED`/`REPORT_SENT`일 때만 NOT NULL 보장.
- **"예약 시점" 일수 측정(가입→예약 며칠, 당일 예약 비중 등)은 `created_at`(예약을 *잡은* 시각) 기준.** `reservation_datetime`(세차 *예정일*)로 재면 왜곡 — "가입 당일 예약" 71%가 14%로 추락한다(세차는 보통 며칠 뒤라). DS-1055.

### 구독 일시정지 상태 (★함정: status='ACTIVE'가 전부가 아님)
- `status='ACTIVE' AND paused_at IS NOT NULL` = **일시정지 상태** (세차 불가, 구독료 정지)
- `status='ACTIVE'` 단독 조건은 일시정지 포함 → "현재 세차 가능한 활성 구독자" 집계 시 왜곡
- **실사용 구독자(일시정지 제외)**: `status='ACTIVE' AND paused_at IS NULL`
- `paused_at`, `ended_at`은 코드에서 KST(`Asia/Seoul`)로 할당 → UTC +9H 변환 불필요

### 시간 변환
- DB는 UTC 저장 → `CONVERT_TZ(reservation_datetime, '+00:00', '+09:00')` 또는 `+ INTERVAL 9 HOUR`
- GROUP BY에 날짜 쓸 때 반드시 KST 변환 후 사용

### 차량 브랜드 필터 (★함정: `car.brand`는 레거시 nullable)
- `car.brand`는 레거시 VARCHAR 컬럼으로 **NULL인 차량이 존재**. `brand IN ('포르쉐','벤츠',...)` 단독으로 쓰면 brand_id만 세팅된 차량이 통째로 누락됨 (2026-06 실사례: 파나메라·S클라스가 조건 충족임에도 탈락).
- **올바른 패턴**: `car_brand` 테이블 조인 사용
  ```sql
  JOIN car_brand cb ON cb.id = c.brand_id
  WHERE cb.name IN ('포르쉐', '벤츠', 'BMW', ...)
  ```
- `car.brand` 직접 필터는 레거시 데이터(구형 등록 차량) 이외엔 신뢰 불가. 항상 `brand_id → car_brand.name` 경로 사용.
- ⚠️ 조건 충족 차량이 결과에서 누락되면 `user_service.applicable_car_id IS NULL`로 귀인하지 말 것 — 첫 의심은 위 `car.brand` 직접 필터다. brand_id만 세팅된 신차(파나메라·S클라스 등)는 데이터 수정이 아니라 쿼리 수정(`JOIN car_brand`)으로 포함된다.
- **국산차 브랜드 목록** (car_brand.name 기준): `'현대', '기아', '제네시스', 'KGM', 'KGM(쌍용)', '르노', '쉐보레', '캠시스', 'GM', '르노삼성', '대우', '삼성'` — 쌍용은 `'KGM(쌍용)'`으로 저장됨 주의. 국산차 제외 시 `cb.name NOT IN (...)` 또는 `brand_id IS NULL` 차량을 별도 분류(등록 오류 가능성).

### 차량 모델 조인 (★함정: `car.car_model_id` 없음)
- `car_model` 테이블 FK 컬럼명은 **`car.model_id`** — `car_model_id`는 존재하지 않아 "Unknown column" 오류 발생.
- 올바른 조인: `LEFT JOIN car_model cm ON c.model_id = cm.id`

### S·A 타겟(신차 출고가 6,500만↑) 판별 — `car_model_target` 뷰 (★함정: car_brand.target_yn 부정확)
- **타겟 = `car_model_target` 뷰** (`launch_price>=6500 → is_target`). `JOIN car_model_target cmt ON cmt.id = c.model_id WHERE cmt.is_target=1`. 출고가 원본은 `car_price`(model_id·launch_price 만원). 고객이 차 여러 대면 `MAX(cmt.is_target)`.
- ❌ **`car_brand.target_yn`(수입차 브랜드 21개 단위)은 부정확** — 제네시스 G90·GV80(국산 6500↑) 통째 누락 + BMW 1시리즈·벤츠 A클래스(타겟 브랜드 저가) 오포함. `car_tier`(T1~T7)도 차 크기 기준이라 출고가 대리변수로 못 씀.
- 뷰 is_target=1 = 220개 모델(2026-06 기준). DS-1055.

### 예약 → 차량 조인 (★함정: `reservation`에 `car_id` 없음)
- `reservation` 테이블엔 차량 FK가 없다. **가장 깔끔한 경로 = `reservation_car`** (reservation_id↔car_id, 거의 1:1).
  ```sql
  JOIN (SELECT reservation_id, MAX(car_id) car_id FROM reservation_car GROUP BY reservation_id) rc
    ON rc.reservation_id = r.id
  JOIN car c ON c.id = rc.car_id
  ```
- 대안: `checkup.car_id`(washed만), `subscription.represent_car_id`. `user_service.applicable_car_id`는 15%만 채워져 부적합.

### `reservation.key_direct_handover_yn` — "다른 사람이 키 전달" 체크박스
- 온보딩/예약 플로우의 "세차 당일 다른 사람이 키를 전달할거예요" 체크박스 값. **TinyInt: 1=대리 전달, 0=본인 직접, null=미설정(구버전 예약, 집계 시 제외)**.
- 프론트 필드명 `isKeyDirectHandover`. 대리인 연락처는 별도 컬럼 없음(예약 확정 시 `reservation.contact`에 덮어씀).

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

## Zone (디테일러 배정 ↔ 예약 위치 매핑)

### 디테일러 할당 zone 판정
- 배정은 `detailer_work_schedule_rule.zone_id` 로 결정 (rule엔 day_of_week뿐 아니라 `zone_id`도 있음)
- 조인: `detailer_work_schedule ws`(detailer_id) → `_rule r`(schedule_id, `deleted_at IS NULL`) → `zone z`(id = r.zone_id)
- 현재 유효 배정만: `UTC_TIMESTAMP() BETWEEN ws.effective_from AND ws.effective_to`
- ⚠️ **`detailer_region` 테이블 쓰지 말 것** — `service_region_id` 기반 구식 구조. zone 배정 판정엔 `detailer_work_schedule_rule.zone_id` 체인만 사용.

### 예약 → zone 매핑 (zone_id 컬럼 없음, polygon으로 판정)
- `reservation`엔 zone_id 없음. `zone.area`는 polygon(SRID 0, 좌표순서 **(lng lat)**)
- ⚠️ **`reservation.latitude/longitude`는 @deprecated** (Prisma 스키마 2026-04-28~). 신규 예약은 `user_address`에만 좌표가 있을 수 있음. Zone 매핑 쿼리는 반드시 COALESCE 패턴:
  ```sql
  JOIN user_address ua ON ua.id = r.address_id
  LEFT JOIN zone z ON ST_Contains(z.area,
    ST_GeomFromText(CONCAT('POINT(',
      COALESCE(r.longitude, ua.longitude), ' ',
      COALESCE(r.latitude, ua.latitude), ')'), 0))
  ```
- `r.latitude` 단독 사용 시 신규 예약이 NULL로 처리돼 zone 매핑에서 누락됨.
- 어느 zone에도 안 들어가면 z가 NULL → 미커버/이탈 후보

### ⚠️ reservation.location 함정
- `reservation.location`은 geometry가 **아니라 text** 타입이고 인코딩이 깨져 있음
  (`ST_AsText`/`ST_SRID` 시도 시 `Geometry byte string must be little endian` 오류)
- 위치는 반드시 `latitude` / `longitude` (decimal(11,8)) 컬럼을 쓸 것

### 예약 → 날씨 조인 (★함정: forecast_log dedup 필수)
- 날씨 데이터는 `forecast_log` 테이블. `reservation`엔 `weather_condition` 컬럼 없음.
- **같은 zone+date에 row가 여러 개** 쌓임 → `ROW_NUMBER() OVER (PARTITION BY zone_id, forecast_date ORDER BY forecasted_at DESC)` 로 dedup 필수. 없으면 예약당 날씨가 여러 건 붙어 중복 발생.
- **`zone_rain_log` 테이블은 드롭됨** — 마이그레이션에서 보이더라도 사용 불가. `forecast_log`만 사용.
- 예약→날씨 경로: `reservation` → `zone` (polygon join, COALESCE 패턴) → `forecast_log` (zone_id + forecast_date)

### 야외/실내 주차장 필터 (★함정: reservation에 없음, user_address 조인 필수)
- 주차장 유형은 `reservation`에 없고 `user_address.parking_lot_type`에 있음.
- 값: `'OUTDOOR'`(야외), `'INDOOR'`(실내), **`NULL`(48k건, 미등록)**.
- ⚠️ **NULL ≠ OUTDOOR** — NULL은 유형 미등록이므로 야외 필터 시 `= 'OUTDOOR'` 명시 필수. `!= 'INDOOR'`로 쓰면 미등록 주소가 모두 포함됨.
- 패턴: `JOIN user_address ua ON r.address_id = ua.id WHERE ua.parking_lot_type = 'OUTDOOR'`

### 예약 작업 주소 = reservation 스냅샷 (★함정: user_address 고치지 말 것)
- 디테일러 앱/알림이 읽는 작업 주소는 **`reservation.location` + `detailed_location` 스냅샷**.
  `address_id`(→`user_address`) join이 **아니다**.
- 좌표도 `reservation.latitude/longitude` 우선, 둘 다 NULL일 때만 user_address fallback
  (`COALESCE(r.latitude, ua.latitude)`). caramel-zero `apps/api` 기준.
- **일회성 작업지 변경(이번 건만 다른 주소)은 `reservation`의
  `location`/`detailed_location`/`latitude`/`longitude` 4필드만 UPDATE.**
  `address_id`·`user_address`는 건드리지 말 것 — 고객 저장 주소(집)를 고치면 향후 예약까지 오염.
- 새 좌표는 NAVER 지오코딩: `GET https://naveropenapi.apigw.ntruss.com/map-geocode/v2/geocode?query=<주소>`,
  헤더 `x-ncp-apigw-api-key-id` / `x-ncp-apigw-api-key`
  (키: caramel-zero `.env.dev`의 `NAVER_MAPS_GEOCODE_CLIENT_ID/SECRET`). 응답 `addresses[0].x`=lng, `.y`=lat.

### 서비스 가능 지역 조회 (service_region)
- 컬럼: `sido`(시/도), `sigungu`(시/군/구), `dong`(동), `available_yn`(1=가능)
  - ⚠️ `city`, `district`, `name` 컬럼 **없음** — 쿼리 작성 시 그 이름 사용 금지
- ⚠️ **`sigungu` 통합값 함정**: `"화성시"` 단독 행 없음. 구 분리 시 `"화성시 동탄구"`, `"화성시 병점구"` 형태로 저장. `= '화성시'`로 쓰면 이 행들 누락 → **LIKE `'%화성%'`** 사용
- 세차 가능 여부: `available_yn = 1`
- 표준 조회 패턴:
  ```sql
  SELECT srg.name AS srg_name, sr.sido, sr.sigungu, sr.dong, sr.available_yn
  FROM service_region sr
  JOIN service_region_group srg ON srg.id = sr.service_region_group_id
  WHERE sr.sigungu LIKE '%화성%'        -- 시 단위 필터는 LIKE 필수
    AND sr.available_yn = 1;
  ```

## 마케팅 데이터 소스

광고비 + Attribution 데이터는 외부 소스(Meta, Naver, Google, Airbridge)에서 동기화되어 별도 일별 집계 테이블에 적재됨. 분석 쿼리는 이 테이블들을 사용.

| 테이블 | 출처 | 주요 컬럼 | 적재 |
|---|---|---|---|
| `meta_daily_performance` | Meta Ads API | `date`, `total_spending`, `total_purchase_value`, `total_purchase`, `avg_cac` | Apps Script (마케팅 대시보드) |
| `naver_daily_performance` | Naver Search Ads API | `date`, `total_cost`, `impressions`, `clicks`, `conversions` | Apps Script `SyncNaverSpend.gs` |
| `google_daily_performance` | Google Ads API | `date`, `total_cost`, `impressions`, `clicks` | Apps Script `syncGoogleAdsSpendToDB` (매일 10:00 KST) |
| `airbridge_daily_install` | Airbridge MMP | `event_date`, `install_users` | Apps Script `SyncAirbridgeInstall.gs` (매일 11:00 KST) |
| `user_attribution` | App SDK (Airbridge attribution) | `user_id`, `source`, `channel`, `campaign` | NestJS app 직접 적재 (가입 시점) |

### ★ 총 광고비 집계 (반드시 3개 채널 합산)
```sql
SELECT DATE(date) AS dt, SUM(cost) AS total_cost FROM (
  SELECT date, total_spending AS cost FROM meta_daily_performance WHERE date BETWEEN :from AND :to
  UNION ALL
  SELECT date, total_cost AS cost FROM naver_daily_performance WHERE date BETWEEN :from AND :to
  UNION ALL
  SELECT date, total_cost AS cost FROM google_daily_performance WHERE date BETWEEN :from AND :to
) sub GROUP BY dt ORDER BY dt
```
⚠️ **`meta + naver`만 합산하면 Google 누락으로 20~30% 과소 집계됨** (2026-06-08 실사례: 6/6일 Meta 19.3만 + Naver 7.7만 = 27만, 실제 47만. Google 20.7만 누락).

### Mixed CAC 분모 옵션

- **설치**: `airbridge_daily_install.install_users` (모든 채널 합산, paid + organic, unique user)
- **회원가입**: `app_user.created_at` 기준 신규 가입자 수
- **차량 등록**: `car.created_at` 첫 차 등록 시점
- **주소 등록**: `user_address.created_at` 첫 주소
- **첫 결제**: `payment.paid_at` 첫 결제 (`status IN ('PAID','PARTIAL_CANCELED')`, `amount > 0`)
  - 세차 서비스 신규 고객 기준이면 `type IN ('VOUCHER','SUBSCRIPTION')`도 추가할 것. OPTION/PACKAGE가 먼저 들어올 수 있어 단순 MIN(paid_at)이 틀린 결과를 낸다.

각 funnel 단계별 CAC = **(Meta + Naver + Google 광고비 합산)** / 해당 단계 unique user 수.

### 알라미 보고서 데이터 소스 (★ DB 직접 쿼리 아님)
- 알라미 = 매일 10:10 KST 슬랙 발송되는 마케팅 성과 일일 리포트
- **광고비 수치**: `데일리 캠페인 트래커` Google Sheets에서 읽음 (DB 직접 조회 아님)
  - 오늘(Row 3): Meta + Naver + Google 합산 수식 (정상)
  - 전일(Row 7): Meta + Naver + Google 포함 (2026-06-08 버그 수정 완료)
- **광고비 적재 타이밍**: Meta/Naver는 09:00 KST 수집, Google은 10:00 KST 수집
- 알라미 수치 이상 시: DB 3개 테이블 직접 조회로 크로스체크할 것

## 서비스 상품 (`service`) — 같은 이름도 내용이 다름 (★함정)

- 같은 이름 계열이라도 `description`이 다르다. 예: `올클린 케어 (29)`/`(39)`/`(49)`는 **"내·외부 방문세차 + 프리미엄 왁스코팅"**, `(55)`/`(35)`는 **"내·외부 방문세차"**(왁스코팅 없음), `(45)`는 **"(아파트 전단지)"**.
- 상품을 비교·집계·설명할 때 `name`만 보고 "내용 동일"로 단정하지 말 것. 반드시 `description`(필요시 `wash_type`, 옵션)도 함께 조회·출력해 차이를 확인한다.

## 쿠폰/프로모션 성과 분석 (★함정: `coupon` 테이블 없음, 발급≠사용)

- 테이블: `coupon_code`(개별 코드 — `code`·`name`·`total_supply_count`), `coupon_campaign`(파트너 캠페인 — **`partner_name`** 필드), `coupon_code_reward`(보상 정의), `coupon_code_usage`(사용 이벤트 — `user_id`). **`coupon`/`discount` 테이블은 없다.**
- ★코드명 LIKE 검색 오탐: `name`/`code LIKE '%KCC%'` 류는 **랜덤 발급코드**(예: "토스 유저 쿠폰"의 `YKCCHAZB`)가 대량 매칭된다. 파트너 프로모션은 보통 사람이 정한 값(예: `voucher_kcc`) — 정확 매칭으로 특정하고, 우연 매칭은 `name`으로 걸러낼 것.
- 쿠폰 → 발급 세차권 조인: `coupon_code_reward.id` → **`user_service.coupon_code_reward_id`**. 한 쿠폰이 SERVICE+OPTION 등 reward 여러 행을 가지니 `IN (reward_ids)`로 묶는다. 보상 정체 = `coupon_code_reward.reward_id` → `service.id`/`options.id` (`reward_type`으로 구분).
- ★전환 퍼널 = 발급≠사용: ① `coupon_code_usage`(쿠폰 사용=세차권 수령) → ② `user_service.reservation_id IS NOT NULL`(예약 생성) → ③ `reservation.status='WASHED'`(실제 완료). 무료 쿠폰은 ①→②에서 대량 이탈하므로(KCC: 194 발급 → 67 예약 → 64 완료) "사용 수"만 보면 전환을 과대평가.
- ★리텐션/매출은 두 소스 교차검증: 코호트 추가 매출은 `user_service.paid_amount`(paid_yn=1, 무료 reward 제외) **와** `payment`(status='PAID', paid_at) 양쪽으로 확인. 무료세차 *당일* 결제는 현장 옵션 업셀이지 재방문이 아니다 — `payment.paid_at > 무료세차 washed_at`로 진짜 재방문만 분리.
- ★발급수는 쉘 계정으로 부풀려진다(보이저 파밍): 무료 쿠폰 코호트엔 **`app_user.phone IS NULL` + 랜덤 7자 이름(`name REGEXP '^[A-Za-z0-9]{6,8}$'`) + 예약 0건**인 가짜 계정이 대량 섞인다(voucher_kcc: 194 중 127). 전화 없으면 예약 자체가 불가하므로 실사용자 모수는 **`phone IS NOT NULL`**로 거른다. 어뷰징 점검 시: ① `user_address.address`+`detail_address`로 세대 묶어 다중 무료세차 탐지, ② 같은 주소에 몰린 쉘 생성 버스트(`created_at` 시간대별 COUNT), ③ `app_user.dealer_id`/`created_by`로 딜러 경유 여부, ④ 코호트 `phone`을 `detailer.phone`(하이픈 제거 비교)과 대조해 디테일러 셀프-어뷰징 확인.

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

## 시계열 교란변수 — 외부만구독 런칭(2025-10-05)

- **월2회·월4회 외부만 구독 상품 런칭: 2025-10-05**
- 2025-10 전후를 단순 비교하면 아래 지표가 런칭 효과를 포함해 왜곡된다:
  재방문율, 외부만 비중, 디테일러 생산성, 세차당 소요시간
- YoY/MoM 비교 시 반드시 외부만구독 세그먼트를 분리해 분석할 것
- **외부만구독 필터**: `service.wash_type = 'OUTSIDE'` AND `reservation.subscription_id IS NOT NULL`
  (product_id 기준 목록은 별도 확인 필요 — DB에서 `SELECT id, name FROM product WHERE name LIKE '%외부%'`)

## 사진 테이블 구조 (★함정: 두 테이블이 다른 컬럼명으로 전/후 구분)

세차 전/후 사진은 **`wash_result_image`** 가 메인 테이블 (신규), `reservation_image`는 구버전.

| 테이블 | 전/후 구분 컬럼 | 값 |
|--------|--------------|------|
| `wash_result_image` | `status` | `'BEFORE'` / `'AFTER'` |
| `reservation_image` | `type` | `'BEFORE_WASH'` / `'AFTER_WASH'` |

### wash_result_image JOIN 패턴
```sql
-- wash_result_image → reservation
JOIN wash_result wr ON wr.id = wri.wash_result_id AND wr.deleted_yn = 0
JOIN reservation r ON r.id = wr.reservation_id
WHERE wri.deleted_yn = 0
```

### 이미 있는 평가 컬럼 (현재 전량 PENDING — 미사용 상태)
```sql
evaluation_status  VARCHAR(50)  DEFAULT 'PENDING'
evaluated_at       DATETIME
evaluator          VARCHAR(50)
```

### BEFORE/AFTER 섹션 종류
외부: `OUTSIDE_FRONT`, `OUTSIDE_DRIVER_SIDE`, `OUTSIDE_PASSENGER_SIDE`, `OUTSIDE_FRONT_GLASS`, `OUTSIDE_DRIVER_SIDE_WHEEL`
내부: `INSIDE_DRIVER_SEAT`, `INSIDE_CENTER_FASCIA`

### 전/후 쌍이 있는 예약 추출 (기준: 최근 1일)
```sql
SELECT wr.reservation_id
FROM wash_result wr
WHERE wr.deleted_yn = 0
  AND wr.created_at >= DATE_SUB(NOW(), INTERVAL 1 DAY)
  AND EXISTS (SELECT 1 FROM wash_result_image WHERE wash_result_id = wr.id AND status = 'BEFORE' AND deleted_yn = 0)
  AND EXISTS (SELECT 1 FROM wash_result_image WHERE wash_result_id = wr.id AND status = 'AFTER' AND deleted_yn = 0)
```
규모: 전/후 둘 다 있는 예약 **~139건/일** (2026-06-10 기준)

## 타이어 마모도 조인 경로 (★함정: report_card에 reservation_id 없음)

- `report_card`에는 `reservation_id` 컬럼 없음. 경로: `reservation → report (report.reservation_id) → report_card (rc.report_id = rp.id)`.
- 타이어 마모도 타입: `rc.type IN ('TIRE_TREAD', 'TIRE_SUMMARY')`. 값은 JSON `data` 컬럼에 저장.
- ⚠️ 세차 완료 전 예약(미래·CONFIRMED)은 `report` 자체가 없어 NULL — 반드시 `LEFT JOIN` 사용.
```sql
LEFT JOIN report rp ON rp.reservation_id = r.id AND rp.deleted_yn = 0
LEFT JOIN report_card rc ON rc.report_id = rp.id AND rc.deleted_yn = 0
  AND rc.type IN ('TIRE_TREAD', 'TIRE_SUMMARY')
```

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
