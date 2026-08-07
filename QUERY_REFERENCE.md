# Caramel DB 쿼리 레퍼런스

caramel-prod DB 분석 쿼리 시 반드시 따를 규칙. `grafana-audit/CLAUDE.md`와 함께 참조.

---

## 0. 모든 쿼리 체크리스트

모든 쿼리를 짜기 전 아래 세 가지를 반드시 확인한다.

- **테스터 제외** — `deleted_yn=0, test_yn=0, temp_yn=0` (앱 유저 기준). 디테일러는 → §3a
- **UTC→KST 변환** — DB 전체 UTC 저장. 날짜 집계 전 반드시 변환 → §5a
- **유령예약 제거** — CONFIRMED 포함 예약 집계 시 `user_service` + `car` 존재 여부 확인 → §2b
- **차량/타겟(고가차) 분석** — `reservation`엔 car_id 없음. **`reservation_car` 경유**가 정본 → §2d (⚠️ `user_service.applicable_car_id`는 ~60% NULL 함정). 타겟 판별 = `car_model_target.is_target` → §2d
- **행 나열 + 합계 함께 제시 시 합계는 SQL로** — 합계·상태별 건수를 답변에서 손으로 세지 말고 `GROUP BY status` 별도 쿼리로 산출해 행 수와 일치하는지 확인 (실사례: 39행 받아놓고 답변에서 35건으로 오기)
- **dev에서 검증할 때 prod의 `service.id`를 그대로 쓰지 말 것** (2026-08-06 실측) — dev와 prod는 `service.id`가 다르다: prod `137`=`프리미엄 세차 패키지 올클린 케어`인데 **dev `137`=`[B2B] 외부만`**이고, prod `120`(반얀)·`140`(자스민)·`142`는 **dev에 없다**. 이 문서의 id는 **전부 prod 기준**이므로 dev 쿼리·dev E2E 테스트는 `service.name LIKE`로 id를 먼저 되찾아 쓴다. ⚠️틀려도 에러가 안 나고 0건이 나와서 "기능 미동작"으로 오판하게 된다

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

⚠️ **`user_service` 경로로 예약을 붙일 때도 status 화이트리스트 필수** — 세차권에 CANCELED 예약이 연결된 채 남는 경우가 실제로 있어(취소 후 반납된 캠페인 세차권 등), status 필터 없는 LEFT JOIN은 취소·미확정 건을 유효 예약처럼 보이게 한다. 표준 패턴:
```sql
LEFT JOIN reservation r ON r.id = us.reservation_id
  AND r.deleted_yn = 0
  AND r.status IN ('WASHED', 'REPORT_SENT', 'CONFIRMED')
```
CONFIRMED가 포함되므로 §2b 유령예약 체크(`car` EXISTS)도 함께 적용.

### 2b. 유령예약 제거 (CONFIRMED 집계 시 필수)

반복구독 고객의 미래 예약은 배치 생성되는데, 세차권(`user_service`)이 없거나 차량(`car`)이 삭제됐거나 **고객이 탈퇴(`app_user.deleted_yn=1`)** 한 상태로 CONFIRMED가 남아 있을 수 있음. 이 유령예약이 집계에 포함되면 과다 카운트.

**예약수 세는 모든 쿼리에 아래 세 조건 추가 필수:**
```sql
AND EXISTS (SELECT 1 FROM user_service us WHERE us.reservation_id = r.id AND us.deleted_yn = 0)
AND EXISTS (SELECT 1 FROM reservation_car rc JOIN car c ON rc.car_id = c.id WHERE rc.reservation_id = r.id AND c.deleted_yn = 0)
AND EXISTS (SELECT 1 FROM app_user u WHERE u.id = r.user_id AND u.deleted_yn = 0)
```

WASHED 완료 건만 세는 쿼리엔 실질적 영향 없음. CONFIRMED 포함 집계에서 특히 중요.

⚠️ **고객 탈퇴 축(`app_user.deleted_yn`)을 빠뜨리기 쉬움.** 디테일러앱/어드민 예약목록 API(caramel-api `careplus-detailer.service.ts`)는 Prisma where에 `user:{deleted_yn:0}`(user 모델=`@@map("app_user")`)를 걸어 **탈퇴 고객 예약을 노출하지 않는다** — 특히 QA 테스트 계정(name='asdf' 등)이 탈퇴 후 CONFIRMED 예약만 잔존하는 경우가 흔함. 세차권·차량만 체크하면 이 유령이 남아 이중예약/충돌 검출에서 오탐(2026-07-21 충돌감사 크론이 김민호 동시각 2건으로 오보 — 1건은 탈퇴고객 유령).

🔴 **탈퇴 고객 유령예약은 "안 보일" 뿐 슬롯은 실제로 점유한다. 그리고 zero 어드민 API로는 못 지운다 (2026-08-06 실측).**
- **점유**: 재배정 후보를 찾을 때 `그 시각 예약 있음`으로 잡혀 멀쩡한 후보를 탈락시킨다(8/7 실사례 — 안용희170 10:00·한승헌218 16:00이 각각 탈퇴 QA 계정 예약에 막혀 있었고, 청담 10:00 대체 후보 산정이 실제로 왜곡됐다). ⟹ **§3c 후보 탐색 쿼리의 `res` CTE에도 위 3조건(특히 `app_user.deleted_yn=0`)을 걸 것.**
- **삭제 경로**: `POST /v1/admin/users/{userId}/reservations/bulk-cancel`(zero-api)은 `assertTargetUserExists`가 먼저 걸려 **404 `고객을 찾을 수 없습니다`** 로 거부된다 — 탈퇴 유저라 어드민 화면·API 어느 쪽으로도 손댈 수 없다. **우회 = sales-admin 레거시** `POST https://gateway-prod.thetrive.com/careplus/reservations-admin/{reservationId}/cancel` `{"reason":"CARAMEL_PROBLEM","detailReason":"…"}` (userId를 안 받아 탈퇴 계정도 통과, HTTP 201 → `[{"id":…}]`). `reason` enum = `CUSTOMER_PROBLEM`(→REFUND)·`CARAMEL_PROBLEM`/`RAIN`(→GIVE_BACK_WITHOUT_CHARGE) 3종뿐이고, **테스트/정리성 취소엔 환불이 걸리지 않는 `CARAMEL_PROBLEM`**을 쓸 것.
- **찾는 쿼리**: `JOIN app_user au ON au.id=r.user_id WHERE au.deleted_yn=1 AND r.deleted_yn=0 AND r.status IN ('CONFIRMED','IN_PROGRESS') AND r.reservation_datetime >= NOW()` — 과거 날짜인데 CONFIRMED로 남은 것도 같이 훑을 것(적재·완료율 분모를 오염시킨다).

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

**⚠️ 외부공급/B2B 더미 차량 = `car.plate_number='00가0000'` (검증 2026-07-29)**
- 활성 83대·소유자 81명, 세차 587건. 차주명이 사람 이름이 아니라 `한남 테슬라`·`마이바흐`·`벤틀리` 같은 **물량 단위 계정**(딜러·제휴 공급).
- 🔴 **차량 단위 집계(차량당 세차 횟수, 기록 깊이, 최다 세차 차량)에서 반드시 제외.** 미제외 시 상위가 통째로 오염된다 — 실측: 최다 357회(한남 테슬라)·123회(마이바흐)·100회(벤틀리) vs **제외 후 실고객 최다 70회**. 총량 영향은 1.4%로 작지만 분포 상단은 치명적.
- `app_user.test_yn`·블랙리스트로는 걸러지지 않는다(정상 고객 계정으로 등록돼 있음). 필터: `IFNULL(c.plate_number,'') <> '00가0000'`.

**⚠️ `reservation.reservation_datetime`에 zero-date 행이 있다 (검증 2026-07-29)**
- `< '2020-01-01'` 또는 NULL인 행 **2,538건**(대부분 CREATED 유령, CANCELED 684건, WASHED는 7건뿐).
- 🔴 `MIN(reservation_datetime)`이 **1970-01-01**을 반환한다 → "서비스 언제부터"·최초 세차 시점 판정이 통째로 틀린다. **실제 최초 = 2024-01-19.**
- 기간 시작점을 뽑을 땐 `WHERE reservation_datetime > '2020-01-01'` 하한을 걸 것. WASHED 기준 손실은 7건으로 무해.

**⚠️ "다차(2대+) 유저" 정의 — 등록 기준 금지**
- 등록 차량(`car` 활성 2대+) 5,913명 vs 실제 2대+ 세차(WASHED) 1,484명 — **등록 기준은 ~4배 과대** (검증 2026-06-26).
- 다차 세그먼트/리텐션 분석의 모수 = `reservation_car` 경유 `COUNT(DISTINCT car_id) >= 2` (WASHED 기준).

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
- 🔴 **`model_id`가 NULL인 실차가 실존한다** (2026-08 기준 233대·148명, `deleted_yn=0 AND temp_yn=0`). 어드민·디테일러 차량등록 API가 modelId 없이도 INSERT를 허용해서 생긴다. ⟹ **`INNER JOIN car_model`이나 `JOIN car_model_target cmt ON cmt.id=c.model_id`로 티어·타겟을 집계하면 이 차량들이 조용히 분모에서 사라진다.** "차량 수가 안 맞는다" 싶으면 `SUM(c.model_id IS NULL)`을 먼저 세볼 것. 모수 카운트는 `deleted_yn=0 AND temp_yn=0` **둘 다** 필요(제품 코드도 `temp_yn: false`로 필터하므로 이게 실제 영향 모수와 일치).
- 참고: 이 row는 고객 차량목록 API(`/v1/vehicles/garage`·`/v1/my-garage`)를 **404로 깨뜨려 그 고객은 예약을 못 한다**. 발견하면 제품팀에 알릴 것. (마이차고 화면은 `/v1/me`를 써서 정상으로 보이는 비대칭이 있음 — 브랜드 없이 번호판만 뜨는 차량이 시그널.)

**원부 이력 `car_wonbu_history` — 브랜드 컬럼 없음**
- 있는 컬럼: `plate_number, search_number, mileage, registered_at, final_registered_at, inspection_valid_start_at, inspection_valid_end_at, model, type, vin, car_year, color, form, engine_type, capacity, is_commercial_car, deleted_yn, requested_at, created_at`.
- **`brand` 컬럼은 없다** — 쓰면 "Unknown column 'brand'". 브랜드는 `car.brand_id → car_brand` 경유. 차종 문자열은 `model`, 연식은 `car_year`.
- 조인 키는 `plate_number`(car_id 아님). 번호판이 원부에 아예 없는 차량도 있으니 `LEFT JOIN` + NULL 처리.

**차종 티어(T1~T7) 판정 — `car_model.tier_id` → `car_tier.tier`**
- `car`에도 `car_model`에도 **티어 숫자 컬럼은 없다**. 정본은 `car_tier.tier`(int).
- 전체 경로: `car c JOIN car_model cm ON c.model_id=cm.id JOIN car_tier ct ON cm.tier_id=ct.id` → `ct.tier`. 브랜드까지 붙이려면 `JOIN car_brand cb ON cm.brand_id=cb.id`.
- ⚠️ **`product.product_type='TIER_1'~'TIER_7'`은 "이 상품이 몇 티어용인가"이지 "이 차가 몇 티어인가"가 아니다.** 차종 티어를 product에서 찾으면 헛다리 — 상품 가격표(1회권 정가 등)를 볼 때만 쓴다.
- 티어는 차 크기·작업량 기준(출고가 아님 — 아래 타겟 판별 참조). 실측 예(2026-07): T4=GV70·GLC·X3·S클래스·911·XC60·파나메라·마칸 / T5=GV80·카이엔·X5·GLE·G클래스·레인지로버.

**S·A 타겟(신차 출고가 6,500만↑) 판별 — `car_model_target` 뷰**
- `JOIN car_model_target cmt ON cmt.id = c.model_id WHERE cmt.is_target = 1`
- ❌ `car_brand.target_yn`(수입차 브랜드 21개 단위)은 부정확 — 제네시스 G90·GV80 누락 + BMW 1시리즈·벤츠 A클래스 오포함.
- `car_tier`(T1~T7)도 차 크기 기준이라 출고가 대리변수로 못 씀.
- 뷰 `is_target=1` = 220개 모델(2026-06 기준).

**⚠️ 타겟 "고객" 판별 3패턴 — 패턴에 따라 숫자가 다르다 (세컨카 포함/제외 차이)**
- **패턴 A (세차 건)**: `reservation_car`→`car`→`car_model_target` — 세차한 그 차가 타겟인지. 타겟 유저가 비타겟 세컨카로 세차하면 제외됨.
- **패턴 B (유저)** ✅ **타겟 고객 분석 표준**: 유저가 타겟차 1대+ 보유 → 그 유저의 세차·결제 전부 포함 (비타겟 세컨카 세차도 포함).
  ```sql
  target_users AS (
    SELECT DISTINCT c.user_id FROM car c
    JOIN car_model_target cmt ON cmt.id = c.model_id
    WHERE c.deleted_yn = 0 AND cmt.is_target = 1
  )
  -- 이후 JOIN target_users tu ON tu.user_id = r.user_id
  ```
- **패턴 C (첫차)**: 유저의 첫 등록차가 타겟인지 — 신규 등록 코호트 지표에만.
- 같은 "타겟 비율"이라도 A/B/C 숫자가 다르다 (실측: B 전환 시 고객수 +7%, 침투율 +5%p). **타겟 고객 분석은 B로 통일** (CBR v2 표준). 예외: 침투율 분모=전체 유입(타겟 필터 없음), 타겟차 신규 등록수=패턴 C 유지.

**검사임박(정기검사 만료) 차량 조회 — `car.next_car_inspection_at`**
- ⚠️ **타임존 트랩**: `next_car_inspection_at`은 UTC 저장이나 값이 **KST 자정**이라 raw가 `...15:00:00`로 보임 (예 raw `2026-08-12 15:00:00` = 검사만료 KST `2026-08-13`). **raw로 D±N 윈도우 필터하면 하루/타임존 어긋남** → 반드시 `DATE(CONVERT_TZ(c.next_car_inspection_at,'+00:00','+09:00'))` 후 비교. `last_wonbu_at`(마지막 원부조회 시각)도 UTC 저장 → KST 표기 시 CONVERT_TZ.
- 표준 패턴 (타겟 + 실고객 + D+20~D+30 예시):
  ```sql
  SELECT c.plate_number, cm.name, c.model_year,
    DATE_FORMAT(CONVERT_TZ(c.next_car_inspection_at,'+00:00','+09:00'),'%Y-%m-%d') AS insp_end_kst
  FROM car c
  JOIN car_model_target t ON c.model_id=t.id AND t.is_target=1   -- 타겟
  LEFT JOIN car_model cm ON c.model_id=cm.id
  JOIN app_user u ON c.user_id=u.id
  WHERE c.deleted_yn=0 AND (c.temp_yn IS NULL OR c.temp_yn=0)      -- 실차
    AND u.test_yn=0 AND u.phone IS NOT NULL                        -- 실고객
    AND DATE(CONVERT_TZ(c.next_car_inspection_at,'+00:00','+09:00'))
        BETWEEN DATE_ADD(CURDATE(),INTERVAL 20 DAY) AND DATE_ADD(CURDATE(),INTERVAL 30 DAY)
  ```
- **원부 배치 재조회는 `next_car_inspection_at`을 갱신한다** (`curl -sG gateway-prod.thetrive.com/careplus/wonbu --data-urlencode carPlateNumber=<판>`, 무인증, 건당 `#caramel_원부조회` 채널 게시). ⟹ 재조회 후 검사완료 차량은 만료일이 미래로 밀려 **윈도우 밖으로 이동**하므로, "재조회 → 같은 윈도우 재쿼리" 시 대상 수가 줄어드는 게 정상. 임시/말소 번호판은 HTTP 500(원부서버 미반환).

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

**건물·단지 단위 집계 — `apartment_yn`으로 오피스 오염을 제거한다 (2026-08-04)**

`user_address.building_name` GROUP BY로 "어느 단지에 우리 고객이 사는가"를 뽑으면 **서울오토갤러리(딜러 상사)·캐피탈타워·한국지식재산센터 같은 오피스가 섞인다.** 이름으로 수동 배제하지 말 것 — `apartment_yn = 1` 한 컬럼으로 전량 걸러진다(실측: 강남3구+용산 상위 120개 단지에서 오염 0건).

```sql
FROM user_address ua
WHERE ua.sigungu IN ('강남구','서초구','송파구','용산구')
  AND ua.apartment_yn = 1
  AND ua.deleted_yn = 0
GROUP BY ua.building_name, ua.sigungu
HAVING COUNT(DISTINCT ua.user_id) >= 5   -- 오탈자성 1~2건 단지 제거
```
- **좌표는 `user_address`에 내장돼 있다** — 단지 지도·지오코딩이 필요하면 `ua.latitude`/`ua.longitude`를 그대로 쓴다. 외부 지오코딩 API를 다시 태울 필요 없음(실측 좌표 확보율 120/120 = 100%).
- 타겟 차량 수는 `reservation_car`→`car`→`car_model_target` 경유(§2d 패턴 A). 단지별 세차 건수는 재현되지만 **고객 수는 DB가 누적이라 과거 기록값보다 계속 커진다** — 시점을 병기할 것.

### 2f. Zone 매핑 (ST_Contains)

- `reservation`엔 `zone_id` 없음. `zone.area`는 polygon(SRID 0, 좌표 순서 **(lng lat)**)
- 경로: reservation → COALESCE 좌표(§2e) → `ST_Contains(zone.area, POINT(lng lat))`
- 어느 zone에도 안 들어가면 z가 NULL → 미커버/이탈 후보
- ⚠️ **거리 계산도 SRID 0으로 통일할 것.** `ST_Distance_Sphere`에 SRID **4326**을 쓰면 `Latitude out of range` 에러로 죽는다(4326은 **위도-경도** 순서를 강제하는데 우리 좌표는 경도-위도). polygon과 축을 맞춰 **SRID 0 + `POINT(경도 위도)`**:
  ```sql
  ST_Distance_Sphere(ST_GeomFromText('POINT(127.0097435 37.5500494)',0),
                     ST_GeomFromText(CONCAT('POINT(',lng,' ',lat,')'),0)) / 1000  -- km
  ```
- ⚠️ **zone 폴리곤이 아예 없는 구가 있다**(중구·광진·양천·동작·관악·종로 등). 그 주소는 최근접 fallback으로 엉뚱한 zone에 떨어진다(예: 중구 신당동 → Z9). **"존 외"로 잡힌 건이 실은 폴리곤 공백 산물일 수 있으니, 존 일치를 목표로 삼기 전에 실거리부터 볼 것.**
- ⚠️ **반대로 폴리곤이 행정구역을 넘어 과하게 뻗은 경우도 있다.** 실측(2026-07-26): **성남시 중원구 여수동(127.12757, 37.41799)은 `ST_Contains`상 Z16(강동/송파) 단독 포함**이고 Z0(성남)은 미포함(convex hull에만 걸림). ⟹ **성남 예약이 Z16 담당자에게 붙는 것은 시스템상 "정상"**이다. 행정구역명과 zone 이름이 안 맞는다고 곧바로 오배정을 선언하지 말고 `ST_Contains`로 실판정할 것.

### 2g. source_type 능동/자동 구분

- **고객 직접(능동)**: `source_type IS NULL OR source_type = 'CUSTOMER_DIRECT'` — 대부분의 고객 예약 (NULL이 절대다수, 약 85%)
- ⚠️ **`source_type IS NULL`을 곧바로 "고객 직접"으로 쓰면 안 된다 (2026-08-06 실측, DS-1830).** `booked_online_yn`으로 갈린다.
  - NULL + `booked_online_yn=0` = **어드민 생성** (2026-06-01~ 541건, 7월 change_log 389건 전부 `ADMIN_RESERVATION_CREATED`).
  - NULL + `booked_online_yn=1` = 5,841건(동기간). `*_RESERVATION_CREATED` change_log가 없는 경로라 **능동으로 단정 금지.**
  - ⚠️ **`CUSTOMER_DIRECT` + `booked_online_yn=1`도 "고객이 직접 골랐다"의 증거가 아니다.** 빙의(`POST /users-admin/{id}/access-token`)와 전화 안내가 같은 지문을 만든다. 고객 자발성 판정은 **선행 이벤트(세차권 발급 등)와의 시간차**로 — 수분 이내면 CS 오케스트레이션이다.
- **제외 대상(자동/관리자)**:
  - `CHECKOUT_SETTLEMENT`: 구독 결제 시 자동 배치 예약
  - `RAIN_RETOUCH`: 비 오는 날 재세차 자동 배정
  - `MANUAL_EVENT_IMPORT`: 관리자 수동 입력
- ⚠️ `reserved_with_date` 컬럼은 레거시 — 능동/자동 구분에 사용 불가. 실제 분포: 0=~12500건, 1=98건뿐.

### 2h. "중복 예약" 신고 진단 — 신고된 날짜/시각으로 좁혀 검색하지 말 것

디테일러/CS가 "N시·M시 중복 예약"이라 신고해도 **그 날짜에 해당 시각 예약이 아예 없을 수 있음** (2026-07-19 실사례: "4시·6시 중복" 신고 → 당일엔 18시 1건뿐, 실체는 7/31 18시 + 8/3 16시).

- 실체는 대개 **구독 자동예약 클러스터 쌍**: 같은 배치(`created_at` 동일)로 생성된 2건이 ±7일 날짜밀림으로 며칠 간격까지 붕괴한 것.
- 진단 절차: 신고 시각으로 검색 → 없으면 **고객의 CONFIRMED 전체를 `created_at` 배치별로 묶어** ① 배치 쌍 간격 붕괴(2주 미만) ② 월별 건수가 플랜(월 N회) 초과인지 확인.
```sql
SELECT id, DATE_FORMAT(CONVERT_TZ(reservation_datetime,'+00:00','+09:00'),'%Y-%m-%d %H:%i') dt_kst,
       created_at FROM reservation WHERE user_id=? AND status='CONFIRMED' ORDER BY reservation_datetime;
```
- 처리는 어드민 API `bulk-cancel` + `ticketAction: GIVE_BACK`(세차권 반환, §5c 재발급 메커니즘 참고). DB 직접 UPDATE 금지.

### 2i. "세차 시작 오조작" 되돌리기 = 3행 세트. status만 바꾸면 재시작이 안 된다 (2026-08-07 실측)

디테일러가 실수로 "세차 시작"을 누른 예약을 세차 전으로 돌릴 때. `POST /v1/detailer/reservations/:id/start`(zero `prisma-detailer-reservation.repository.ts startReservation`)는 한 트랜잭션에서 **①`reservation.status='IN_PROGRESS'` ②`reservation_status_log` 1행 ③`wash_result` 1행 ④`checkup` 1행**을 만든다.

- 🔴 **`startReservation`은 살아있는 `wash_result` + `checkup`이 둘 다 있으면 그걸 그대로 반환하고 status를 건드리지 않고 조기 리턴한다.** 그래서 status만 `CONFIRMED`로 되돌리면 **디테일러가 버튼을 다시 눌러도 IN_PROGRESS로 안 돌아온다**. 디테일러앱도 `!washResult && status !== 'IN_PROGRESS'`일 때만 시작 모달을 띄우고(`ReservationDetailScreen.tsx`) 아니면 세차 화면으로 직행.
- 🔴 **soft delete로는 안 된다 — `checkup.reservation_id`가 UNIQUE(`checkup_reservation_id_key`)다.** 코드는 `checkup.deleted_at`을 찍고 같은 예약으로 `create`를 시도하므로 **soft delete된 checkup이 남아 있으면 재시작이 UNIQUE 위반으로 터진다**(코드 버그. `wash_result.reservation_id`는 일반 KEY라 중복 허용). ⟹ **되돌리기는 실제 `DELETE`.**
  ```sql
  DELETE FROM checkup     WHERE id=?;   -- 자식 checkup_detail 0건 확인 후
  DELETE FROM wash_result WHERE id=?;   -- 자식 wash_result_image/audio/report/wcc 0건 확인 후
  UPDATE reservation SET status='CONFIRMED' WHERE id=? AND status='IN_PROGRESS';
  INSERT INTO reservation_status_log (reservation_id, status) VALUES (?,'CONFIRMED');
  ```
  어드민 `PATCH /v1/admin/users/:userId/reservations/:id`는 status만 바꾸므로 **단독으로는 반쪽 조치**.
- ⚠️ **`reservation_status_log`에 손으로 INSERT하면 tz가 어긋난다.** 이 테이블은 Prisma가 `created_at`/`modified_at`을 둘 다 **UTC로 명시 세팅**하는데, 컬럼 DEFAULT `CURRENT_TIMESTAMP`는 서버 tz(KST)라 raw INSERT는 형제 행보다 **9시간 미래**로 박힌다. INSERT 후 `SET created_at=DATE_SUB(created_at, INTERVAL 9 HOUR), modified_at=created_at`으로 맞출 것(같은 UPDATE 안에서 `modified_at`을 `DATE_SUB(created_at,...)`으로 쓰면 이미 갱신된 created_at을 참조해 **또 −9h** 되므로 두 문장으로 나눠라).
- 진행분 확인 후 실행: `wash_result.status`가 초기값(`CHECKUP/TIRE/DRIVER_FRONT`)이고 `wash_result_image` 0장이면 잃을 데이터 없음. 사진이 있으면 이미 진행된 것이므로 되돌리기 전에 확인.
```sql
SELECT r.status, wr.id wr_id, wr.status wr_status, wr.deleted_yn,
       ch.id ch_id, ch.deleted_at, (SELECT COUNT(*) FROM wash_result_image WHERE wash_result_id=wr.id) imgs
FROM reservation r
LEFT JOIN wash_result wr ON wr.reservation_id=r.id AND wr.deleted_yn=0
LEFT JOIN checkup ch ON ch.reservation_id=r.id AND ch.deleted_at IS NULL
WHERE r.id=?;
```
- 시작 시각 지문 = `wash_result.created_at`(=`checkup.created_at`, 초까지 동일). `reservation_change_log`엔 **IN_PROGRESS 전환이 안 남는다** — 상태 이력은 `reservation_status_log`를 봐야 한다.

---

## 3. 디테일러 쿼리 필수 패턴

### 3a. Active 4조건 + 테스터 제외

**코드 기준 active 4조건**: `booking_yn=1, retired_yn=0, deleted_yn=0, direct_yn=1`

테스터 제외:
- `detailer.name != '이상민'` (테스트 계정)
- `detailer.id != 159` (성지원, supply_sheet 미등록 테스터)

참고: `detailer_supply_sheet.status = '현직'`은 40명, Grafana 기준(위 조건)은 **65명**(2026-08-07 실측, 구 문서값 60명은 stale) — **Grafana 기준 사용할 것**

🔴 **"디테일러 몇 명"은 층이 3개다. 숫자만 쓰면 재현이 안 된다 (2026-08-07 실측).** 같은 날 같은 DB에서:

| 층 | 조건 | 인원 |
|---|---|---|
| 미퇴사 | `deleted_yn=0 AND retired_yn=0` | 129명 |
| **예약 가능 (§3a 4조건)** | + `booking_yn=1 AND direct_yn=1` | **65명** |
| **구역 배정 (§3a ∩ §3b 체인)** | + 현재 유효 `work_schedule` × `rule.zone_id` | **53명** (13개 구역) |

- **외부(IR·팀 공유)에 "직영 디테일러 N명"으로 쓰는 값은 구역 배정 층**이다 — 실제로 고객 차를 받는 사람 수이고, 구역별 명단·사진과 개수가 맞는 유일한 층. IR 덱의 "62명"은 **어느 층으로도 재현되지 않아** 폐기했다(2026-08-07).
- `direct_yn=1`을 빼면 66명이 된다. 차이 1명은 구역 배정이 없어서 **구역 배정 층에는 영향이 없다** — 그래서 direct_yn 누락은 조용히 통과한다. 인원 수를 보고할 땐 4조건을 다 걸고 층을 명시할 것.
- 층별 인원은 계속 바뀐다. **숫자를 인용하지 말고 층 정의를 인용하고 매번 재측정한다.**

`detailer.profile_image` = 프로필 사진 URL(전원 보유 수준). 호스트가 `cdn.thetrive.com`과 `trive-attachment.s3...` 두 갈래이고 **S3 쪽은 경로에 한글이 percent-encoding**되어 있다 — 내려받을 땐 `urllib.parse.quote(url, safe=':/')`로 감싸야 404가 안 난다.

**파견 디테일러**: `supply_sheet.status='파견'` 기준 (현재 7명). 대부분 work_schedule_rule 없음 (15명 중 13명).
- capacity 쿼리, "근무 디테일러수" 메트릭 모두 UNION으로 합산 (= 워크 발생 디테일러 ∪ 현재 파견자)
- `supply_sheet`에 status 변경 이력 없음 — 파견↔현직 전환이 발생하면 12개월 시계열 전체가 retroactive하게 변동됨.

**셀(cell) 소속 — `detailer_supply_sheet.cell_name` (⚠️ zone과 다른 축)**:
- 셀장 판별 = `position='셀장' AND status='현직'`. 셀원 = `cell_name = <셀장 이름>` (같은 status 조건).
- ⚠️ **한 셀이 여러 zone(region)에 걸친다.** cell_name ≠ region/zone. 예: 이승원 셀 = Z1·Z6·Z17 3개 zone에 멤버 분산. 셀장 본인 `region`(Z1)은 셀장이 일하는 zone 하나일 뿐 셀 커버리지가 아님.
- 셀원 명단: `WHERE cell_name='<셀장>' AND status='현직'` — zone/region으로 셀을 재구성하려 하면 누락(타 zone 셀원)+혼입(같은 zone 타 셀원)이 동시에 발생.
- 파견 셀(오토랩·헤이딜러·인천테슬라 등)은 region이 Z코드가 아닌 텍스트.

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

🔴 **존은 하드 파티션이다 — "옆 존 사람이 왜 슬롯에 안 뜨나"의 답 (2026-07-31 코드+DB 확정).** 슬롯 조회 코드(zero-api `query-time-slots.handler.ts`)엔 "존 기반 결과가 0건이면 `zoneId: undefined`로 재조회해 **구(`service_region_group_id`) 단위로 넓히는**" 폴백이 있지만 실제로는 안 돈다:
- ① 판정이 **조회 창 전체** 기준(`primarySlots.length === 0`)이다. 앱은 한 달을 조회하므로 후반에 1개라도 있으면 폴백 미발동 → 근일(D+0~2) 공백이 그대로 노출된다.
- ② **DEFAULT 근무룰은 전부 `zone_id`만 있고 `service_region_group_id`는 NULL**이다(전수 확인). srg만 가진 룰은 구형 디테일러 1명씩(종로1·중구2·용산3·성동4·광진5·동대문6·중랑7·성북8·강동25·인천53~58·구리99·남양주100)뿐이고 **서초22·강남23·마포14 보유자는 0명**, `zone_id`·srg 둘 다 NULL인 전지역 룰도 없다 → 폴백이 돌아도 후보 0명.
- ⟹ 존별 캐파가 남아도 **다른 존 고객은 그 캐파를 쓸 수 없다**. "전사 슬롯은 여유 있는데 특정 지역만 예약 불가"의 구조적 원인. 🔑 룰 필터는 **rule 단위 OR**이고 같은 요일에 복수 룰이 허용되므로, 한 사람을 하루 안에 두 존으로 쪼개 넣는 것(오전 원존/오후 인접존)은 **코드 변경 없이 DB만으로** 된다.

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

### 3c. 재배정 후보 탐색 — "이 존 외 건, 누구로 바꿀 수 있나" (2026-07-26)

§6b의 사전검증은 **이미 고른 대상을 검사**하는 절차다. 후보를 **찾는** 건 별개이고, 순서를 틀리면 "교체 불가"라는 오답이 나온다.

1. **같은 zone 담당자로 1:1 교체는 대개 불가** — 그 zone·그 요일 rule 보유자를 전부 뽑아도 인기 시간대(14시 등)엔 전원 예약이 차 있다. **여기서 멈추지 말 것.**
2. **존을 풀고 "그 시각 공백 × 목표주소 최단거리"로 확장**한다. 1위가 보통 압도적으로 가깝다(실사례 1.4km vs 2위 4.9km).
```sql
WITH sched AS (   -- 그 요일 근무자 (⚠️ rule은 schedule_id로 직접 필터 — §3b)
  SELECT dws.detailer_id FROM detailer_work_schedule dws
  JOIN detailer_work_schedule_rule r ON r.schedule_id = dws.id AND r.deleted_at IS NULL
  WHERE dws.effective_from <= :date AND dws.effective_to > :date AND r.day_of_week = 'MON'
),
res AS (          -- 그날 전체 예약 (KST 하루 = UTC 전날15:00 ~ 당일15:00)
  SELECT r.detailer_id, DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%H:%i') kst,
         r.location, COALESCE(r.longitude,ua.longitude) lng, COALESCE(r.latitude,ua.latitude) lat
  FROM reservation r LEFT JOIN user_address ua ON ua.id = r.address_id
  WHERE r.reservation_datetime >= :utc_from AND r.reservation_datetime < :utc_to
    AND r.status NOT IN ('CANCELED','CREATED')
)
SELECT s.detailer_id, d.name,
       ROUND(MIN(ST_Distance_Sphere(ST_GeomFromText('POINT(:lng :lat)',0),
              ST_GeomFromText(CONCAT('POINT(',x.lng,' ',x.lat,')'),0)))/1000,1) AS min_km
FROM sched s
JOIN detailer d ON d.id = s.detailer_id
  AND d.booking_yn=1 AND d.direct_yn=1 AND d.retired_yn=0 AND d.deleted_yn=0   -- §3a
LEFT JOIN res x ON x.detailer_id = s.detailer_id
WHERE NOT EXISTS (SELECT 1 FROM res y WHERE y.detailer_id=s.detailer_id AND y.kst=:target_hhmm)
  -- ① 종일 휴무만 종일 탈락 (부분 블록을 여기 섞으면 근무 가능자가 통째로 사라진다 — 항목 4)
  AND NOT EXISTS (SELECT 1 FROM detailer_holiday h WHERE h.detailer_id=s.detailer_id
                    AND h.from <> h.to AND TIMESTAMPDIFF(HOUR, h.from, h.to) > 8
                    AND h.from < :kst_day_end_utc AND h.to > :kst_day_start_utc)
  -- ② 부분 시간 블록은 "그 시각만" 탈락
  AND NOT EXISTS (SELECT 1 FROM detailer_holiday h WHERE h.detailer_id=s.detailer_id
                    AND h.from <> h.to AND h.from <= :target_utc AND h.to > :target_utc)
GROUP BY s.detailer_id, d.name ORDER BY min_km;
```
3. **채택 판단은 거리가 아니라 "동선 사이에 끼는가"** — 후보의 직전/직후 예약 시각·좌표를 뽑아 삽입 가능한지 본다(+ 하루 5건 캡). 목표가 기존 동선 한복판에 떨어지는 후보가 정답.
4. ⚠️ `detailer_holiday`는 **UTC 저장**이라 "그날 휴무" 판정 윈도우는 `from < 'X일 14:59:59' AND to > '(X-1)일 15:00:00'`. `from <> to` 필터도 같이(§6b 무력화 row). 그래도 예약이 있는 사람이 휴무로 잡히는 경우가 있으니 **route와 교차확인**.
   - 🔴 **하루 겹침만 보면 "부분 시간 블록"이 종일 탈락으로 번져 후보를 잃는다 (2026-07-26 실사례).** 황석찬(114)에게 memo `셀원 품질 점검`으로 **매일 UTC 05:00~09:00(=KST 14~18시) 4시간 row가 4월~8월 대량 선삽입**돼 있어, 겹침 필터로는 "휴무 있음"이 되지만 오전은 근무 가능이다. **판별 = `TIMESTAMPDIFF(HOUR, from, to) > 8`이면 종일, 이하면 부분 블록**(+`memo` 확인). 위 쿼리처럼 두 NOT EXISTS로 분리할 것.
   - ⚠️ 반대 방향도 틀린다 — 같은 사람에게 **종일 row가 별도로 존재**할 수 있다(황석찬은 `출산 휴가 - 연차` 7/19~7/31 종일 row가 있어 결과적으로 탈락). **부분/종일 둘 다 조회해야 정답.** 한쪽만 보고 "가용/불가"를 확정하지 말 것.
5. 실행 전 §6b "재배정 대상 사전검증"을 반드시 통과시키고, 실행은 재배정 API로(DB 직접 UPDATE 금지). `skipConflictCheckYn=false`로 두면 TMap 실이동시간 기반 충돌체크가 돌아 삽입 타당성을 한 번 더 걸러준다.
6. **교체 전 고객 통지 상태 확인** — D-1 알림톡 본문엔 담당 디테일러 **이름**이 들어간다(§6g). 이미 나갔으면 교체 시 고객이 본 이름이 바뀌므로 재통지 필요.

### 3d. 파견 전환 잔존 예약 — "존 외"의 세 번째 원인 (2026-07-26)

오배정도 슬롯 누수도 아닌 통로. **디테일러를 파견(반얀 등)으로 전환할 때 `detailer_work_schedule`만 갈아끼우고, 그 전에 이미 잡혀 있던 미래 예약은 아무도 되돌아보지 않는다.** 스케줄 변경 → 기존 미래 예약 재검증/재배정 메커니즘이 시스템에 **없다**.

- 실사례: 한수용(191) `BANYAN_TREE_EXTENDED`(7/20~8/31) 스케줄을 **7/18 21:59에 생성** → 그 전 배정된 Z16 권역(강동·송파·하남·성남) 예약이 파견기간에 **45건/18일** 잔존. 하루 것만 처리하면 4~5건 겹치는 날에 계속 재발하므로 **처음부터 파견기간 전체를 뽑을 것.**
- **진단 = 파견 스케줄 `created_at`을 기준선으로 before/after 가르기.** 파견기간 내 비-파견지 예약 중 `r.created_at >= (파견 스케줄 created_at)`인 게 0건이면 **잔존 tail**(과거 배정분), >0이면 **진행형 누수**(신규가 계속 붙는 중). 처방이 다르다 — tail은 일괄 재배정, 누수는 코드/스케줄 수정.
- 🔴 **`reservation_datetime` 상한을 파견 `effective_to`로 반드시 걸어라.** 파견 **종료 후** 날짜는 복귀 DEFAULT 스케줄 구간이라 그 존 예약이 정상이다. 상한 없이 세면 복귀 구간 예약(한수용 9월 8건, 구독 자동예약 `created_at` 03:0x)을 "누수"로 오판한다.
- 구독 자동예약이 몇 주 앞을 미리 깔아두므로(§6b) 파견 결정 시점엔 이미 한 달 반 뒤까지 채워져 있다 = tail은 항상 크다.
- ⚠️ **배정 당시엔 존 외가 아니었을 수 있다** — 판정은 "지금 스케줄"이 아니라 **예약 생성 시점의 effective 스케줄**(`effective_from <= 생성시점 < effective_to`)로. 지금 기준으로 존 외라고 오배정 선언하지 말 것.
- 🔴 **근무창 *안*이어도 이동시간 때문에 불가능해진다 — 휴무·근무창 감사 어느 쪽에도 안 걸리는 세 번째 유형 (2026-08-06 실측).** 한수용(191)이 반얀 **오전조→오후조**(sched 898 `BANYAN_TREE_EXTENDED`, 8/3~8/9 KST 16~21)로 재편성되자 원존(Z16 고덕) **18:00** 예약이 파견 근무창 **안**에 남았다. `detailer_holiday` **0건**이고 근무창 이탈도 아니라 위 두 감사(장소 불일치·교대창 이탈)를 **모두 통과**한다. 실제로는 16:00 반얀 90분 → 17:30 종료 + 장충동→고덕 20km(35~45분) = 18:10 도착으로 불가. ⟹ **파견 감사 조건에 이걸 추가할 것: `파견지 직전 예약 종료시각 + 파견지→목표 이동시간 > 목표 시각`.** 파견 근무창을 **시간대만 옮기는**(오전조↔오후조) 재편성이 이 유형을 만든다 — 날짜·장소·건수가 그대로라 눈에 안 띄고, 디테일러가 전날 전화해서야 드러난다.
  - 🔴 **파견 감사는 반드시 스케줄 토막을 *전수*로 뽑고 시작할 것 — "지금 유효한 한 토막"을 파견 전체로 읽으면 남은 충돌을 통째로 놓친다 (2026-08-06 실수).** 한수용 파견은 **7/20~9/4**인데 `effective_from <= X AND effective_to > X`로 **오늘 것 한 토막(8/3~8/9)만** 뽑고 "파견은 8/9까지"로 단정해, 9/1·9/4 잔존 3건을 "없음"으로 보고했다(사용자가 잡아냄). 실제 편성은 **주 단위 8토막이고 오전조(08~16)/오후조(16~21)가 번갈아** 든다(811·855 오전 → 898 오후 → 899 오전 → 900 오후 → 901 오전 → 902 오후 → 807 복귀). ⟹ 진입 쿼리는 `WHERE detailer_id=? AND type LIKE 'BANYAN_TREE%'` **전체 토막 + 각 토막 rule의 `start_time`/`end_time`**을 먼저 펼쳐 보고, 예약 감사는 예약 1건마다 **그 시점에 유효한 토막**을 조인해서(`dws.effective_from < r.reservation_datetime AND dws.effective_to > r.reservation_datetime`) 근무창을 판정한다. 토막 사이 **공백일**(한수용 7/29)도 이때 드러난다.
- 🔴 **잔존 예약은 "원존 예약"만이 아니다 — 같은 장소 안에서 근무창을 쪼개도 발생한다 (2026-07-27 실측).** 한 장소를 오전/오후 2교대로 분할하면 **분할 전 생성된 그 장소 예약이 교대창 밖으로 떨어진다.** 실사례: 반얀 09·10·11시 예약 4건이 오후조(KST 14~21)인 이형준161·임사명193·박현규207에 잔존 — created 7/13~7/15로 2교대 편성(7/19) 전이고, 당시엔 기본 `BANYAN_TREE` 그리드(09·11시)가 열려 있었다. ⟹ **근무창 감사에 "장소가 맞는 건"도 반드시 포함할 것.** 장소 필터(`location` 불일치)만으로 잔존을 찾으면 이 유형이 통째로 안 보인다.

---

### 3e. 디테일러 생산성 — 작업 소요시간·이동 간격 (2026-08-06 실측)

"1인당 하루 몇 대까지 가능한가"를 따질 때 쓰는 3종. 세 군데 다 함정이 있다.

🔴 **실제 작업 소요시간의 정본은 `wash_result.created_at` → `wash_result.finished_at`이다. `reservation.estimated_time`을 쓰지 마라** — 그건 차량 티어·서비스에서 나온 **산식(계획값)**이지 측정값이 아니다. 부하 랭킹(§6b)엔 계획값이 맞지만 "실제로 몇 분 걸리나"엔 틀린다.

⚠️ **`wash_result.status`는 BEFORE/AFTER가 아니다** — 리포트 작성 **워크플로 단계**이고 `'DONE'`이 완료다(2026-05~07 10,788 / 10,804 = 99.9%. 나머지는 `CHECKUP/TIRE/...`·`SUBMIT/NOTE` 등 중간에 멈춘 행). BEFORE/AFTER는 `wash_result_image.status`다(§6d). **예약당 1행**이라 소요시간 집계에 중복이 안 생기고, `finished_at IS NOT NULL`만 걸면 미완료 행은 자동으로 빠진다.

🔴 **디테일러 귀속·`GROUP BY`는 `reservation.detailer_id`(FK)로. `technician`으로 묶지 마라** — `technician`은 디테일러 **이름 문자열**(비정규화)이고 99.9% 채워져 있어 그럴듯해 보이지만, 2026-05~07 구간에서 `COUNT(DISTINCT technician)` 74 vs `COUNT(DISTINCT detailer_id)` 75로 **동명이인이 한 명 합쳐진다.**

🔴 **이동시간을 `LEAD` 간격으로 재지 마라 — 그건 이동이 아니라 "이동 + 유휴"다 (2026-08-06 실측, 내가 틀렸던 것).**
연속 작업의 `LEAD` 차이는 4시간 트림 후 평균 **59.7분**(n=7,333)이라 "이동이 오래 걸린다"로 읽힌다. 그런데 실제 이동거리는 **홉당 3~5km · 하루 총 7~14km**(서울 시내 15~45분)다. **간격의 대부분은 예약 슬롯 사이 빈 시간**이지 이동이 아니다. 이걸 이동으로 읽으면 "생산성 제약 = 동선"이라는 **정반대 진단**이 나온다.

**정본 = `cbr_detailer_daily_productivity_snapshot`** (디테일러·일 단위 사전집계. 이동·시간을 다 갖고 있다)

| 컬럼 | 뜻 |
|---|---|
| `daily_total_km` / `daily_avg_km` / `daily_max_gap_km` | 하루 총 이동 / **홉당** 평균 / 최대 홉 |
| `daily_work_minutes` | 근무 분 |
| `daily_total_wash_minutes` / `daily_avg_wash_minutes` | 세차 총 분 / 건당 분 |
| `washes_total`, `is_workday`, `detailer_segment`, `region` | 건수·근무일 플래그·세그먼트 |

- `is_workday = 1` 필터 필수. 주간 집계는 **중앙값**(주별 편차가 크다 — 2026-07 주간 세차수 2.18~4.22대).
- 🔑 **가동 판정식 = `daily_work_minutes − daily_total_wash_minutes` (여유분).** 2026-07-26주 실측: 근무 467분 · 세차 274분 · **여유 192분** · 세차시간 비중 58.8%. 여유의 대부분이 유휴라 **제약은 동선이 아니라 배정량(수요 밀도)**이다.
- `LEAD` 간격은 여전히 쓸모가 있다 — 단 이름을 **"작업 간 간격"**으로 부르고 이동시간이라 부르지 말 것. 음수(기록 겹침, 20건)는 `>= 0`으로 제외.

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

## 4b. 월별 실적·코호트 쿼리 함정 (2026-07-28 실측)

월 단위 실적·리텐션·매출을 뽑을 때 **조용히 틀리는** 지점들. 전부 prod 실측으로 확인됐고, 합계 검증만으로는 안 잡히는 것들이 섞여 있다.

### 4b-1. 코호트·세그먼트: 유저 이력 CTE에 날짜 하한을 걸지 마라

신규/온보딩/충성/복귀 같은 세그먼트를 뽑을 때, **유저 이력을 만드는 CTE**(`all_washed`/`washed`)에 하한을 걸면 `MIN(세차일)`이 "진짜 첫 세차일"이 아니라 **"창 안에서의 첫 세차일"**이 된다. 그러면 오래 쉬다 돌아온 유저의 first_d가 복귀월로 잡혀 `first_d < 전월시작` 조건에 못 걸리고 **어느 세그먼트에도 안 들어간다.**

```sql
-- ❌ 틀림: 이력 CTE에 하한
washed AS (SELECT ... FROM reservation WHERE ... AND 세차일 >= '2025-08-01')
-- ✅ 맞음: 이력은 무제한, 출력 월 범위만 제한
washed AS (SELECT ... FROM reservation WHERE status IN ('WASHED','REPORT_SENT') AND deleted_yn=0)
```

실측 누락: 복귀(resurrected) 2026-04 −36명 / 05 −11 / 06 −21. 누락 수가 오차와 정확히 일치.
⚠️ **"세그먼트 합 = active" 검증으로는 이 버그가 안 잡힌다** — 누락분이 다른 버킷으로 밀려 총합이 보존된다. **월별 값을 확정 실적과 개별 대조**할 것(허용 ±5).
빠른 진단: SQL 안의 날짜 리터럴 개수를 세라. 이력 하한이 있으면 정상 메트릭보다 하나 많다.

### 4b-2. 상태 스냅샷: 미래 데이터를 참조하면 과거가 소급 변한다 (look-ahead 편향)

"그 달에 휴면이었나" 같은 **시점 상태**를 구할 때 `MAX(전체 기간 세차일)`을 쓰면 **미래의 세차가 과거 달의 판정을 지운다.**

```sql
-- ❌ 틀림: 전체 기간 MAX → 2026-06에 복귀하면 2026-05 휴면 판정이 사라짐
user_last AS (SELECT user_id, MAX(k) last_d FROM all_washed GROUP BY user_id)
... WHERE last_d < 월시작
-- ✅ 맞음: 해당 월 시작 이전만 참조
ever_before  = 첫세차 < 월시작인 유저
returning_in = 그 중 해당 월에 세차한 유저
pool         = ever_before − returning_in
```

실측: 휴면풀이 2026-04 −938 / 05 −781 / 06 −295 과소. **오차가 최근일수록 작아지는 것이 이 버그의 지문**(과거 달일수록 지울 미래 데이터가 많다). 고치면 별도 산출 기준과 0.1% 안에서 일치.

### 4b-3. 확정 월별 실적의 기준일은 `reservation_datetime`이다

세차 건수·활성 유저수·세그먼트·세차 매출 **전부** `reservation_datetime` 기준이다. `washed_at`을 쓰면 어긋난다.

실측(2026-06 카라멜 세차): `washed_at` 3,922 / **`reservation_datetime` 3,971 = 확정값**.
⚠️ `washed_at`을 쓰면 **예약일이 250일 전인데 완료가 이번 달인 건**(2026-07에 216건 관측) 같은 케이스가 엉뚱한 달로 귀속돼 "세차당 매출"이 특정 월에서 과소·다른 월에서 과대로 왜곡된다.
⚠️ 완료 세차 중 `washed_at IS NULL`이 소수 존재(2025-08~2026-06 0.05~0.88%, 진행 중인 달은 최대 3.7%) → `washed_at` 기준은 그만큼 언더카운트한다.

### 4b-4. 세차 매출 SQL은 월 단위로만 정확하다

`scripts/tmp_mar_revenue.sql`은 **기간 창을 여러 달로 넓히면 값이 샌다.** 결제 1건이 여러 달에 걸쳐 소진되는 구조(구독·다회권) 때문에 payment 단위 집계가 월 경계를 넘는다.

실측(2026-06): 단일월 실행 **216,111,879원**(확정값 일치) vs 12개월 한 번에 실행 217,412,416원(+130만원).
→ **CTE를 다월용으로 재작성하지 말고 월 창을 갈아끼워 N번 실행하라.** 부분 수정(내부 GROUP BY에 month 추가)으로는 안 막힌다. 그리고 이 SQL이 월마감이 쓰는 정의이므로 재작성하면 마감과 다른 숫자가 나온다.

### 4b-5. 부분취소(PARTIAL_CANCELED) 취소액을 차감하라

매출 SQL이 `status IN ('PAID','PARTIAL_CANCELED')`로 부분취소 결제를 **포함시키면서 `cancel_amount`를 빼지 않으면** 그만큼 과대계상된다.
→ 포인트와 **동일하게 비례배분** 차감: `cancel_alloc = ROUND(cancel_amount × 항목_정가 / 정가합)`.
실측 과대분: 2026-03 ~194만 / 04 ~91만 / 05 ~143만 / 06 ~314만원. **12개월 누적 약 1,090만원.**

### 4b-6. 합산 CPA는 채널 믹스가 바뀌면 해석이 없다

광고비는 3채널 합산이 맞지만(§6 참조), **믹스가 급변한 구간에서 합산 CPA를 효율 지표로 읽으면 오독한다.**

| 월 | Meta | Naver | Google | 합계 | 신규 첫구매 | 합산 CPA |
|---|---:|---:|---:|---:|---:|---:|
| 2026-03 | 1,264 | 59 | – | 1,323 | 853 | 1.55 |
| 04 | 1,494 | 209 | 10 | 1,713 | 816 | 2.00 |
| 05 | 1,371 | 158 | 590 | 2,119 | 565 | 3.75 |
| 06 | 911 | 245 | 1,044 | 2,200 | 670 | 3.28 |

(단위 만원) Meta를 끄고 Google로 갈아탄 결과이지 한 채널이 나빠진 게 아니다. **예산을 +66% 올린 구간에서 신규는 853→670으로 줄었다** — "예산↑ ⇒ 신규↑ 비례" 가정은 실측과 부호가 반대다.
→ CPA 변화를 논할 때 **채널별 집행액을 같이 뽑아 믹스 변화를 먼저 배제**하라. ⚠️ 다만 **채널별 신규(분모)는 현재 못 만든다** — `user_attribution` 귀속률이 2026-06~07도 unknown 55%다(그 이전은 98~99%).

### 4b-7. 외부공급(헤이딜러) 세차 = `manual_wash_adjustment` 전체 합산

memo 화이트리스트로 좁히지 마라. `memo IN ('헤이딜러','조준호')`로 거르면 표기 변형(`'인천 테슬라 (조준호)'` 등)을 놓친다.
memo 실측(2026-01~07, 247행): 헤이딜러 4,559 / 조준호 527 / 인천 테슬라 (조준호) 30 / 현장 긴급 세차 36 / 마이바흐 추가세차분 반영 11 → **전부 외부공급**.
⚠️ `wash_date`는 **DATE 타입**이라 KST 변환 불필요. ⚠️ 테이블이 **2026-01-02부터** 시작하므로 2025년은 0행이 정상.
⚠️ **파견 디테일러(`detailer_supply_sheet.status='파견'`)의 앱 예약은 외부공급이 아니다** — 카라멜 자산으로 센다. 2025-08~2026-02에 669건 있고 고객이 개인 585명(평균 1.14건)인 일반 소매 예약이다. `manual_wash_adjustment`는 앱에 안 잡히는 현장 물량을 따로 더하는 장치라 두 소스는 겹치지 않는다.

### 4b-8. live_user 블랙리스트에 `OR phone IS NULL`을 빼먹지 마라

`phone NOT IN (...)`만 쓰면 SQL의 `NULL NOT IN (...)` 규칙 때문에 결과가 NULL(falsy)이 되어 **phone이 NULL인 유저가 조용히 제외된다.**

```sql
AND (u.phone NOT IN ('01020866510', ...) OR u.phone IS NULL)
```

같은 분석 안에서 어떤 지표는 블랙리스트를 쓰고 어떤 지표는 안 쓰면 **분자와 분모가 다른 모집단**이 된다(실측: 세차 건수 12개월 합 ~100건 오염).

### 4b-9. `payment_medium`은 2025-10부터 존재한다

기존 문서 일부에 "2025-09부터"로 적혀 있으나 실측은 **2025-09까지 0건, 2025-10부터 전환 시작**(2025-10 혼재, 2025-11 이후 거의 전부).
→ 그 이전 기간의 포인트는 `metadata.$.point` 폴백 필수: `COALESCE((payment_medium POINT SUM), metadata.$.point, 0)`. 안 하면 과거 포인트 차감이 0이 되어 매출이 과대된다.

### 4b-12. 연도별과 누적을 한 화면에 쓸 때는 필터를 통일하라 (2026-08-04 실측)

같은 "세차 완료 건수"인데 **연도별은 raw(사용자 필터 없음), 누적은 live_users 필터**로 뽑아 한 장표에 나란히 두면 합계가 안 맞는다. 실측 갭 **437건(1.04%)** — 손으로 더하는 자리에서 바로 들킨다.

| 기준 | 2024 | 2025 | 2026 1~7월 | 합계 |
|---|---:|---:|---:|---:|
| raw (필터 없음) | 2,118 | 16,474 | 24,258 | 42,850 |
| **live_users (정본)** | **2,076** | **16,298** | **24,078** | **42,452** |

- 원인 2가지: (1) `live_users`(deleted/test/temp + 블랙리스트 전화번호 + `OR phone IS NULL`) 적용 여부 (2) **측정 시점** — 같은 정의라도 7/29 스냅샷과 7/31 마감이 400건 이상 벌어진다.
- ⟹ **한 장표·한 문단에 들어가는 수치는 같은 쿼리에서 한 번에 뽑는다.** 연도별을 A에서, 누적을 B에서 가져오지 말 것. 인용할 땐 "테스터 제외 실고객 기준 · YYYY-MM-DD까지"를 같이 적는다.
- ⚠️ 모델·재무 시트의 2025 세차 완료수(16,301)는 또 다른 스냅샷이다. DB 값(16,298)과 3건 차이라 실무상 무해하지만, **DB 수치와 모델 수치를 같은 표에 섞지 말 것.**

### 4b-13. 🔴 과거 월의 세차 완료수는 계속 바뀐다 — 원인 3가지 (2026-08-06 실측)

"이미 지난 달인데 왜 숫자가 달라지냐"의 답. **세차가 늦게 완료돼서가 아니다** (2026-04 완료 4,037건 중 4,034건이 세차 당일 `wash_result` 입력, 나머지 3건은 소급 생성 예약).

| 원인 | 방향 | 메커니즘 | 2026-04 실측 |
|---|---|---|---:|
| 고객 탈퇴 | 감소 ↓ | `live_users`의 `deleted_yn=0` → 탈퇴하면 **그 사람의 과거 세차가 전 기간에서 사라진다** | 21건 (탈퇴 시점 4월 6·5월 11·6월 1·7월 2·8월 1) |
| 수기 외부공급 입력 지연 | 증가 ↑ | `manual_wash_adjustment`는 사람이 매일 입력 → 월말 며칠분이 익월 초에 들어옴 | 78건(4/29·4/30분이 5/1~5/2 입력). 07월은 151건이 8월 입력 |
| 소급 예약 생성 | 증가 ↑ | 어드민이 나중에 과거 `reservation_datetime`으로 예약 생성 | 4건 |

- ⟹ **마감 확정값(`Caramel_monthly(A)`)이 정본이고 Grafana는 모니터링용.** 두 숫자가 다르면 버그가 아니라 조회 시점 차이일 수 있다. 인용 시 `YYYY-MM-DD 조회` 병기(§4b-12).
- ⚠️ 정의 변경도 과거를 소급으로 바꾼다 — 2026-07-28 외부공급 memo 화이트리스트 → 전체 합산(§4b-7) 전환으로 2026-02가 +30건 됐다.

### 4b-14. 🔴 "언제 완료됐나"를 `reservation.modified_at`으로 판정하지 마라 (2026-08-06 실측)

`modified_at`은 무관한 배치·셔플·백필에도 갱신된다. 2026-04 완료 예약 36건이 `modified_at` 2026-07~08이라 "3개월 늦게 완료된 건"으로 보였지만, **전부 `wash_result.created_at`이 세차 당일**이었다(7/19~21에 뭔가가 훑고 지나간 흔적일 뿐).

- **완료 시점 정본 = `wash_result.created_at`(≈`checkup.created_at`, 같은 값).** 지연 판정은 `DATEDIFF(wr.created_at, KST(r.reservation_datetime))`.
- 🔴 **`reservation_change_log`는 2026-05-22부터만 존재한다** (전체 18,824행, 그 이전 0행). 2026-04 이전 기간의 상태 전이·재배정 이력은 **이 테이블로 추적 불가** — 없다고 "변경이 없었다"로 읽지 말 것.
- 소급 생성 예약 판별: `DATE_FORMAT(KST(r.created_at),'%Y-%m') > DATE_FORMAT(KST(r.reservation_datetime),'%Y-%m')`.

### 4b-10. 경과일 버킷의 누적 평균은 시계열로 비교할 수 없다 (2026-08-04 실측)

구독 코호트의 "경과일 버킷별 누적 세차 횟수"를 뽑으면 버킷마다 **모집단이 다르다.** 실측:

| 버킷 | 관찰 n | 누적 평균 세차 |
|---|---:|---:|
| D1-90 | 6,282 | 2.09회 |
| D91-180 | 3,112 | 4.11회 |
| D181-270 | 1,675 | **4.97회** |
| D271-365 | 814 | **4.09회** |

D181-270이 D271-365보다 높은 건 개선이 아니라, D181 버킷에 **D271 도달 전 해지한 유저가 섞여** 있어서다. 같은 유저를 따라간 값이 아니므로 "6개월차에 4.97 → 1년차에 4.09로 줄었다"는 해석은 틀린다.
- **연간 횟수를 말할 땐 12개월 완주 코호트만 쓰고 `n`을 병기한다** — 실측 = 완주 814명 · 평균 4.1회 · **중앙값 2회**(평균만 쓰면 과대). 상품별로 크게 갈린다(월2회 8.0 / 월1회 4.8 / 월1회 외부+내부 5.6 / 두달1회 2.5 / 상품 미지정 1.2 / 1개월 무료 0.6).
- 비교군은 비구독(1회권) 1.6회 → 구독/비구독 = **2.6배**.
- 절대 하지 말 것: 짧은 버킷 평균에 연환산 계수를 곱하기. §4b-1(이력 CTE 하한)과 같은 계열의 오류다.

### 4b-11. 🔴 '월 2회(외부만)' 구독 리텐션은 기존 기록값이 재현되지 않는다 (미해결)

아래 정의로 짜면 기존 기록과 **8.5%p까지 벌어진다.** 어느 쪽이 맞는지 미확정이므로 **인용 시 반드시 쿼리 정의와 n을 같이 쓴다.**

```sql
-- 재현 시도한 정의 (2026-08-04)
payment.name LIKE '월 2회(외부만)%' AND payment.type='SUBSCRIPTION' AND payment.amount > 0
  + car_model_target.is_target = 1        -- 타겟 차량 보유
  + first_paid_kst 기준 cohort_date, D1~365 경과일 버킷 MAX 활성 여부
```

| 버킷 | 위 정의 (n=490) | 기존 기록 (n=368) |
|---|---:|---:|
| D1-30 | 89.0% | 96.5% |
| D151-180 | **57.8%** | **66.3%** |
| D181-210 | 54.1% (분모 292) | — |
| D211-240 | 47.5% (분모 80) | — |

- 원본이 **세차 활동 기준 추가 필터**를 걸었을 가능성이 크다(결제 존재 ≠ 실사용). 확인되면 이 절을 갱신할 것.
- **분모를 반드시 라벨링한다** — 코호트 리텐션(분모=코호트 전체)과 조건부 생존율(분모=직전 버킷 생존자)은 전혀 다른 값이다. 위 표는 코호트 리텐션이고, 조건부 생존율은 버킷마다 83~88%로 훨씬 높게 보인다. 섞으면 큰 오차.
- **상품 출시가 2025-10이라 D271 이상 도달자가 0명이다** — "1년 리텐션"은 아직 데이터가 없다. 만들어 쓰지 말 것.

### 4b-13. 전화번호 리스트를 DB에 대조할 땐 `GROUP BY 전화번호` — `app_user.id`로 묶으면 한 사람이 쪼개진다 (2026-08-04 실측)

**한 전화번호에 `app_user` row가 여러 개 존재한다.** 영업·CS 리스트(시트)를 번호로 조회할 때 `JOIN app_user` 후 `GROUP BY u.id`로 집계하면 **같은 사람이 계정 수만큼 여러 행으로 갈라지고, 예약이 한쪽 계정에만 있으면 다른 행은 "활동 0"으로 나온다.** 대상자 명단을 뽑는 쿼리에서 이건 오탐이다.

```sql
-- 정본: 번호로 묶고, 계정 수도 같이 확인
SELECT REPLACE(u.phone,'-','') AS ph, COUNT(DISTINCT u.id) AS accounts, SUM(...) 
FROM app_user u
LEFT JOIN reservation r ON r.user_id=u.id AND r.status NOT IN ('CANCELED','CREATED')
WHERE REPLACE(u.phone,'-','') IN (:phones)
GROUP BY ph          -- ⚠️ GROUP BY u.id 아님
```

- 실측(반얀 고객 552개 번호 대조): **33/552 = 6.0%가 계정 2~3개**, 그중 **11개 번호는 조회 기간 예약이 한쪽 계정에만 몰려 있었다** → `u.id` 기준으로 짰으면 11명(2.0%)이 "미접촉"으로 잘못 분류된다. 차량·주소로 유저를 좁혀 들어가는 경로(`car.user_id` 등)도 같은 함정.
- 시트 번호는 `010-1234-5678` 하이픈 포함이 흔하므로 **양쪽 다 `REPLACE(phone,'-','')`** 로 정규화. `app_user.phone`은 하이픈 없는 게 원칙이지만 신뢰하지 말 것.
- ⚠️ **번호 자체가 깨진 계정이 있다** — 실측으로 `app_user.phone='0079'`(4자리)가 존재. `LENGTH(REPLACE(phone,'-',''))<>11`을 먼저 세서 "매칭 실패"와 "번호 불량"을 구분할 것. 관련: 050 vno는 phone이 아니라 user_id 단위 키잉(§ `customer_vno`).

---

### 4b-14. 시점 기준 미사용 세차권(선수금) 잔액 — `used_yn`은 **현재** 상태다 (2026-08-05 실측)

"월말 기준 미이행 세차권이 얼마였나"(선수금·이연매출 추이)를 구할 때 `used_yn=0`을 쓰면 **과거 시점이 통째로 과소집계된다.** `used_yn`은 오늘 상태이므로, 과거에 미사용이었지만 그 후 소진된 세차권이 전부 빠진다. 최근 달일수록 오차가 작아지는 것이 이 버그의 지문이다(§4b-2와 같은 계열).

- **`user_service`에 `used_at` 컬럼이 없다.** 소진 시점의 정본 = **연결된 `reservation`의 세차일**.
- 시점 D의 미사용 판정 4조건: ①`created_at ≤ D` ②`deleted_yn=0 OR deleted_at > D` ③`ended_at IS NULL OR ended_at > D`(만료분은 부채 아님) ④`reservation_id IS NULL` **또는** 연결 예약의 세차일 `> D` **또는** 그 예약이 `WASHED/REPORT_SENT`가 아님.

```sql
LEFT JOIN (SELECT id, DATE_ADD(reservation_datetime, INTERVAL 9 HOUR) AS wash_kst, status
           FROM reservation WHERE deleted_yn=0) r ON r.id = us.reservation_id
WHERE us.reservation_id IS NULL OR r.id IS NULL
   OR r.wash_kst > :asof OR r.status NOT IN ('WASHED','REPORT_SENT')
```

- 실측 격차: 2026-03-31 잔액이 `used_yn=0`으로는 6,660장, 시점 판정으로는 **10,652장 — 37% 과소**.
- **금액은 `service.price`(정가)로 환산할 것.** `user_service.paid_amount`는 2026-05분부터만 채워져 추이를 못 만든다(위 `user_service` 치트시트). 정가 기준이라 실수령액보다 크다는 단서를 반드시 병기.
- **발급 경로를 갈라야 해석이 된다** — `promotion_application_id`/`coupon_code_reward_id`/`coupon_campaign_reward_id` 중 하나라도 있으면 무상권, 아니면 `payment_id` 유무로 '결제로 발급' vs '어드민 지급'. 실측(2026-06-30): 결제 발급 4.90억 / 어드민 지급 1.33억 / 무상 0.15억 — 무상권을 섞으면 "선수금 증가"가 부풀려진다.

### 4b-15. 세차 객단가 = 정의부터 맞춰라. 그리고 상승 원인은 **정가 vs 실현율**로 갈라야 한다 (2026-08-05 실측)

- **카라멜 세차 객단가 정본 = (전체 세차매출 − 헤이딜러 건수×8.80만) ÷ 카라멜 세차 횟수.** `Caramel_monthly(A)` 시트 22행('세차 객단가 > 카라멜')이고, `tmp_mar_revenue.sql`의 `avg_revenue_per_wash`와 같은 값이 나온다(실측 2026-04 50,020원 / 05 51,657 / 06 54,423 = 시트 5.01·5.17·5.44와 일치).
- ⚠️ **`세차 매출 ÷ 합계 세차 횟수`로 계산하면 틀린다** — 헤이딜러(외부공급) 건수가 분모에 섞여 값이 눌린다(2026-04 기준 4.88만 vs 정본 5.00만).
- 🔴 **객단가 상승을 "옵션이 팔렸다"로 먼저 결론내지 말 것.** 분해 순서는 ①`item_kind`별(세차권/옵션/서비스변경) 기여 ②세차권 안에서 **정가 불변인지** 확인. 실측 2026-04→06 +8.8% 중 세차권 73% · 옵션 23%였고, **정가 인상은 0원이었다** — 같은 티어·같은 서비스의 `originalPrice`가 그대로였고(1회권 외부+내부 T3 59,536→60,000) 바뀐 건 **정가 실현율**이다(외부만 T4 67%→97%, 외부만 T5 48%→98%). 즉 원인은 가격 인상이 아니라 **프로모션·쿠폰 할인 축소 + 무상(0원) 세차 비중 감소**다.
- **실현율 뽑는 법**: `tmp_mar_revenue.sql`의 `items_with_point`에 이미 `original_price`(=`metadata.prices[].originalPrice`)가 있다. `SUM(net_amount)/SUM(list_amount)`를 **동일 `service_id`(티어×세차범위) 단위로** 볼 것 — 티어 믹스가 섞이면 가격 변화와 구분이 안 된다.

---

## 5. 공통 패턴

### 5a. KST 변환

DB는 UTC 저장 → `CONVERT_TZ(col, '+00:00', '+09:00')` 또는 `+ INTERVAL 9 HOUR`

GROUP BY에 날짜 쓸 때 반드시 KST 변환 후 사용.

예외: `paused_at`, `ended_at`은 코드에서 KST(`Asia/Seoul`)로 할당 → UTC +9H 변환 불필요.

**🔴 정정: `reservation.created_at`은 UTC다 (2026-08-06 재실측). 아래 "KST 벽시계" 서술은 틀렸다.**
- **재실측 근거 2개.** ①`NOW()`=17:02 KST(session tz `Asia/Seoul`)일 때 `MAX(created_at)`가 `reservation`·`message`·`payment`·`user_service` **4개 테이블 전부 08:0x** = 정확히 −9h. ②`created_at` 시각 분포에서 **0–5시가 4,150/6,577 = 63.1%**(2026-05, 06·07·08월도 63~68%로 동일). 사람이 새벽에 예약을 63% 만들 리 없고, 0–5시 UTC = 09–14시 KST 업무시간이다.
- 즉 **`+ INTERVAL 9 HOUR` 변환이 필요하다.** `DATE_FORMAT`으로 뽑은 문자열을 KST로 읽으면 9시간 어긋난다.
- ⚠️ **이 오기가 실제로 사고를 냈다 (2026-08-06):** 티켓 러너 세션이 이 문장을 믿고 정상적인 티켓 본문(`10:38 KST`)을 `01:38 KST`로 "정정"했다. 같은 날 다른 세션은 SENS 응답의 KST `requestTime`과 19,606행 대조로 UTC임을 독립 확인했다.
- (구 서술: "MySQL `DEFAULT CURRENT_TIMESTAMP`=서버 KST라 `created_at`/`modified_at`은 KST 벽시계, 2026-07-12 실측" — 최소 2026-05 이후 데이터에선 성립하지 않는다. `modified_at`은 이번에 따로 재측정하지 않았으므로 아래 §7 "`modified_at` tz 지문" 항목은 쓰기 전에 재검증할 것.)
- **디테일러 재배정 역추적 시그니처**: 재배정 전용 이력 테이블/로그 type은 없다. `modified_at`이 **17:00분대 = 셔플 크론(매일 17시 KST)이 detailer_id 변경**한 것, 17시대 후반(예 17:51) = 사람이 어드민에서 재배정했을 개연성 (2026-07-13 임세혁 셔플 진단 실사례).
  - 🔴 **단 "change_log엔 아예 안 남는다"는 반쪽 진술이다 — 두 경로를 함께 봐야 한다 (2026-07-27 예약 #79702 실측 교정).**
    - **고객이 날짜를 바꾸면서 디테일러도 바뀐 경우는 남는다**: `RESERVATION_DATETIME_CHANGED` row의 `data` JSON에 `fromDetailerId`/`toDetailerId`가 같이 실린다(#79702: 고객이 7/27→7/28 변경하며 78 이승제→88 강지성). **재배정 전용 `data.type`이 없어서 datetime 로그 안에 숨어 있다** — `data.type`으로 재배정을 찾으면 못 찾는다. `WHERE JSON_EXTRACT(data,'$.toDetailerId') IS NOT NULL`로 잡을 것.
    - **셔플 크론·어드민 단독 재배정은 안 남는다**: 같은 #79702가 다음날 17:00 셔플로 88→78 되돌아왔는데 change_log엔 row 0건. 이건 `modified_at`으로만 추적된다.
    - ⟹ change_log만 보면 셔플 이동을 놓치고, `modified_at`만 보면 고객 변경분의 before/after 디테일러를 잃는다. **"재배정 이력" 질문엔 항상 두 쿼리를 돌릴 것.**
  - 🔴 **초는 `00`이 아니다 — `TIME(modified_at)='17:00:00'` 등호 필터는 0건이 나온다 (2026-07-26 실측).** 배치가 17:00:00에 시작해 수 초간 쓰므로 실제 저장값은 `17:00:14` 같은 형태다. **판별은 `HOUR(modified_at)=17 AND MINUTE(modified_at)=0`.** "정각"이라는 표현에 낚여 초까지 등호 비교하면 "셔플이 안 돌고 있다"고 오판한다 — 실제로는 매일 돌고 있다(7/23~26 각 12·27·50·93건 변경).

**⚠️ mysql-query.sh DATETIME 렌더링 함정 (쓰기 작업 시 치명적)**
- DATETIME 컬럼을 그냥 SELECT하면 `...Z` ISO로 보이지만 **실제 저장값이 아니라 저장값−9h** (드라이버가 naive 값을 KST 로컬로 해석해 UTC ISO로 직렬화).
- 저장 원문이 필요하면 `DATE_FORMAT(col,'%Y-%m-%d %H:%i:%s')`로 문자열화해서 읽을 것.
- INSERT/UPDATE의 인라인 리터럴은 **verbatim 저장**됨 → SELECT에서 본 `Z` ISO 값을 그대로 복붙해 넣으면 9시간 어긋난다. 반드시 DATE_FORMAT으로 읽은 원문 기준으로 쓸 것.

**⚠️ DATE 컬럼(시각 없음)도 렌더링 함정 — 하루 밀림**
- DATE 컬럼도 `...T15:00:00.000Z` ISO로 렌더됨: **렌더 X일T15:00Z = 저장 X+1일** (naive date를 KST 자정으로 해석해 UTC 직렬화).
- 날짜별 결과를 눈으로 해석할 때 하루 밀려 읽기 쉬움 → `DATE_FORMAT(col,'%Y-%m-%d')`로 뽑을 것. (실사례: `forecast_log.forecast_date`)

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

**취소 시 세차권 "반환" = 새 row 재발급 (2026-07-19 실측)**: 예약 취소(어드민 bulk-cancel `ticketAction=GIVE_BACK` 등)로 세차권이 반환되면 기존 `user_service` row의 `used_yn`을 0으로 되돌리는 게 아니라 ① 기존 row는 `used_yn=1`·`deleted_yn=1`로 soft-delete되고 `reservation_id` 연결이 그대로 남으며 ② 동일 `service_id`의 새 미사용 row(`used_yn=0`, `reservation_id=NULL`)가 새로 생성됨. ⟹ row 수를 발급 수로 세면 이중계산, `deleted_yn=1`을 "소실"로 세면 오판(반환분은 새 row로 살아 있음).

**🔴 "고객이 가진 세차권 N장" = 미사용 + 미래예약에 물린 것 (2026-07-31 실측)**: CS 문의("몇 장 남았냐", "유효기간 연장해달라")에 `used_yn=0`만 세면 **틀린다.** 구독 고객은 자동예약 배치가 미래 예약을 미리 잡으면서 세차권을 `used_yn=1`로 선점해두기 때문에, 미사용 row가 0장인데 고객은 "7장 남았다"고 말하는 상황이 정상적으로 발생한다. 그 예약을 취소하면 위 GIVE_BACK 경로로 새 미사용 row가 나오므로 고객 인식이 맞다.
```sql
-- 고객 보유 세차권 (실질)
SELECT us.id, s.name, r.status,
       CASE WHEN us.used_yn = 0 THEN '미사용' ELSE '예약선점' END AS state
FROM user_service us
JOIN service s ON s.id = us.service_id
LEFT JOIN reservation r ON r.id = us.reservation_id
WHERE us.user_id = ? AND us.deleted_yn = 0
  AND (us.ended_at IS NULL OR us.ended_at > NOW())
  AND (us.used_yn = 0 OR r.status = 'CONFIRMED')   -- WASHED = 실소진이라 제외
```
전체 규모(2026-07-31, 살아있고 미만료인 `user_service` 기준): 미사용 18,860 / 미래 CONFIRMED 선점 4,816 / 소진(WASHED) 35,248. **선점분이 실질 보유의 4,816÷23,676 = 20.3%** — 무시하면 CS 답변이 대량으로 틀린다.

### 5d. 구독 status=ACTIVE 필터

- `status='ACTIVE'` 단독 조건은 일시정지 포함 → "현재 세차 가능한 활성 구독자" 집계 시 왜곡
- **실사용 구독자(일시정지 제외)**: `status='ACTIVE' AND paused_at IS NULL`
- `status='ACTIVE' AND paused_at IS NOT NULL` = 일시정지 상태 (세차 불가, 구독료 정지)

**⚠️ stopped_at·churn 판정 함정**
- `stopped_at` = 해지 시점 (churn 판정 컬럼). **STOPPED 4,500건+도 `deleted_yn=0`** → deleted_yn만으로 활성 판단하면 해지 구독이 오염된다. 활성 = `status='ACTIVE' AND deleted_yn=0`.
- status 실값: `STOPPED`/`ACTIVE`/`CREATED`/`ENDED`/NULL(+오타 `STOPPPED` 소량). **`PAUSED` status는 없다** — 일시정지는 `paused_at`으로만 판별.
- **churn 계산**: 분모 = 월초 ACTIVE (`started_at < 월초 AND (stopped_at IS NULL OR stopped_at >= 월초)`), 분자 = 월내 `stopped_at` 전이, user DISTINCT, paused 제외. ⚠️ **분자에도 `started_at < 월초` 코호트 조건을 걸 것** — 안 걸면 월중 가입→같은 달 해지 유저가 분모 없이 분자에만 새서 churn이 과대된다 (실측: 주간 기준 10~12% 상대 과대).
- ⚠️ 과거 시점 활성 구독 수 스냅샷에 `status='ACTIVE'`(현재 상태) 필터를 쓰면 이후 해지된 구독이 과거에서도 빠져 역사 시계열이 통째로 과소된다 — 과거 스냅샷은 `started_at`/`stopped_at` 경계로만 판정.
- 데이터 품질: STOPPED인데 stopped_at NULL ~90건, ENDED는 stopped_at 전부 NULL → 경계식 분모에 영구 잔류. 해결 = 종료시점에 `ended_at` fallback(아래).
- ⚠️⚠️ **`ended_at`은 "종료시점"이 아니다 — churn/활성 판정에 `COALESCE(stopped_at, ended_at)`를 전 행에 쓰지 말 것.** `subscription.ended_at`은 **ACTIVE 구독에선 현재 결제주기 종료일(=다음 갱신 예정일, 미래)**이다(2026-07 기준 ACTIVE 1861건 중 1609건 미래). 전 행에 coalesce하면 아직 구독 중인 유저의 갱신일이 "해지일"로 둔갑 → 현재월 churn이 폭등한다(실측 4.75%→83%). **올바른 종료시점**:
  ```sql
  CASE WHEN status IN ('STOPPED','STOPPPED','ENDED')
       THEN COALESCE(stopped_at, ended_at)  -- 종료구독만 ended_at fallback(stopped_at NULL ~120건 구제)
       ELSE stopped_at END                   -- ACTIVE 등은 ended_at 무시(NULL=미해지)
  ```
  churn 분모·분자, 과거 활성 스냅샷의 "경계 종료시점" 모두 이 식을 쓸 것. `stopped_at`=실제 해지일, `ended_at`=다음 결제 예정일 — 섞으면 갱신을 해지로 오해.
- **⚠️ 구독-차량 1:1 바인딩은 2026-04-01 도입** (`represent_car_id` 설정률 ~95%→100% 시점). 그 전엔 구독 세차의 ~39%가 represent_car가 아닌 차에 발생 → **2026-04 이전 기간에 `represent_car_id`로 "구독으로 세차한 차"를 판정하면 왜곡**. 이전 기간은 reservation_car로 실세차 차량을 직접 볼 것 (검증 2026-07-07).

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
- ⚠️ **`source` 필터도 필수** — 4종 혼재: 예보=`KMA_PUBLIC_API`(probability 항상 있음)·`OPEN_METEO`, 실황=`KMA_PUBLIC_API_OBSERVED`·`OPEN_METEO_ARCHIVE`(probability NULL, amount_mm만). source 없이 dedup하면 예보/실황이 뒤섞임. 앱 우천 로직 기준 = 예보 `KMA_PUBLIC_API` + 실황 `KMA_PUBLIC_API_OBSERVED`.
- 참고: 앱의 "비예보 표시" 판정 = `RAIN` + 확률≥50%(3일 내)/60%(이후) + 강수량≥5mm (`rain-forecast-display.policy.ts`). 리터치 신청 가능 날짜에서 비예보일·주말 제외도 이 기준.
- ⚠️ **`reservation_retouch` 링크 부재를 "리터치가 아니다"의 근거로 쓰면 안 된다 (2026-08-06 실측, DS-1830).** 자동 리터치(`source_type='RAIN_RETOUCH'`)만 row를 만들고, **CS 수동 리터치(세차권 지급 후 예약)는 row를 아예 안 만든다** — 어드민 생성 수동 리터치 12건 전부 링크 0. 수동분 판정은 `service_id=136` + `partner_activity_log.description`(`리터치`/`우천 리터치`) + 직전 WASHED 세차 존재로.
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

**슬롯 타임 그리드 (capacity 집계용 근사, UTC → KST)**

⚠️ 아래 08~22 그리드는 **Grafana 공급량/가동률 집계용 근사 그리드**일 뿐, 고객에게 실제 노출되는 슬롯 시각의 출처가 아니다. 캐파 카운팅(1인당 5슬롯 등)에만 쓴다.

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

**실제 노출 슬롯 시각의 출처 (2026-07-13 확정) — ⚠️ caramel-api 파지 말 것**
- 콜 콘솔·고객앱 예약 슬롯 = **caramel-zero `apps/api` `scheduling` 도메인의 하드코딩 상수** (`generate-time-slots.policy.ts`, zero-api `POST /v1/admin/scheduling/time-slots/query`). ⚠️ 레거시 caramel-api `time-slot.service.ts`(TARGET_TIMES 08·10·12…)는 죽은 경로 — 여기 파면 헛다리.
- ⚠️⚠️ **반얀트리(BANYAN_TREE) 슬롯 ≠ 일반(DEFAULT) 슬롯 = 완전히 다른 시스템.**
  - **반얀트리**: 고정 상수 `SEOUL_BANYAN_TREE_SLOT_START_TIMES_UTC` → **KST 09·11·14·16·18** (반얀 주소=장충단로 60 매칭 시에만).
  - **일반(DEFAULT)**: zone·동선·이동시간 기반의 다른 스케줄링. **슬롯 시각 로직 미조사** — 위 08~22 그리드로 추론하지 말 것.
- 실제 노출 = 상수 그리드 ∩ rule 근무 윈도우 ∩ 가드(예약버퍼·시각겹침·하루 `MAX_RESERVATIONS_PER_DAY=7`).
- 그리드는 타입별 공용 상수 → 특정 디테일러만 다른 시각대 주려면 DB 아닌 **코드 변경 필요**.

**슬롯 가용 판단**
- X시 슬롯 공급 가능 = rule의 `start_time(KST) ≤ X시` AND `end_time(KST) ≥ X+1시`
- **`effective_from~to` 범위만 체크하면 과대 카운트** — 반드시 해당 요일의 rule 존재 여부를 함께 확인

**effective 경계 저장 컨벤션 (스케줄 생성/수정 시)**
- KST 자정 경계를 UTC로 저장: **D일부터 유효 = effective_from `'(D-1) 15:00:00'`**, 영구 = effective_to `'2099-12-30 23:59:59'`.
- 코드 lookup은 `dayjs(date).startOf('day')`(UTC 자정)와 `effective_from <= date <= effective_to` 비교 + 해당 요일 rule 매칭.
- 노출 시뮬레이션: `effective_from <= 'D일 00:00:00' AND effective_to >= 'D일 00:00:00'` + `day_of_week` + `zone_id` 조건으로 SQL 재현 가능.

**🔴 디테일러 일부하 비교는 건수만으로 하면 틀린다 — 개인 근무창을 반드시 함께 조인 (2026-07-27 이승제 6건 항의 실사례)**
- 표준 근무창은 rule `01:00:00~10:00:00` UTC(=**KST 10~19**)지만 **이른 조 `23:00:00~08:00:00`(=KST 08~17)가 여럿 있다** — 실측 명단: 이한결(177)·이승제(78)·이재형b(167)·황석찬(114). "이한결만 예외"로 알고 있으면 틀린다.
- **이른 조는 18시 이후를 못 받아 같은 건수가 더 짧은 창에 압축된다.** 실측 6건 배정 비교(2026-07-28): 10~19조는 `10·12·14·16·17·18`로 9시간에 퍼지지만 이른 조는 `08·10·11·12·14·16`으로 오전에 4건이 붙고 마지막 건 종료가 근무 종료(17시)에 딱 붙는다. (DEFAULT 슬롯 시각 상수 자체는 여전히 미조사 — 위 슬롯 섹션 경고 참조. 위 시각들은 배정 실측값이지 그리드 단정이 아니다.)
- ⟹ 부하 랭킹 쿼리에 `SUM(estimated_time)` + rule 윈도우(`DATE_FORMAT(wr.start_time,'%H:%i')`)를 함께 뽑을 것. 건수만 세면 이른 조 과부하가 안 보인다(실사례: 6건 이상 5명 중 이른 조가 2명이었고, 건수·총소요분으로는 이승제가 오히려 최하위였다).
- 근무창 밖 건을 "동선 좋으니 소화 가능"으로 임의 판단 금지 — 수락 여부는 디테일러별로 다르다(§6b 재배정 사전검증 참조).
- ⚠️ **파견 상주자는 파견기간에 `type='DEFAULT'` 스케줄이 0행일 수 있다 (2026-07-27 반얀 상주 6명 전원 확인).** 즉 그 기간의 근무시간 = 파견 근무창이 유일하다. DEFAULT로 근무창을 찾아 0행이 나오면 "판정 불가"가 아니라 **파견 스케줄(`type LIKE 'BANYAN_TREE%'` 등)을 볼 신호**다. 근무외 판정 전에 그 사람이 그 주에 가진 스케줄 `type`을 먼저 전부 뽑을 것.

**신규/복귀 디테일러 스케줄 생성 (활성 스케줄 0건인 경우)**
- rule만으로는 안 되고 `detailer_work_schedule` 헤더부터 INSERT 필요.
- 최근 운영 컨벤션: `slot_id = NULL`, `type = 'DEFAULT'`, description에 사유 메모.
- rule의 start/end_time은 `'1970-01-01 HH:MM:SS'` UTC (예: 10~19시 KST = `01:00:00`~`10:00:00`), `service_region_group_id = NULL`.
- Fill Rate = `실제 예약 디테일러 수 / 스케줄 기반 공급 가능 디테일러 수`

**detailer_work_schedule.type — DEFAULT만 있는 게 아니다 (2026-07-13)**
- `type` 값: `DEFAULT`(일반 존 배정) / `BANYAN_TREE`(반얀트리 주소 전용) / `BANYAN_TREE_EXTENDED`(반얀 확장 그리드, 2026-07-16 prod 실존 확인) / `HEY_DEALER`(외부 사업 이탈 마커, lookup에서 제외).
- ⚠️ 반얀 상주 조회 시 `type='BANYAN_TREE'` 등호 필터는 `BANYAN_TREE_EXTENDED`를 놓친다 — **`type LIKE 'BANYAN_TREE%'`** 로 잡을 것.
- 코드 lookup이 type별로 분리 조회 → **반얀트리 상주 배정은 zone rule이 아니라 `type='BANYAN_TREE'`** + rule `service_region_group_id=2`(서울 중구)·`zone_id=NULL`. zone 테이블만 뒤지면 못 찾는다.
- ⚠️ **`slot_id`(→`detailer_slot`)는 데드 데이터 (2026-07-13 확정).** 슬롯 생성 경로에서 안 읽힘 — slot_id를 바꾸거나 `detailer_slot`을 INSERT해도 실제 노출 슬롯 시각엔 무영향. 반얀 세팅 시 관례로 채우긴 하나(김형현·손정민 slot 3), 시각을 결정하는 건 slot_id가 아니라 **상수 그리드 ∩ rule 윈도우**다. 슬롯 조사에서 이 테이블 보지 말 것.
- 반얀 상주 디테일러 N명 = 슬롯당 캐파 N배 (slot_id 때문이 아니라 같은 시각대에 N명이 서빙).
- **기간 파견 패턴 = 스케줄 3토막**: ①기존 스케줄 `effective_to` 단축 ②파견 스케줄(기간 한정) INSERT ③복귀 스케줄(파견 종료 익일~영구) INSERT. ③을 빼먹으면 파견 종료 후 배정 공백.
- 🔴 **스케줄 무효화 관례 = `effective_from = effective_to` (2026-08-06 실측).** 파견 중 원존 차단 등에서 행을 지우지 않고 길이 0으로 눌러둔다(염철림165 sched 786 = `2026-08-06 15:00` 양쪽 동일). ⟹ **effective 판정은 반드시 `effective_from < X AND effective_to > X` (양쪽 strict)**. `BETWEEN`이나 `effective_to >= X`로 쓰면 무효화된 스케줄이 근무 중으로 잡힌다(위 §슬롯/근무 예시 중 `BETWEEN`·`effective_to >= 'D일 00:00:00'` 형태는 이 관례 이전 것이니 그대로 복사하지 말 것). 무효화 결과 그날 어떤 type의 스케줄도 없으면 슬롯 0 · work-day API `blocks: []`.
  - ⚠️ **파견 일정이 뒤로 밀리면 무효화가 남아 공백이 된다** — 염철림은 원존 차단으로 786을 눌렀는데 반얀 파견이 8/10~8/11로 미뤄져 **8/7~8/9 사흘간 아무 스케줄도 없는** 상태가 됐다. 파견 일정 변경 시 무효화 행을 되돌렸는지 함께 확인할 것.

**detailer_holiday 처리**
- 단기(≤7일) full-day (`from ≤ 당일 00:00` AND `to ≥ 익일 00:00`) → 실제 off
- 장기(>7일) → capacity 집계에선 무시 (파견/퇴사 등 운영 메모). ⚠️ **단 `memo`에 `퇴사`·`하차`·`출격보류`가 들어간 장기 row는 예외 — 실질 비가용인데 `booking_yn=1`로 남아 있는 경우가 있다**(김승규190 `퇴사 예정` 2026-08-05~12-30, 2026-08-06 실측). 인계·재배정 후보 선정에선 장기라도 배제할 것.
- 부분 시간 → 겹치는 슬롯만 차감. ⚠️ **매일 반복되는 4시간짜리 부분 블록이 수개월분 선삽입돼 있는 경우가 있다**(memo `셀원 품질 점검` = UTC 05:00~09:00 = KST 14~18시, 황석찬114에 4~8월분). 하루 겹침 COUNT로 "휴무"를 세면 오전 근무 가능자가 통째로 탈락 → **`TIMESTAMPDIFF(HOUR, from, to) > 8`로 종일/부분을 갈라** 종일만 종일 탈락시킬 것(§3c 항목 4).
- `v_detailer_holiday_daily` 뷰 한계 있음 — capacity 쿼리에서는 `detailer_holiday` 직접 조회 권장
- 🔴 **공휴일·전사휴무 캘린더 테이블은 없다 — `detailer_holiday`에 디테일러 1인당 1행으로 깔려 있다** (2026-07-29 확인). memo 규칙 `[전사휴무]<휴일명>`(예 `[전사휴무]대체휴일(광복절)` = 2026-08-17, 101행 종일 `(D-1) 15:00 ~ D 15:00`). ⟹ ①"그날 회사가 쉬는 날인가"는 `WHERE memo LIKE '[전사휴무]%'` 분포로 판별할 것 — 예약/슬롯 0건을 "수요 없음"이나 데이터 누락으로 오독하기 쉽다 ②**그 휴일에 0분(`from`=`to`) row인 사람 = 그날 예외적으로 일하는 사람**(반얀 단독 파견 등). 즉 0분 row는 무력화 표시일 뿐 아니라 "이 사람만 출근"의 시그널이다.
- ⚠️ **"왜 슬롯에 안 뜨나" 진단에선 반대 — 휴무는 길이 무관 하드 차단** (2026-07-13). 플래그(booking_yn 등)·스케줄·rule이 다 정상이어도 해당 날짜에 holiday row 있으면 노출 0. 운영이 파견/별동대를 **매일 full-day 휴무 bulk INSERT**로 마킹하는 패턴이 있으니(같은 created_at·memo 예 "정비별동대") 미노출 진단 시 `memo` 확인 필수.

**🔴 슬롯을 실제로 닫는 유일한 레버 = `detailer_holiday` 부분블록 INSERT (2026-08-05 실행·검증)**
- 특정 디테일러의 슬롯 1~2칸만 즉시 막을 때(개인 사유 외출 등): ``INSERT INTO detailer_holiday (detailer_id, `from`, `to`, memo)`` **4컬럼만**. 값은 **UTC**(KST−9h).
- ⛔ **rule `start_time`/`end_time` 축소로 근무창을 줄이려 하지 말 것** — DB엔 반영되는데 **prod 슬롯 API가 계속 옛 창을 반환**(2026-07-31 실측, 원인 미확정). 즉시 움직이는 건 holiday뿐.
- ⚠️ **`holiday_date`/`start_time`/`end_time`(prod 실존, DB_SCHEMA 표엔 누락)에 시각을 넣지 말 것** — 슬롯 경로가 안 읽는다. NULL로 둬도 정상 동작하고 `from`/`to`가 정본. 컬럼명만 보고 여기 `08:00`~`12:00`을 넣으면 조용히 무효.
- 🔑 **휴무 끝을 다음 그리드 시각과 정확히 같게 두면 그 칸만 죽는다** — 길이 0 FREE는 생성되지 않아 인접 칸은 보존된다. 예) 08·10시만 막고 12시 유지 = `from` KST 08:00 / `to` KST 12:00.
- **휴무는 신규 접수만 막고 기존 CONFIRMED 예약은 남는다** → 그 시각에 예약이 이미 있으면 재배정·연락이 별도로 필요.
- **검증 = 무인증** `GET https://api-prod.thetrive.com/v1/scheduling/detailers/{id}/work-day?addressId={addrId}&fromDate=&toDate=` → 해당 구간 `HOLIDAY` 전환 + **다음날 정상 FREE** 둘 다 확인. ⚠️ 블록 타입 키는 `type`이 아니라 **`kind`**(`FREE`/`HOLIDAY`/`RESERVATION`), 근무 없는 날은 `blocks: []`.
- 롤백 = 그 row DELETE 또는 `to`=`from`(위 무력화 관례).

**예약↔근무스케줄 정합성 감사 패턴 (2026-07-19, 반얀 재배정 사고 전수조사)**
- 재배정/파견 후 "예약이 디테일러 근무 밖에 배정됐나" 검증은 3축: ①근무윈도우 밖 = `reservation` × `NOT EXISTS`(rule 윈도우 매칭) ②휴무 겹침 ③동시각 이중배정 = `GROUP BY detailer_id, reservation_datetime HAVING COUNT(*)>1`.
- rule 윈도우 매칭 정석: `ru.day_of_week = UPPER(DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%a'))` (**KST 요일** 기준) + `TIME(CONVERT_TZ(r.reservation_datetime,...,'+09:00')) >= TIME(DATE_ADD(ru.start_time, INTERVAL 9 HOUR)) AND ... < TIME(DATE_ADD(ru.end_time, INTERVAL 9 HOUR))` (end 배타적). `ru.deleted_at IS NULL` 포함. 스케줄은 `effective_from <= r.reservation_datetime < effective_to`.
- ⚠️ **재배정 API는 근무윈도우 밖 배정도 통과시킬 수 있다** (실증 2026-07-19: 08~17 근무자에게 18시 예약 배정 성공 — 이한결 사례). "시스템이 막아줬겠지" 가정 금지 — 대량 재배정 후엔 위 감사 필수.
- ⚠️ **`detailer_holiday`에 `from`=`to`인 '무력화' row 실존** (blanket 휴무 해제 시 삭제 대신 from=to로 눌러두는 관례, 2026-07-18 반얀 파견 해제). from/to range 겹침 판정에선 자동 배제되지만, row 존재/COUNT 기반 "휴무 있음" 판정은 오판 → **`from <> to` 필터** 필수.

**재배정을 직접 실행할 때 — 대상 사전검증 필수 (2026-07-24)**
- 재배정 API(sales-admin `PUT /careplus/reservations-admin/{id}/schedule`, zero-api admin `PATCH`)는 대상 디테일러의 **근무시간·휴무·현직/퇴사를 전혀 검증 안 함** (`checkScheduleConflict`=같은 디테일러 동일시각 겹침만, `skipConflictCheckYn=true`면 그마저 스킵). 검증은 고객 슬롯조회 경로(`findActiveDetailers`)에만 있음 → **API 성공 ≠ 실제 가용.**
- ⟹ 재배정 대상을 고를 땐 아래를 **직접** 걸 것: ①Active 4조건(§3a: `booking_yn=1·retired_yn=0·deleted_yn=0·direct_yn=1`) ②출장 재배정이면 `supply_sheet.region <> '오토랩'`(고정샵은 필드 안 돎) ③대상 시각이 `detailer_holiday`(부분휴무 포함, from~to 둘 다 UTC 직접비교) 안에 없음 ④그 시각 겹치는 CONFIRMED 예약 없음 ⑤더미 `132/125/168` 제외.
- 🔴 **"그날 예약 0건 = 여유 있음"이 아니다 (2026-08-06 실측).** 2026-08-07 예약 0건인 디테일러 8명 중 7명이 연차·퇴사예정이었다(한홍구·김승규·남경우·김민호·김남용·장태훈·이승제). 건수로 인계처를 고르면 **가장 안 되는 사람만 뽑힌다.** 후보는 위 ①~⑤ + effective 스케줄 존재를 먼저 통과시킨 뒤 건수로 정렬할 것.
- ⚠️ **실제 테이블명은 `detailer_supply_sheet`** (문서·구두로 "supply_sheet"라 부르지만 `SHOW TABLES LIKE '%supply%'`엔 `detailer_supply_sheet`·`detailer_supply_load_log`·`detailer_supply_weekly_snapshot`뿐). 유용 컬럼: `name`·`status`·`cell_name`(셀장)·`region`(Z번호)·`phone_norm`·**`home_address`(자택, 디테일러 출퇴근 동선 판단용)**·`car_plate`·`work_start_date`. ⚠️ `name`·`phone_norm` 비교 시에도 **`COLLATE utf8mb4_general_ci` 양쪽에 붙일 것** — 안 붙이면 `Illegal mix of collations`로 죽는다.
- 현직 판별: `detailer_supply_sheet.status='현직'`이 정본(퇴사/하차/삭제/교육중 제외). ⚠️ `detailer.retired_yn`은 미신뢰 — 실제 퇴사자도 0인 경우 있음(주진우147, retired_yn=0인데 booking_yn=0·supply_sheet 퇴사). `booking_yn=0`이 실질 비활성 시그널. supply_sheet 조인=phone `REPLACE(phone,'-','') COLLATE utf8mb4_general_ci`, `status IS NULL`=로스터 누락(퇴사 아님, 확인 필요).
- ⚠️ **반얀 파견 예외**: 반얀 파견 디테일러(`detailer_work_schedule.type LIKE 'BANYAN%'`, 예 `BANYAN_TREE_EXTENDED`)는 정상근무 차단용 **종일 휴무**가 걸려도 그날 배정된 **반얀 예약(장충단로 60)은 본인 담당** → 휴무충돌 감사·재배정 대상에서 제외(2026-07-24 이형준161 사례).
- ⚠️ **반얀 예약 매칭은 `LIKE '%장충단로 60%'` 금지** — '장충단로 600'·'장충단로 60길'을 오탐한다. **`location REGEXP '장충단로 ?60($|[^0-9길])'`** 를 쓸 것(공백 없는 '장충단로60'까지 커버, caramel-zero `isBanyanAddress` 정규식과 같은 기준). ⚠️ 파이썬 `mysql.connector`로 실행할 때 `%`가 들어가면 이스케이프 함정이 있으니 REGEXP가 안전하다.
- ⚠️ **"이 예약이 셔플(17시 동선 재배정) 대상인가"는 DB 컬럼만으로 판정할 수 없다 (2026-07-26 확정).** `reservation.allow_shuffle_yn`(DEFAULT 1)은 *옮겨지는 예약* 쪽만 막는다 — 코드의 move 로직은 **받는 디테일러를 보지 않는다**(swap은 양쪽 예약을 본다). 즉 `allow_shuffle_yn=0`으로도 "그 디테일러에게 다른 예약이 들어오는 것"은 못 막는다(실사례: 2026-07-24 셔플이 을지로 예약 81101을 반얀 파견조 정순욱187에 배정). 반대로 반얀 예약은 **주소 문자열 게이트**(`user_address`의 address+building_name+jibun_address에 '반얀트리'/'장충단로 60'/'장충동2가 201' 포함 여부)로 이미 이동이 막혀 있어 `allow_shuffle_yn=1`이어도 안 옮겨진다. → 셔플 영향 판정은 반드시 코드 게이트(`libs/route-optimization`)를 함께 확인.
- 🔴 **운영이 슬랙에서 말하는 "이 예약 고정돼 있어요" = `reservation.allow_shuffle_yn=0`이며, "이 디테일러로 고정"이라는 뜻이 아니다 (2026-08-06 확립).** 어드민 콘솔 고정 버튼 = `pinNoShuffle(userId)`(zero `prisma-console-reservation-schedule.repository.ts`)이고, **유저 단위로** 그 사람의 활성 예약(CONFIRMED/IN_PROGRESS) 전부에 `allow_shuffle_yn=0`을 박는다. 담당자를 지정하는 필드가 **아니고, 수동 재배정을 막지도 않는다**(셔플 크론만 제외).
  - ⟹ "고정이라 못 옮긴다"는 보고를 그대로 받지 말 것. **검증법 = 그 고객의 과거·미래 예약 담당자 명단을 뽑는다**(`WHERE user_id=? ORDER BY reservation_datetime`). 매회 담당자가 다르면 고정 아님 → 인계 가능. 실사례: 8/7 잠실 건이 "고정"으로 보고됐으나 같은 고객의 9건이 남경우·진정철·이형준·고대진으로 제각각이었다.
  - ⚠️ 부작용: 이 플래그가 걸린 예약은 **셔플이 교정하지 못해 존 외 배정이 그대로 남는다**. 존 외 예약 진단 시 `allow_shuffle_yn`을 함께 뽑을 것(2026-08-07 예약 159건 중 0인 건 23건=14.5%).
  - 🔴 **이 누수는 진행형이다 — 1회성 청소로 끝나지 않는다 (2026-07-27 재발 실측).** 같은 패턴이 7/27 17:00:22에도 발생(#87098 반얀 16시 → 오전조 08~16인 정순욱187 = 근무 종료 경계 초과). 파견기간 중엔 **매일 17시 이후 새 위반이 생길 수 있으므로 주기 점검**이 필요하다(파견 tail 일괄 재배정과 별개 처방). 반얀 장소 예약도 안전하지 않다 — 장소 게이트는 이동을 막지만 **근무창은 아무도 안 본다.**

**주말 데이터 주의**
- 주말 디테일러 2~3명 → fill rate 스윙이 큼
- 평일만 분석하거나 8+ 디테일러 운영일 필터 적용 권장

**Grafana 참조**
- 디테일러 가동률 대시보드: uid `fe6dr4x83wwlca`
- Grafana API: `https://thetrive.grafana.net`
- 가동률 공식: `count(*) / (5 * count(distinct detailer_id))` — 총 예약 / (5슬롯 × 디테일러 수)

### 6b-2. 슬롯 수요 계측 = 미충족 수요 정본 (`time_slot_request_log` + `time_slot_result_log`) (2026-07-31)

**"고객이 예약하려 했는데 자리가 없었나"는 `reservation`으로 볼 수 없다.** 슬롯 조회가 일어날 때마다 남는 이 두 테이블이 유일한 경로다(2025-10-30~, 40.7만건). 존별 공급 부족·핵심지역 예약 불가 진단은 여기서 출발할 것.

- `time_slot_request_log`: `id`(**varchar UUID**, int 아님) · `user_id`(**NULL 많음** — 미인증 경로) · `address_id` · `latitude/longitude` · `from_date`/`to_date`(조회 창, 앱은 보통 **한 달**) · `zone_id`(2026-06~ 채움, 커버 75%) · `duration` · `last_detailer_id`
- `time_slot_result_log`: `request_id`(위 `id`와 조인) · `time_slot`(UTC) · `detailer_id` · `priority` · **`show_yn`**
- 🔴 **`show_yn = 1` 필터 필수.** 안 걸면 미노출 슬롯까지 세어 "슬롯 있었다"로 오독한다.
- 🔴 **`reservation_id`·`reserved_at`으로 전환율을 계산하지 말 것 — 0.2%만 채워져 있다**(2026-07: 63,536건 중 139건). 그대로 쓰면 전 존 전환율 0.0%가 나오고 "아무도 예약 안 한다"로 오답한다(실제로 한 번 걸림). 전환은 `reservation.created_at`이 요청 시각 +24h 안에 있는지로 따로 판정.
- **정본 지표 3개** (Grafana `0. 카라멜_TV 대시보드` uid `ju4ln4m` 패널 9 `원인_공급`이 이 조합):
  - `days_to_first_slot` = 요청일 → 첫 `show_yn=1` 슬롯까지 일수 (존별 P75가 핵심 — Z5 11일 vs Z12 3일 식으로 갈린다)
  - `slots_within_3days` = 요청일 ~ +2일 노출 슬롯 수 (중앙값 0 = 그 존은 사실상 예약 불가)
  - `D3초과%` = `days_to_first_slot >= 3 OR IS NULL` 비율
  - 요청 단위는 세션이 아니라 `(user_id, address_id, 요청일 KST)` **dedup 후** 세야 한다(한 번 보면 로그가 3~5건씩 쌓인다).
- 존 배정은 `address_id → user_address` 좌표 → `ST_Contains`(§2f). `zone_id` 컬럼은 커버가 75%라 전 기간 분석엔 좌표 판정이 안전.
- **어드민 화면이 이미 있다**: `/admin/map` = 슬롯 수요 지도(날짜별 존별 요청 수 + 근무 디테일러 수 + 폴리곤). zero PR #577, 2026-06-18 배포. 존 수급 질문에 새 도구를 만들기 전에 이걸 먼저 볼 것.
- ⚠️ **존별 인원·캐파를 셀 때 `dws.type='DEFAULT'` 필터를 넣어라.** 반얀 파견 스케줄의 rule도 `zone_id=8`이라 Z9로 합산돼 인원이 과대 집계된다(13명 중 6명이 반얀 상주 = 실효 7명). 위 대시보드 패널 12·15도 이 왜곡이 있다.
- ⚠️ 근무창 2시간 그리드로 만든 capacity 모델은 개인 편차·부분휴무를 놓쳐 **가동률 100%를 넘는 칸이 나온다**(실측 Z4 150%). 존 간 상대 비교용으로만 쓸 것.

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

**⚠️ 2026-07-27 정정: `crm_repair_order.paid_at` 컬럼이 생겼다 (아래 activity-log 서술은 그 이전 기준)**
- `paid_at` 커버리지 = PAID 619건 중 **616건**. 아래 "정산완료일 컬럼이 없음"은 이제 사실이 아니다.
- ⚠️ **단 두 소스가 크게 어긋난다**: 둘 다 있는 614건 중 **5분 내 일치 373건뿐, 148건은 1일 이상 차이**. 월 집계도 벌어진다(2026-04: `paid_at` 145만원 vs log+`modified_at` 폴백 335만원).
- 어느 쪽이 "정산완료일" 정본인지 **미확인**(paid_at=운영자 입력 실제 수금일 / log=UI 상태변경 시각으로 추정). 매출 집계에 쓰기 전 제품·경영지원에 확인할 것. 어느 쪽을 쓰든 **기간 비교 시 한쪽으로 통일**.
- ⚠️ **투자자 레터의 정비 매출은 이 테이블로 재현되지 않는다** — '26년 1Q 레터(1월 699·2월 1,236·3월 1,448만원)는 `paid_at`·`created_at`·마진 어느 조합과도 불일치. 회계 자체기장 출처로 추정. 상세 = memory `reference_wash_revenue_sources`.

**정산 완료일 = activity log 기준 + modified_at 폴백** (paid_at 도입 이전 방식)
- `modified_at` 단독은 메모 수정에도 갱신돼 부정확.
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

**🔴 세차범위(외부만/외부+내부)를 *집계*할 때는 `service.name`이 아니라 `service_id` 격자로 (검증 2026-08-03)**
- 단건 조회는 위 `s.name`으로 충분하지만, **`GROUP BY s.name`으로 집계하면 못 쓴다** — `user_service`에 붙는 CAR_WASH service id가 **85종**이고 프로모션·제휴 변형(`[토스] 올클린 케어`·`[프로모션]`·`[리터치] 외부만`·`올클린 케어 for 반얀트리`·`올클린 케어 (55)`·`[선물] 실내 + 실외 세차 1회권` …)이 60행 넘게 쪼개진다. 이름 3개만 보고 clean하다고 판단하면 표가 산산조각난다.
- **정본 격자 = `service.tier_id`(T1~T7) × 세차범위:**
  | 범위 | service_id (T1→T7) |
  |---|---|
  | 외부 + 내부 (ALLCLEAN) | 14 · 17 · 20 · 23 · 26 · 29 · 32 |
  | 외부만 (OUTSIDE_ONLY) | 15 · 18 · 21 · 24 · 27 · 30 · 33 |
  | 내부만 | 16 · 19 · 22 · 25 · 28 · 31 · 34 |
- 이 21개가 앱 정규 카탈로그분이고, 나머지 64종은 프로모션/제휴/패키지/구독 전용이다. **"정규 구매 기준" 집계는 이 격자로 좁히고, 격자 밖 비중을 함께 보고**할 것(리터치·제휴가 통째로 빠지므로 목적에 따라 포함 여부를 명시).
- 참고: 격자 밖이 무시할 수준이 아니다 — 리터치 `[리터치] 외부만`만 해도 WASHED 기준 수백 건 규모.
- 예약당 `user_service` 다중 row는 410/53,457 = **0.8%**(옵션·패키지 동반분), CAR_WASH 아닌 service.type(INSPECTION·MEMBERSHIP·WATER_REPELLENT)은 219/70,187 = **0.3%** → `user_service` 스키마 절의 `MIN(service_id)` dedup 패턴으로 충분하고 별도 `service.type='CAR_WASH'` 필터는 정밀 집계에서만 필요.

**구독 플랜의 상품 구성 조회 — `payment.name`('월 2회')만으론 구성을 알 수 없음**
- 구독 플랜명(월 1회/월 2회)은 어떤 세차 조합인지 말해주지 않는다. 구성은 구독에 연결된 발급 세차권으로 확인:
  ```sql
  SELECT s.name, us.created_at
  FROM user_service us
  JOIN service s ON s.id = us.service_id
  WHERE us.subscription_id = :sid AND us.deleted_yn = 0
  ORDER BY us.created_at
  ```
- 예: "월 2회" 구독 = 매월 갱신 시 `'외부 + 내부'` 1매 + `'외부만'` 1매 자동 발급 (검증 2026-07-13, 구독 3101).

**서비스 상품 이름 동일해도 내용 다를 수 있음**
- 같은 이름이라도 `description`이 다름. 예: `올클린 케어 (29)`는 왁스코팅 포함, `(55)`/`(35)`는 미포함.
- 상품 비교·집계 시 `name`만 보고 "동일"로 단정 금지. `description`도 함께 조회·확인.

**🔑 대면/비대면(고객 입회) 여부 = `wash_result.crm_type` (검증 2026-08-03)**
컬럼명이 "CRM 타입"이라 대면 여부로 보이지 않지만, 디테일러 앱이 세차 후 여기에 기록한다. **다른 대면 판정 컬럼은 없다.**

| 값 | 의미 | 건수(전량) |
|---|---|---|
| `ON_CALL` | 비대면 | 28,855 |
| `FACE_TO_FACE` | 대면 | 11,796 |
| `FACE_TO_FACE_EXPLAIN` | 대면(설명까지) — **2024-09~2025-04 레거시, 이후 미발생** | 818 |
| NULL | 미기록 | 975 (2.3%) |

- ⚠️ **`= 'FACE_TO_FACE'`만 쓰면 2025-04 이전 구간에서 대면이 과소집계된다.** 전 기간 분석은 `IN ('FACE_TO_FACE','FACE_TO_FACE_EXPLAIN')`.
- ⚠️ **대면율 분모는 `COUNT(*)`가 아니라 `crm_type IS NOT NULL`** — NULL 2.3%를 비대면으로 밀면 대면율이 낮게 나온다.
- 조인: `LEFT JOIN wash_result wr ON wr.reservation_id = r.id` (완료 전 예약엔 row 없음). 세차범위별로 보려면 같은 §6d의 「세차범위 집계 = service_id 격자」와 교차.
- 🔑 **실측 시그널(2025-08~2026-08, 1회권·live_users)**: 대면율은 **세차범위가 회차보다 크게 좌우**한다 — 외부+내부 첫 세차 2,214/4,615 = **48.0%** vs 외부만 191/879 = **21.7%**(2.2배). 내부 세차는 차 안 접근이 필요해 키 전달·입회가 물리적으로 발생. 회차가 늘면 둘 다 감소(외부+내부 6회차+ 30.2% / 외부만 11.7%). **"대면 접점이 있는 세그먼트"를 정의할 때 회차만 보면 틀린다.**

**세차 회차(n번째 세차) 매기기**
```sql
ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY r.reservation_datetime, r.id) AS nth
-- 모수는 status='WASHED'만. 구독/1회권을 섞어 순번을 매길지는 목적에 따라 명시할 것
-- (1회권만 필터한 뒤 순번을 매기면 "생애 n번째 세차"가 아니라 "n번째 1회권 세차"가 된다)
```
⚠️ MySQL `GROUP BY <alias>`는 SELECT의 CASE alias가 아니라 원본 표현식으로 묶이는 경우가 있다 — `CASE WHEN nth>=6 THEN '6+' ... END AS nth`로 버킷팅하고 `GROUP BY nth`하면 **에러 없이 6+가 안 합쳐진 채** 결과가 나온다. 버킷은 `LEAST(nth,6)` 같은 식으로 만들고 그 식으로 GROUP BY할 것.

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

**⚠️ `wash_result_image.status`는 BEFORE/AFTER 둘만이 아니다 (검증 2026-07-29)**
전량 분포: AFTER 258,839 / BEFORE 243,191 / **DEFAULT 42,551**(정보성) / DONE 584 / ON_PROGRESS 208 + 타이어 상세(`FRONT_TIRE_TREAD`·`REAR_TIRE_SIZE` 등) 20여 종 소량.
→ **전·후 사진 매수를 셀 때 `status IN ('BEFORE','AFTER')` 필터 없으면 약 8% 과대**(DEFAULT가 대부분). 반대로 "이 세차의 모든 사진"이면 필터를 빼야 한다 — 목적에 따라 명시할 것.
(참고 규모 2026-07-29, 테스터 제외 실고객 WASHED 기준: 사진 540,464장 / 사진 보유 세차 39,631건 = 세차의 94.3%, 세차당 13.6장.)

BEFORE/AFTER 섹션 종류:
- 외부: `OUTSIDE_FRONT`, `OUTSIDE_DRIVER_SIDE`, `OUTSIDE_PASSENGER_SIDE`, `OUTSIDE_FRONT_GLASS`, `OUTSIDE_DRIVER_SIDE_WHEEL`
- 내부: `INSIDE_DRIVER_SEAT`, `INSIDE_CENTER_FASCIA`
- 평가 컬럼(`evaluation_status`, `evaluated_at`, `evaluator`)은 현재 전량 `PENDING` — 미사용 상태.

**🔴 차량 거래(매매)는 DB에 기록 시스템이 없다 (2026-08-04 전수 확인)**

회계상 **연 100억원 규모의 최대 매출원**인데 DB엔 거래 이력이 한 건도 없다. "매매 실적 0" = 사업이 없다는 뜻이 **아니다.** 매번 재탐색하지 말 것:

| 테이블 | 행 수 | 실제 용도 |
|---|---:|---|
| `deal` | **0** | 빈 테이블 |
| `transaction_receipt` | **0** | 빈 테이블 |
| `heydealer_daily_report` | **0** | 빈 테이블 |
| `dealer` | 171 | 내부 담당자 리스트(이름/전화) — 거래 기록 아님 |
| `bank_account_transaction` | 1,275 | **디테일러 급여 정산**(`detailer_id` FK) — 매매 아님 |
| `vehicle_inspection` | 332 | 점검 기록, 마지막 행 2025-11-20 |

- `SHOW TABLES LIKE '%trade%'`·`'%sale%'` → 0건. 매매 전용 테이블 자체가 없다.
- ⟹ 매매 대수·매출·"세차 고객의 매매 전환율"은 **회계 기장 또는 계획치**로만 말할 수 있다. DB로 산출한 것처럼 쓰면 안 된다. 상세 = memory `reference_repair_and_trade_revenue_sources.md`.

### 6e. 쿠폰

- 테이블: `coupon_code`(개별 코드), `coupon_campaign`(파트너 캠페인 — **`partner_name`** 필드), `coupon_code_reward`(보상 정의), `coupon_code_usage`(사용 이벤트). **`coupon`/`discount` 테이블은 없다.**
- ⚠️ 코드명 LIKE 검색 오탐: `code LIKE '%KCC%'`는 랜덤 발급코드(예: `YKCCHAZB`)가 대량 매칭됨. 파트너 프로모션은 정확 매칭으로 특정.
- 쿠폰 → 발급 세차권 조인: `coupon_code_reward.id` → `user_service.coupon_code_reward_id`
- ⚠️ **캠페인→예약전환 조회 시 발급경로 3가지 다 확인**: 캠페인마다 세차권 연결 컬럼이 다르다 — ① `user_service.coupon_code_reward_id`(코드별 보상 경유) ② `user_service.coupon_campaign_reward_id`(캠페인 단위 보상 `coupon_campaign_reward` 경유 — 예: 자스민 캠페인 80 → reward id 86) ③ `service` 직결(코드 등록 즉시 특정 서비스 지급 — 예: "자스민 전용 무료 세차권" = `service.id=140`, `coupon_code_reward` 레코드 자체가 0건). 한 경로가 0건이라고 "예약 전환 0건"으로 단정하지 말 것 — 캠페인명으로 `service.name` 매칭 + `coupon_campaign_reward.campaign_id` 양쪽을 교차 확인.
- **`coupon_campaign_reward.group_no` = 회차 묶음** (제휴처 N회권 패키지 구조): N회권 상품은 회권별로 **별도 캠페인**으로 등록된다(예: 현대백화점 프리미엄 세차 패키지 1/3/5회권 = campaign 73/74/75, `partner_name='현대백화점'`). 각 캠페인의 reward를 `group_no`로 회차별로 묶는다 — `group_no=1~N`이 각 회차분(그룹마다 `reward_type='SERVICE'` 1개 + `OPTION` 세트 반복), `group_no=NULL`은 회차 무관 패키지 전체 1회 보너스(`PROMOTION`·추가 `OPTION` 등). 따라서 "N회권"의 실제 세차 횟수는 `COUNT(DISTINCT group_no) WHERE reward_type='SERVICE'`로 세야 정확(reward row 수로 세면 OPTION/PROMOTION 포함돼 과대). `reward_type`은 `SERVICE`/`OPTION`/`PROMOTION` 혼재.
- **N회권 정의의 두 번째 경로 = 코드 상수 `EntitlementPackageDefinition`** (위 쿠폰 캠페인 구조와 별개, 2026-07 확인): 프리미엄/반얀트리 세차 패키지의 구성(회차 수·포함 옵션)은 **DB product 테이블에 없고** caramel-zero `apps/api/src/domains/commerce/domain/entitlement/entitlement-package-definition.ts`에 하드코딩(`PREMIUM_WASH_PACKAGE_1/3/5`, `BANYAN_WASH_PACKAGE_5/10`). product/car_tier_product에서 패키지 구성을 찾으면 허탕. **매 회차 왁스(option 1)+살균(option 2)은 전 패키지 공통 강제 세트**(`requiredOptionIds=[1,2]` 공통 상수), standalone 옵션(유막제거 option 3)만 패키지별로 다름(현백 5회권=1장, 반얀 10회권=2장, 반얀 5회권=0장).
- **패키지 발급 실데이터 조회** = `entitlement_package_instance`(1행=1회차, `package_name`·`status`) ⋈ `entitlement_package_item`(`package_instance_id`, `item_type`='SERVICE'/'OPTION', 연결 컬럼은 **`user_service_id`/`user_option_id`로 분리** — 범용 item_id 컬럼 없음) → `user_option.option_id` → `options`(⚠️ 테이블명 복수형, `option` 아님). 옵션 id: 1=프리미엄 왁스 코팅, 2=차량 전체 살균, 3=유막 제거/발수 코팅.
- ⚠️ **패키지 오지급 회수 = 5테이블 세트 전부** (2026-07-21 반얀 오발급 실사례, 회수 API 없음 — 승인된 SQL만 경로): ① `user_service.deleted_yn=1` ② `user_option.deleted_yn=1`(강제 왁스/살균 + standalone 유막까지) ③ `entitlement_package_instance.status='CANCELLED'` + `deleted_at=NOW()` ④ `entitlement_package_item.status='CANCELLED'` ⑤ 미수금 `crm_note.deleted_yn=1`(안 지우면 CS가 틀린 금액 수금). user_service만 지우면 instance/item이 ACTIVE로 남아 옵션 자동묶음·중복차단 로직이 유령 패키지를 봄. soft-delete 컬럼 혼재 주의: instance=`deleted_at`(datetime), item=`status`만(soft-delete 컬럼 없음), user_service/user_option/crm_note=`deleted_yn`. 실행 전 `used_yn=0 AND reservation_id IS NULL` 가드로 미사용분만 특정.
- ⚠️ **쿠폰 세차권으로 생성된 예약만 조회할 땐 `user_id` JOIN 금지** — `coupon_code_usage → user_id → reservation.user_id`로 붙이면 그 유저의 쿠폰과 무관한 **전체 예약**이 섞인다. 반드시 `user_service.reservation_id` 경유로 연결 (위 3가지 발급 컬럼 중 캠페인 구조에 맞는 것으로 user_service를 특정한 뒤 reservation_id로 조인).
- ⚠️ **`coupon_code.name`과 `payment.name`을 `UNION`/`UNION ALL`로 합치면 MySQL 1253 "Illegal mix of collations" 에러.** `payment.name`=`utf8mb4_general_ci`, `coupon_code.name`=`utf8mb4_unicode_ci`로 컬레이션이 다르다(테이블별 컬레이션 혼재 — 다른 테이블 쌍도 의심). 수정은 파라미터가 아니라 **컬럼 쪽에 `COLLATE`**: `p.name COLLATE utf8mb4_unicode_ci`. 목킹 유닛테스트로 못 잡고 실 DB 실행에서만 드러남 — 새 테이블 쌍을 UNION으로 합칠 땐 `SELECT TABLE_NAME,COLUMN_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='caramel-prod' AND TABLE_NAME IN (...)`로 먼저 대조.
- **전환 퍼널 = 발급≠사용**: ① `coupon_code_usage`(수령) → ② `user_service.reservation_id IS NOT NULL`(예약) → ③ `reservation.status='WASHED'`(완료). 무료 쿠폰은 ①→②에서 대량 이탈.
- 리텐션/매출은 `user_service.paid_amount`와 `payment`(status='PAID') 양쪽으로 교차검증. 무료세차 당일 결제는 현장 옵션 업셀 — `payment.paid_at > 무료세차 washed_at`로 진짜 재방문만 분리.
- **쉘 계정 어뷰징**: 무료 쿠폰 코호트엔 `app_user.phone IS NULL` + 랜덤 이름(`name REGEXP '^[A-Za-z0-9]{6,8}$'`) + 예약 0건인 가짜 계정이 섞임. 실사용자 모수는 **`phone IS NOT NULL`** 필터.
  - 어뷰징 점검: `user_address.address`+`detail_address`로 세대 묶기, 같은 주소 생성 버스트 탐지, `app_user.dealer_id`/`created_by`로 딜러 경유 확인, `app_user.phone`과 `detailer.phone` 대조(디테일러 셀프-어뷰징).
- ⚠️ **프로모션 "종료" 판단 함정**: 로그인 게이트(`/careplus/auth/promotion/*`)가 막혔다고 쿠폰까지 막힌 게 아니다. `POST /careplus/coupon/apply`는 프로모션 상태와 무관한 앱 공용 엔드포인트로, 검증은 `coupon_code.expired_at`/`max_usage_count`만 본다. "프로모션 막혔나요?" 질문엔 로그인 엔드포인트뿐 아니라 **해당 쿠폰의 `expired_at`도 같이 확인** 필수 — 안 그러면 로그인 게이트만 막고 코드 자체는 방치돼 계속 재적용 가능한 뒷문이 남는다(KCC·토스 사례 반복).
- ⚠️ **`coupon_code.name` LIKE 검색 시 코드 모델 착각 주의**: 같은 `name`으로 캠페인당 **1개 공유코드**(KCC `voucher_kcc`)인 경우와 **유저당 1개씩 개별 발급**(토스 "토스 유저 쿠폰", 5만 row)인 경우가 섞여 있다. `SELECT * WHERE name LIKE '%키워드%'`로 순진하게 조회하면 후자는 row가 수만 개 쏟아진다 — 먼저 `COUNT(*) GROUP BY name`으로 코드 개수 모델부터 확인. 미사용 코드 수 계산 시 `coupon_code_usage`는 `COUNT(*)`(usage row)와 `COUNT(DISTINCT coupon_code_id)`(실사용 고유 코드 수)가 다르므로 반드시 distinct 기준으로 뺄 것.

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
- **직접 짜지 말 것 — 완성본이 있다: `~/claude/scripts/tmp_mar_revenue.sql`.** 위 5단계가 전부 구현돼 있다. 날짜 리터럴(`'2026-03-01' AND '2026-03-31'`) 두 군데만 바꿔 실행하면 `wash_count / total_revenue / avg_revenue_per_wash`가 나온다.
- ⚠️ **`reservation_revenue`는 테이블이 아니다** — 위 SQL 안의 마지막 CTE 이름이다. `JOIN reservation_revenue`를 쓰면 실행 자체가 실패한다. (2026-07-26 실사례: 테이블로 착각해 "매출 산출 불가"로 오판 후 근사치로 대체함)
- ⚠️ **`cbr_daily_revenue_snapshot.total_revenue`를 보고용 매출로 쓰지 말 것** — 실제 대비 **25~30% 과소**. (2026년 5월: 스냅샷 1.36억 vs 실제 1.80억) 빠른 감만 볼 때 외 금지.
- 검증 기준: 위 SQL 재현값 vs `Caramel_monthly(A)` 시트 확정값 오차는 **+0.4~0.6%가 정상**(2026년 3·4월 실측). 이 범위를 넘으면 필터를 의심할 것.
- ⚠️ **후불(현장수금) 예약은 이 매출 SQL에서 통째로 0원이다.** CTE가 `IF(us.payment_id IS NULL, 0, …)`라 payment가 없는 후불 예약은 금액이 0으로 깔린다. 후불을 포함한 매출을 내려면 `reservation_onsite_collection` 수금액(§ 해당 섹션 공식)을 **세차일(`reservation.reservation_datetime`) 기준으로 별도 가산**해야 한다. (2026-07-27 CBR v2 실측: 7/20주 타겟 매출 1,477만 → 후불 8건 74.7만 누락 = -5.1%)
- ⚠️ **제휴처 오프라인 수금 매출은 DB 어느 매출 쿼리에도 안 잡힌다.** 두 패턴 모두 "결제 row를 봤으니 반영됐다"고 착각하기 쉬우니 `amount`가 아니라 **`amount − point`(현금)** 로 확인할 것:
  - **현대백화점 팝업 패키지** = `payment` row는 **있다**. 다만 `metadata.syntheticPointPayment=true`·`source='COUPON_PACKAGE_REDEEM'`로 **amount 전액이 POINT**(`payment_medium` CASH=0, POINT=amount)라, `amount − point` 공식을 그대로 쓰면 **0원으로 상쇄**된다. (2026년 6~7월 PACKAGE amount 합 5,635만 vs 그 공식상 현금 654만) → **이 point는 고객 포인트 잔액이 아니라 제휴 정산용 합성값이므로 차감하면 안 된다.** 매출/GMV 집계 시 예외 처리할 것:
    ```sql
    -- 포인트 차감에서 COUPON_PACKAGE_REDEEM 제외 (CBR v2 #335/336 채택, 2026-07-27)
    - IF(JSON_UNQUOTE(JSON_EXTRACT(p.metadata,'$.source')) = 'COUPON_PACKAGE_REDEEM', 0,
         COALESCE((SELECT SUM(pm.amount) FROM payment_medium pm
                   WHERE pm.payment_id = p.id AND pm.medium = 'POINT'),
                  CAST(JSON_UNQUOTE(JSON_EXTRACT(p.metadata,'$.point')) AS SIGNED), 0))
    ```
    인식 시점 = `paid_at` = 쿠폰 등록/지급일(구매일 아님. 실제 현금은 제휴처가 받아 우리 PG를 안 거친다).
    🔴 **그래서 `payment.type='PACKAGE'`의 건수·금액 추이를 "5·10회권 판매"로 읽으면 오답이다.** 팝업 쿠폰 사용분이 같은 type으로 들어와 판매처럼 보인다 — 실측 2026-06 PACKAGE 195건 중 **279건 상당이 `프리미엄 세차 패키지 1회권`(COUPON_PACKAGE_REDEEM)**이고 실제 5·10회권 판매는 **8건 399만원**뿐이었다(2026-07은 380건 vs 7건). 회권 판매만 세려면 `source <> 'COUPON_PACKAGE_REDEEM'` + `name LIKE '%회 이용권%'`로 좁히고, **반얀 지급분은 payment에 없으니 `crm_note`를 따로 더할 것**(바로 아래 항목).
  - **반얀트리 5·10회권** = `payment` row 자체가 없다(어드민/콜콘솔 grant + 계좌입금). `user_service`(service **137** '프리미엄 세차 패키지 올클린 케어')가 `product_id NULL·payment_id NULL·paid_amount 0`으로 지급되므로 **user_service엔 금액이 없다.** **금액 정본 = `crm_note.memo LIKE '%회권 지급 · 수금할 금액%'`** — grant 1tx가 남기는 로그에 금액이 박혀 있다(예: "반얀트리 프리미엄 세차 10회권 지급 · 수금할 금액 750,000원"). 5회권 400,000 / 10회권 750,000, 회차 구분은 memo 텍스트로만(`entitlement_package_instance.package_name`엔 회차수 없음). ⚠️`crm_note.created_at`은 UTC.
  - **유효 판매 판정 4조건** (그냥 crm_note를 세면 과대집계된다):
    ```sql
    -- 반얀 회권 유효 판매/수금액 (2026-07-27 검증: 16건 11,650,000원 = 운영 수동집계 일치)
    SELECT MIN(n.created_at) ts, n.user_id,
           CAST(REPLACE(REGEXP_SUBSTR(n.memo,'[0-9,]+원'),',','') AS UNSIGNED) amt
    FROM crm_note n JOIN live_users lu ON lu.id = n.user_id
    WHERE n.memo LIKE '%회권 지급 · 수금할 금액%'
      AND n.deleted_yn = 0                                    -- ① 취소된 note 제외
      AND EXISTS (SELECT 1 FROM user_service us               -- ② 지급 세차권 생존 = 회수분 제외
                  WHERE us.user_id = n.user_id AND us.service_id = 137 AND us.deleted_yn = 0)
    GROUP BY n.user_id, DATE(DATE_ADD(n.created_at, INTERVAL 9 HOUR)),  -- ③ 오지급→재지급 중복제거
             CAST(REPLACE(REGEXP_SUBSTR(n.memo,'[0-9,]+원'),',','') AS UNSIGNED);
    -- ④ live_users(테스트 계정 제외) — 7/19 내부 테스트 배치 8명이 여기서 걸러진다
    ```

**헤이딜러(외부공급) 세차 — `manual_wash_adjustment`**
- `reservation`에 안 잡힌다. 별도 테이블 `manual_wash_adjustment`의 `SUM(count)`, 날짜 컬럼은 `wash_date`(KST 저장, 변환 불필요).
- ⚠️ **`memo='헤이딜러'`만 필터하면 누락** — `memo='조준호'`도 외부공급이다. **둘 다 합산**(전체 합산이 맞다). 2026년 월평균 조준호분 ~100건.
- 매출 환산은 `건수 × 8.80만원`(고정 가정, (A)시트 헤이딜러 객단가와 동일). 위 세차 매출 SQL엔 포함되지 않으므로 따로 더할 것.
- 마감 후 retro 입력으로 과거 월 수치가 ±25건 움직일 수 있다 — 이전 마감값과 다르면 정상.

**구독 갱신 결제액이 매달 다른 이유 — `payment.metadata.prices`로 추적**
- 같은 구독인데 결제액이 월마다 변동(예: 111k~124k)하면 프로모션 할인. `metadata.prices[]`의 `originalPrice`(정가) vs `price`(실결제) 차이 + `promotionApplicationId` 존재 여부로 판별.
- 첫 결제의 `metadata.params`엔 유입 UTM(utm_source 등)이 그대로 저장돼 있어 구매 유입 채널 역추적 가능. (검증 2026-07-13)

### 6g. CRM 메시지 발송 로그 (`message`)

CRM·트랜잭션 메시지 발송 기록 테이블.

- **컬럼 의미**: 수신자=`customer_id`(→`app_user.id`, ⚠️ `user_id` 아님), 발송시각=`created_at`(UTC), 채널=`lms_type`(`ALIMTALK`/`PUSH`/`MMS`/`SMS`/`LMS`), 캠페인 식별=`type`(varchar 200, 예 `reservationGuide002`·`firstWash_expire`), 발송상태=`status`(기본 `REQUESTED`).
- ⚠️ **`sent_yn` 함정**: **ALIMTALK은 발송돼도 `sent_yn=0`·`status='REQUESTED'` 고정**(PUSH만 `sent_yn=1`). `sent_yn=1`로 필터하면 알림톡이 통째 누락된다. **행 존재 = 발송요청**으로 집계(도달 확정 아님 — BizM 도달 콜백 미반영).
- 채널은 `type`별로 대체로 고정(윈백·구독갱신·자동예약=ALIMTALK, 쿠폰만료는 알림톡/푸시가 별도 `type`).
- 🔴 **`reservation_id`는 대체로 NULL이다 — 예약 통지 이력을 `reservation_id`로 찾으면 "안 나갔다"는 오답이 나온다** (2026-07-26 실측: 당일 `reservationUpcoming003` **216건 전부 NULL**). **예약 통지 조회 = `WHERE customer_id = :app_user_id AND created_at >= :당일`** 로. `reservation_id`가 채워지는 type도 일부 있으니(`RESERVATION_INFO_DETAILER` 등) 둘 다 확인.
- **D-1 예약확인 알림톡 `reservationUpcoming003` = 매일 18:00 KST 발송, 본문에 담당 디테일러 실명이 들어간다** (`message.message` JSON → `request.msg`: "안녕하세요 고객님, 내일 세차를 담당할 **{디테일러명}**입니다…" + 예약시간·방문장소). ⟹ **재배정 판단 시 "고객이 이미 이 이름을 봤는가"의 판정 근거**(§3c 항목 6). 본문 확인은 `SUBSTRING(m.message,1,150)`으로 충분.
  - 🔴 **발송시각 09:00은 오답이다 (2026-08-06 교정).** 최근 11일 전수(`GROUP BY 날짜, MIN(created_at)`) **전부 18:00 KST**. 이걸 09:00으로 알고 있으면 **재배정 시한을 반나절 잘못 잡는다** — "오전에 이미 이름이 나갔으니 늦었다"고 포기하거나, 반대로 "내일 아침까지 여유 있다"고 오판한다(실사례: 8/7 존 외 예약 조율에서 시한을 "내일 07:00"으로 잘못 보고했다가 정정).
  - ⚠️ **결번이 있다** — 주말 외에도 안 나가는 날이 섞인다(7/31·8/1 0건). "오늘 아직 없다"를 곧바로 "장애"로 읽지 말고 **당일 18:00 이전인지부터 확인**할 것.
  - **당일 07:00 `parkingInfo001`(주차위치 안내)에도 디테일러 이름·연락처·차량번호가 들어간다** — 통지 노출 시점은 D-1 18:00과 D-day 07:00 **두 번**이다.
- 🔴 **`message.message`의 `request` JSON은 구/신 2종이 혼재한다 — `request.msg`로만 뽑으면 신규분이 통째로 NULL이다 (2026-08-06 실측).** 구=`{msg, phn, tmplId, title, …}`(알림톡 레거시 경로) / 신=`{content, recipient, channel, metadata, trackingKey, …}`. 최근 30일 기준 `tmplId` NULL이 32,366건으로 **최대 그룹**인데 이건 "템플릿 없음"이 아니라 **신규 스키마라 그 키가 없는 것**이다. 본문·템플릿 조회는 `COALESCE(JSON_UNQUOTE(JSON_EXTRACT(message,'$.request.msg')), JSON_UNQUOTE(JSON_EXTRACT(message,'$.request.content')))` 처럼 **양쪽을 함께** 볼 것. 수신번호도 `request.phn`(구) vs `request.recipient`(신)로 갈린다.
- **CRM 7일 예약전환 측정**: received(테스터 제외 live_users §5b) → 발송 후 7일 내 `reservation` 생성(`r.user_id = m.customer_id`, `r.created_at` 기준, `r.deleted_yn=0`. raw·비인과). `(customer_id, type)`별 첫 발송 dedup. 상세·재현쿼리 = caramel-api `docs/superpowers/specs/2026-06-30-crm-kill-keep-map.md` §2/§6.

### 6h. 050 안심번호/통화 (`telephony_call_log`·`customer_vno`) (2026-07-16)

디테일러↔고객 050 통화(세종 050Biz) 기록. 2026-07-08 prod 가동.

- **`telephony_call_log`**: 050 경유 통화의 CDR. `call_started_at`은 **UTC 저장**(+9h 필요, `reservation_datetime`과 동일). 예약 귀속 = `reservation_id`/`detailer_id`/`customer_vno_id` — 크론 `telephonyAttributeCalls`(*/10분)가 사후에 채움. **미귀속 2~4건/일은 정상**(부분귀속 설계: vno 매칭만 되고 예약 모호). 발신자/수신자 = `calling_num`(디테일러 실번호)·`vno`(고객 050)·`called_num`(고객 실번호).
- ⚠️ **"통화 수 적다" ≠ 장애**: 예약 중 050 통화가 잡히는 비율은 **30~45%가 정상 밴드**. 디테일러 절반가량은 앱 050 발신을 안 씀(문자 사용 — SMS는 시스템 미캡처 / 저장된 실번호 직발신). 19시 KST 통화 스파이크(일요일 포함)는 D-1 저녁 사전 확인콜로 정상.
- **`customer_vno`**: 고객에게 050 동적 부여. **user_id 단위 키잉(폰번호 아님)** — 한 폰이 여러 app_user면 특정 user_id에만 붙음. 통화↔vno 매칭 구간 = `[assigned_at, COALESCE(cleared_at, expires_at)]`. ⚠️ `ASSIGN_FAILED` 대량(수십 건/일) = 더미폰 유저(01012345678류) 매시 재시도 반복이지 시스템 장애 아님 — `COUNT(DISTINCT user_id)`로 먼저 확인.
- **크론 실행 기록 = `job_execution`**(`job_id`→`job.name`, telephony 크론 8종). ⚠️ **status='FAILED'여도 장애 단정 금지** — 유저 1명 실패해도 execution 전체가 FAILED로 기록됨. `result` JSON의 `failureCount`/`successCount`를 먼저 볼 것.

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
| technician | varchar | 디테일러 **이름 문자열**(비정규화, 99.9% 채워짐). 🔴 귀속·`GROUP BY`는 `detailer_id`로 — 이걸로 묶으면 **동명이인이 합쳐진다** → §3e |
| estimated_time | int | 티어·서비스에서 나온 **산식(계획 소요분)**. 🔴 실제 소요시간 아님 — 실측은 `wash_result.created_at`→`finished_at` → §3e |
| address_id | int | FK → user_address.id |
| subscription_id | int | **98% NULL — 구독 여부 판단에 사용 불가** |
| location | text | 주소 문자열 |
| detailed_location | text | 상세 주소 (동/호수) |
| parking_info_content | text | 주차 안내 메모 |
| deleted_yn | tinyint | 0=정상 |
| allow_shuffle_yn | tinyint | 1=셔플 크론 리배정 허용 / **0=콘솔 "고정"(유저단위 `pinNoShuffle`). 담당자 지정 아님·수동 재배정은 가능** → §3c |
| note | text | **디테일러앱 현재 예약 상세 "메모" 블록에 보이는 내부 지시란**(고객 미노출). 판매 약속·동반 방문 등은 여기 써야 담당자가 본다 |
| detailer_note | text | 디테일러가 세차 완료 시 쓰는 칸. **다음 방문 이력 탭에만 렌더** → 이번 예약 지시로 쓰면 안 보인다 |

🔴 **`note`/`detailer_note` 쓰기 경로 = DB UPDATE만이 아니다 (2026-08-06 실측).** sales-admin `PATCH https://gateway-prod.thetrive.com/careplus/reservations-admin/{id}` 가 `note`·`detailerNote`·`complaintYn`·`complaintReason`·`overtimeExpectedReason`를 받는다(`UpdateReservationAdminDto`, `'note' in dto` 방식이라 **보낸 키만** 갱신 → 다른 필드 안전). 알림 부작용 없음. ⟹ **prod DB 직접 UPDATE 하지 말고 이 PATCH를 쓸 것.** 단 이 API는 **덮어쓰기**이므로 기존 값이 있으면 먼저 SELECT해서 이어붙인 전문을 보낼 것.

**차량 조인 (car_id 직접 없음 → reservation_car 경유):**
```sql
JOIN (SELECT reservation_id, MAX(car_id) car_id FROM reservation_car GROUP BY reservation_id) rc
  ON rc.reservation_id = r.id
JOIN car c ON c.id = rc.car_id AND c.deleted_yn = 0
```

---

### reservation_change_log (예약 변경 이력, 행위자 판별용)
컬럼은 `id·created_at·modified_at·reservation_id·actor_type·data` **6개뿐**.
- ⚠️ **`actor_id`·`reason`·`from_status`·`to_status` 컬럼은 없다.** 전부 `data` JSON 안이다:
  `JSON_UNQUOTE(JSON_EXTRACT(data,'$.reason'))`, `$.actorId`, `$.toStatus`.
- 생성 사유 → 경로 매핑 (2026-07 실측): `CUSTOMER_RESERVATION_CREATED`=`CUSTOMER_DIRECT` / `CHECKOUT_SETTLED_RESERVATION_CREATED`=`CHECKOUT_SETTLEMENT` / `ADMIN_RESERVATION_CREATED`=`source_type` NULL+`booked_online_yn=0` / `ADMIN_RAIN_RETOUCH_RESERVATION_CREATED`=`RAIN_RETOUCH`.
- 빙의로 만든 예약은 `actor_type='CUSTOMER'` + `actorId`=고객으로 남는다 → **어드민 행위를 이 컬럼으로 못 걸러낸다.**

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

🔴 **`phone`은 UNIQUE가 아니다 — `WHERE phone = ?` 스칼라 서브쿼리는 터진다 (2026-08-06 실측).** 재가입·탈퇴 반복으로 한 번호에 행이 쌓인다(실측 `01092828753` = **218행 중 217행 `deleted_yn=1`**). `WHERE user_id = (SELECT id FROM app_user WHERE phone='…')` 는 `Subquery returns more than 1 row`로 **에러**, `IN (...)`으로 바꾸면 이번엔 탈퇴 계정들의 옛 예약이 섞여 조용히 오답이 된다.
- 특정 예약의 고객을 찾을 땐 **역방향**으로: `WHERE r.user_id = (SELECT user_id FROM reservation WHERE id = :rid)`.
- 번호로 시작해야 하면 `deleted_yn=0`으로 좁히고 **그래도 여러 행이면 최신 `id`**를 쓰되, "한 사람"으로 묶는 집계는 §4b-13(`GROUP BY 전화번호`)을 따를 것.

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

⚠️ **이름으로 디테일러 찾을 땐 `detailer.name`으로 검색** — `JOIN app_user ON user_id` 후 `app_user.name`으로 찾으면 일부 디테일러가 누락된다 (실사례 2026-07-16: 염철림(165)은 app_user.name으로 안 잡히고 detailer.name에만 있음).

---

### subscription
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | int | PK |
| user_id | int | FK → app_user.id |
| status | varchar(25) | `ACTIVE`/`STOPPED`/`CREATED`/`ENDED`/NULL (오타 `STOPPPED` 소량). ⚠️`PAUSED` 없음 — 일시정지는 paused_at |
| represent_car_id | int | FK → car.id (구독 대표 차량) |
| product_id | int | FK → product.id |
| started_at | datetime | 구독 시작일 |
| stopped_at | datetime | 해지 시점 (churn 판정 → §5d). STOPPED인데 NULL ~90건 |
| paused_at | datetime | 일시정지 시점 (ACTIVE + NOT NULL = 일시정지) |
| ended_at | datetime | ⚠️해지일 아님. ACTIVE에선 현재 결제주기 종료일(=다음 갱신 예정일, 미래). 종료판정은 §5d CASE식으로 |
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
| postpaid_yn | tinyint(1) | 0=선불, 1=후불(레거시: 선불권 소진 시 자동생성 후불권) **⚠️ 온보딩 '후불 결제(현장수금)' 예약은 postpaid_yn=0으로 생성됨 — 후불 판별에 이 컬럼 단독 사용 금지, `reservation_onsite_collection` 참조** |
| applicable_car_id | int | 차량 FK **⚠️ 15%만 채워짐 — 차량 조인 부적합** |
| ended_at | datetime | 세차권 만료일 **⚠️ 무한대 sentinel이 여러 값으로 혼재 — 아래 참조** |

- ⚠️ **취소 반환 = soft-delete + 새 row 재발급** (기존 row는 `deleted_yn=1`·`reservation_id` 유지, 새 미사용 row 생성) → 상세 §5c.
- ⚠️ **고객 보유 세차권 수는 `used_yn=0`만 세면 안 된다** (미래예약 선점분 20% 누락) → 상세 §5c.

**`ended_at` = 실효 만료일이고, 값이 지저분하다 (2026-07-31 실측)**
- **게이팅 실재**: zero-api `prisma-entitlement.repository.ts`가 사용가능 세차권을 `OR: [{ended_at: null}, {ended_at: {gte: now}}]`로 거른다. 장식 컬럼이 아니므로 "보유 세차권" 쿼리엔 만료 조건을 반드시 넣을 것.
- **무한대 sentinel이 한 값이 아니다** (deleted_yn=0 기준 분포): `2999`=39,832 · `2027`=17,619 · `2026`=5,553 · `2029`=3,104 · **`2099`=1,613** · `2025`=1,305 · NULL=568 · `2028`=208 · **`9999`=93** · 2030/2083/2098 소량. `YEAR(ended_at)=2999`만 무한으로 처리하면 2099·9999가 실만료일로 오분류된다.
- **발급 경로별 만료 규칙**: 어드민 지급(`POST /v1/admin/users/{id}/tickets`)·쿠폰 발급 = **정확히 3년** (`user-service-expiration.policy.ts` `ISSUED_ENTITLEMENT_VALID_YEARS=3` + `endOfSeoulDateAfterYears` → 저장값 `YYYY-MM-DD 14:59:59` UTC = KST 23:59:59). 구독 발급분은 결제주기마다 제각각.
- ⚠️ **어드민 지급 경로가 두 개고 만료 규칙이 다르다 (2026-08-06 실측, DS-1830).**
  - **zero** `POST /v1/admin/users/{id}/tickets` → 만료 **정확히 3년**, `product_id` 채움.
  - **레거시** `POST /users-admin/{userId}/rewards` (sales-admin `사용권 지급` 드로어) → **운영자가 만료일을 직접 고른다. 화면 기본값이 `dayjs().add(1,'month')`** (`GrantRewardDrawer.tsx:38`)라 대부분 +30/31일로 찍힌다.
  - **레거시 경로 지문**: `partner_activity_log_id` NOT NULL + `product_id` NULL + `paid_amount` NULL.
    `partner_activity_log`(`action='SERVICE_ISSUED'`) 조인 → `description`에 **운영자가 쓴 메모**, `partner_id`에 지급자가 남는다. 발급 출처를 물으면 이 조인이 1순위다.
  - ⚠️ **만료기간으로 발급 경로를 가르지 말 것** — "30일권"은 별도 경로가 아니라 화면 기본값이다. 코드 상수인지 UI 기본값인지 확인 없이 나누면 한 경로를 둘로 센다.
  - ⚠️ 드로어의 service 드롭다운은 `comment !== 'DEPRECATED'`만 필터한다(`:28`) → **내부용 service도 CS 지급 화면에 그대로 노출된다.**
- 🔴 **유효기간 일괄 연장 시 `ended_at < 목표일` 가드 필수** — 조건 없이 UPDATE하면 2999/2099/9999 행이 함께 걸려 **연장이 아니라 단축**이 된다.
- 만료일 변경은 SQL 직접 UPDATE 대신 어드민 API `PATCH /v1/admin/users/{userId}/tickets/SERVICE/{ticketId}`. **전필드 덮어쓰기**(`deletedYn,endedAt,paidYn,postpaidYn,reservationId,usedYn` 전부 `.strict()`)라 빠뜨린 값은 날아간다 — 현재값을 읽어 그대로 재전송할 것.

**⚠️ 무료/유료 판별에 쓰면 안 되는 컬럼 2개 (2026-07-26 실측)**
- **`paid_amount`는 2026-05부터 채워지기 시작했다.** 2026-01~04 첫 세차 `user_service`는 **전부 0**이고, 5월 565건 중 443건·6월 670건 중 233건만 0이다. 시계열로 유·무료를 가르면 4월 이전이 통째로 "무료"가 되어 완전히 틀린다.
- **`paid_yn`은 거의 항상 1이라 판별력이 없다** (첫 세차 기준 월별 99~100%). 무료 프로모션 세차도 1로 들어온다.
- **권장 판별**: 결제 조인으로 판정한다 — `user_service.payment_id` → `payment`(`deleted_yn=0`, `status IN ('PAID','PARTIAL_CANCELED')`)의 `amount > 0`이면 유료, payment 없거나 `amount=0`이면 무료. 구독/1회권 구분은 `user_service.subscription_id` NULL 여부(§5d). 첫 결제 유형으로 가르는 대안은 first-touch `payment.type`(`SUBSCRIPTION`/`VOUCHER`/`PACKAGE`).

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

### user_option (예약-옵션 연결) (2026-08-06 실측)
옵션(내부세차 추가·왁스·살균 등)은 **`user_service`가 아니라 `user_option`**. 옵션 마스터는 `options`(복수형, `option` 아님).

- **"결제한 옵션이 그 예약에 반영됐나" 판정 = `user_option`에 `reservation_id=<예약> AND paid_yn=1 AND used_yn=1 AND deleted_yn=0` row 존재.** `user_service`에서 옵션 row를 찾으면 영영 못 찾는다.
- 🔴 **`paid_yn=1` + `used_yn=0` + `reservation_id` 있음 = 미반영 버그 상태.** 디테일러 앱 예약상세 API(`prisma-detailer-reservation.repository.ts`)가 `reservation_id=X AND used_yn=1`인 옵션만 조회하므로, 결제는 됐는데 디테일러에게는 안 보인다. (2026-08-06 예약 #83490 CS 실사례)
  - 원인: 옵션 결제 정산을 레거시 caramel-api와 zero-api가 경합한다. `cart.metadata.autoUseOptions` → `used_yn=1` 후처리는 **레거시에만** 있고, zero-api가 먼저 `payment.status='PAID'`로 바꾸면 레거시가 멱등 early-return 해서 후처리를 통째로 스킵한다. 빈도는 월 1~3건.
  - 잔존 건 탐지: `WHERE paid_yn=1 AND used_yn=0 AND reservation_id IS NOT NULL AND deleted_yn=0` + 예약 status 미완료.
- **어느 서버가 그 row를 썼는지 판별 = `modified_at` tz 지문** (다른 테이블에도 적용 가능): `modified_at`이 `ON UPDATE CURRENT_TIMESTAMP`(서버 tz=**KST**)인 테이블에서, 레거시 caramel-api처럼 `modified_at`을 안 넘기는 writer가 쓰면 **KST 벽시계**로 찍히고, zero-api처럼 Prisma가 `modified_at: new Date()`를 명시하는 writer가 쓰면 **UTC**로 찍힌다. `created_at`(UTC)과 대조해 **+9h면 레거시, 같은 tz면 zero-api**. 로그 없이 writer를 특정할 수 있는 거의 유일한 단서.
- 옵션 단건 추가 결제는 `payment.type='OPTION'`이 아니라 **`VOUCHER`**, `metadata.pathname='/payment/options'`·`metadata.autoUseOptions=true` (§7 payment 참조).

---

### reservation_onsite_collection (온보딩 후불 결제/현장 수금, 2026-07-11 prod~)
온보딩 v3의 **'후불 결제' 예약 canonical marker**. 예약 시 결제 없이 세차 현장에서 수금.

- **후불 예약 판별 = 이 테이블에 row 존재 + `status <> 'CANCELED'`.** (⚠️ `user_service.postpaid_yn` 아님 — 온보딩 후불의 user_service는 `postpaid_yn=0`으로 생성됨. postpaid_yn=1은 레거시 구독 후불권.)
- 컬럼: `reservation_id`(UNIQUE FK→reservation), `user_id`(FK→app_user), `status`(PENDING=수금대기/REQUESTED/CONFIRMED/CANCELED, NOT NULL DEFAULT PENDING), `collection_method`(CARD_TERMINAL/BANK_TRANSFER/PAYMENT_LINK), `requested_at`. created_at은 UTC 저장.
- 예약 취소 시 status→CANCELED로 함께 전이됨.
- **수금액 계산**: `reservation_onsite_collection_item.amount_snapshot` 합(`canceled_at IS NULL`만) + `reservation_onsite_collection_item_adjustment.amount` 합(할인=음수, 쿠폰 등).
- 후불 선택 가능 조건: 타겟 차량(`car_model_target.is_target=1`)만.

```sql
-- 신규 예약 선불/후불 분류 (테스터·취소 제외)
SELECT CASE WHEN roc.id IS NOT NULL THEN '후불' ELSE '선불' END AS pay_type, COUNT(*)
FROM reservation r
JOIN app_user au ON au.id=r.user_id AND au.test_yn=0 AND au.deleted_yn=0
LEFT JOIN reservation_onsite_collection roc
  ON roc.reservation_id=r.id AND roc.status<>'CANCELED'
WHERE r.created_at >= %s AND r.created_at < %s  -- UTC 경계
  AND r.deleted_yn=0 AND r.status<>'CANCELED'
GROUP BY 1;

-- 후불 예약별 수금액
SELECT roc.reservation_id, roc.status,
 (SELECT COALESCE(SUM(i.amount_snapshot),0) FROM reservation_onsite_collection_item i
   WHERE i.collection_id=roc.id AND i.canceled_at IS NULL)
 + (SELECT COALESCE(SUM(a.amount),0) FROM reservation_onsite_collection_item_adjustment a
   JOIN reservation_onsite_collection_item i2 ON a.collection_item_id=i2.id
   WHERE i2.collection_id=roc.id AND i2.canceled_at IS NULL) AS amount_to_collect
FROM reservation_onsite_collection roc WHERE roc.status<>'CANCELED';
```
- ⚠️ **`status`는 세차가 끝나도 `PENDING`에 머문다** — 수금완료 전이가 없다(2026-07-27 실측: 전체 49건이 PENDING/CANCELED 두 값뿐, WASHED 예약도 PENDING). "수금 완료" 필터를 걸면 전부 0건이 된다. `status <> 'CANCELED'`로만 거를 것.
- **온보딩 상품 구매를 선불·후불 통틀어 세려면 `user_service.product_id`를 쓴다.** 후불도 온보딩 시점에 user_service가 product_id와 함께 생성되고 `payment_id`만 NULL이라, 결제 유무와 무관하게 한 소스로 잡힌다. `payment`/`cart`로 조회하면 후불 절반이 통째로 빠지고, `reservation_onsite_collection_item`으로 조회하면 취소분이 남는다(user_service는 `deleted_yn=0`으로 자동 정리됨).
  ```sql
  -- 온보딩 코스(라이트/베이직/장마 대비 풀코스) 일별 구매 고객수, 선불+후불 통합
  SELECT DATE(DATE_ADD(us.created_at, INTERVAL 9 HOUR)) d, pr.name, COUNT(DISTINCT us.user_id)
  FROM user_service us JOIN product pr ON pr.id = us.product_id
  WHERE us.deleted_yn = 0 AND pr.type = 'VOUCHER'
    AND (pr.name LIKE '라이트%' OR pr.name LIKE '베이직%' OR pr.name LIKE '장마%')
  GROUP BY d, pr.name;
  ```
  ⚠️ 코스 상품은 **tier별로 product row가 7개씩** 따로 있다(2026-07-15 생성, id 4037~4057). `product_id IN (…)`로 특정 코스를 집으려 하지 말고 **이름으로 묶을 것**.

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
| type | varchar(25) | `VOUCHER`=1회권, `SUBSCRIPTION`=구독, `OPTION`=옵션, `PACKAGE`=패키지 **⚠️ PACKAGE엔 제휴 쿠폰 사용분이 섞인다 — 회권 판매 집계 전 §6c의 `COUPON_PACKAGE_REDEEM` 경고 확인** / ⚠️ NULL 존재(`IFNULL(type,'')` 비교) / ⚠️ 앱 '세차 옵션 추가' 결제는 `OPTION`이 아니라 `VOUCHER`로 저장됨 |
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
