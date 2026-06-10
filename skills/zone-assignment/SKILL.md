---
name: zone-assignment
description: "디테일러를 어느 zone에 배정할지 결정하는 분석 스킬. Use when: 신입 디테일러 zone 배정, 임시 파견 배치, 디테일러 N명 어디 보낼지, 디테일러 zone 추천, 어떤 동네에 넣을까, '디테일러 배정', 'zone 배정', '존 배정'. zone-change(DB 실제 변경)와 다름 — 이건 결정 단계까지만."
scope: team
owner: juseong
side-effects:
  - db-read
tags:
  - 디테일러
  - zone
---

# /zone-assignment — 디테일러 zone 배정 결정

디테일러 N명을 어느 zone에 보낼지 데이터로 결정하고, 운영팀에 보낼 슬랙 글까지 만든다.
실제 DB 변경은 이 스킬에서 안 한다 — 결정 후 `/zone-change`로 넘긴다.

## 언제 쓰나

- 신입 디테일러 1~N명 입사 → 어느 zone에 넣을지
- 임시 파견 배치 (예: 단기 7명을 5일간 다른 zone에)
- 일괄 재배치 (한가한 zone → 바쁜 zone 보내기)
- "이 사람 어디 zone이 좋을까?"

## 입력 (3가지)

1. **디테일러 명단** — 이름 또는 전화번호 list (없어도 가능 — 그러면 zone 상태만 보고 후보 추천)
2. **시작일 + 기간** — 예: `2026-05-04 ~ 2026-05-08` (5일)
3. **(선택) 본인 home zone** — 본인이 평소 일하던 zone (있으면 우선 고려)

## 절대 원칙 (산수)

이 스킬은 아래 8가지 원칙 위에서 돈다. 어기지 말 것.

1. **fill rate은 supply 변동에 깨진다.** 디테일러 한 명 새로 넣으면 fill 갑자기 -10점. 진짜 추세는 수요(`time_slot_request_log`) 시계열로 봐야. fill rate 절대 단독 기준 X.
2. **수요 추세도 외부 노이즈 큼.** 비, 워크샵, 공휴일로 직전 4주 -28% 같은 큰 하락은 일시적. 4주 추세보다는 절대량 + D3초과율 같은 "현재 부족" 지표가 견고.
3. **단순 normalize 점수는 가짜.** "지표/max 다 더해서 한 줄 점수" 거부. 절대값으로 비교.
4. **진짜 미충족 = D3초과% × 일평균 요청** (3일 안에 슬롯 못 본 손님 수/일). "요청 - booked"는 안 잡은 이유 분리 안 됨.
5. **1명 = 어디든 5건/일 흡수** (진짜 미충족 5+ zone에서). 인당 부담·한계효용 가짜 계산. 미충족 5- zone은 idle 손실.
6. **`time_slot_request_log`는 신규 조회 손님만 잡힘.** 구독자 자동 갱신은 슬롯 조회 없이 잡혀서 누락. 미래 booked의 80~95%가 자동 갱신인 zone이 많음. 따라서 **공급 부족 = 신규 미충족 + 자동 갱신으로 차 있는 capa**.
7. **신규 capa 여유 = 인원 × 5 - 일평균 미래 booked**. 신규 손님 받을 수 있는 진짜 여유. 여유율 (= 여유 / capa) 낮을수록 부족.
8. **결정 우선순위**:
   - (a) 진짜 미충족 5+ zone인가 (5 미만 = idle 손실)
   - (b) 신규 capa 여유율 낮은 곳
   - (c) D3초과% 큰 곳
   - (d) 거리·단골 매칭 (운영 자연성)

---

## 5단계 프로토콜 (순서대로)

### Step 1: 입력 확정

명단 + 기간 + (있으면) home zone 받기. 누락이면 AskUserQuestion.

```
명단 예시: 김준혁(Z9), 한용진(Z14), 한홍구(Z16) ...
기간: 2026-05-04 ~ 2026-05-08
```

### Step 2: zone별 현재 상태 측정 (4개 메트릭)

명단에 있는 디테일러는 측정에서 **제외**한다 (배정 전 상태로 봐야 하므로).

> **`{exclude_detailer_ids}` 치환 규칙**: 명단의 detailer.id를 콤마 구분으로 넣되, **빈 명단이어도 반드시 `0`을 넣을 것** (예: `NOT IN (0)` — 0은 detailer.id에 없으므로 모든 디테일러 포함). 빈 리스트(`NOT IN ()`)는 SQL 문법 에러.

#### 2-1. 인원 + 미래 booked + 자동 갱신 비중

`{from_date}`, `{to_date}` (KST 날짜), `{exclude_detailer_ids}` 치환.

```sql
WITH future_res AS (
  SELECT
    r.id,
    r.user_id,
    z.id AS zone_id,
    z.name AS zone_name,
    CASE WHEN sub.user_id IS NOT NULL THEN 1 ELSE 0 END AS is_subscriber
  FROM reservation r
  LEFT JOIN zone z
    ON ST_Contains(z.area, ST_GeomFromText(CONCAT('POINT(', r.longitude, ' ', r.latitude, ')')))
  LEFT JOIN (
    SELECT DISTINCT user_id FROM subscription
    WHERE status = 'ACTIVE'
  ) sub ON sub.user_id = r.user_id
  WHERE r.deleted_yn = 0
    AND r.status IN ('CONFIRMED','WASHED','REPORT_SENT')
    AND DATE(r.reservation_datetime + INTERVAL 9 HOUR)
        BETWEEN '{from_date}' AND '{to_date}'
),
zone_headcount AS (
  SELECT
    z.id AS zone_id,
    z.name AS zone_name,
    COUNT(DISTINCT d.id) AS headcount
  FROM zone z
  LEFT JOIN detailer_work_schedule_rule dwsr
    ON dwsr.zone_id = z.id
    AND dwsr.deleted_at IS NULL
  LEFT JOIN detailer_work_schedule dws
    ON dws.id = dwsr.schedule_id
    AND DATE(dws.effective_from) <= '{from_date}'
    AND DATE(dws.effective_to) >= '{to_date}'
  LEFT JOIN detailer d
    ON d.id = dws.detailer_id
    AND d.booking_yn = 1
    AND d.retired_yn = 0
    AND d.deleted_yn = 0
    AND d.direct_yn = 1
    AND d.id NOT IN ({exclude_detailer_ids})
  GROUP BY z.id, z.name
)
SELECT
  zh.zone_name,
  zh.headcount AS '인원',
  zh.headcount * 5 AS 'capa/일',
  ROUND(COUNT(fr.id) / (DATEDIFF('{to_date}', '{from_date}') + 1), 1) AS '미래 booked/일',
  ROUND(SUM(fr.is_subscriber) / NULLIF(COUNT(fr.id), 0) * 100, 0) AS '구독자%',
  ROUND(zh.headcount * 5 - COUNT(fr.id) / (DATEDIFF('{to_date}', '{from_date}') + 1), 1) AS '신규 여유/일',
  ROUND(
    (zh.headcount * 5 - COUNT(fr.id) / (DATEDIFF('{to_date}', '{from_date}') + 1))
    / NULLIF(zh.headcount * 5, 0) * 100,
    0
  ) AS '여유율%'
FROM zone_headcount zh
LEFT JOIN future_res fr ON fr.zone_id = zh.zone_id
GROUP BY zh.zone_id, zh.zone_name, zh.headcount
ORDER BY
  (zh.headcount * 5 - COUNT(fr.id) / (DATEDIFF('{to_date}', '{from_date}') + 1))
  / NULLIF(zh.headcount * 5, 0) ASC;
```

> **주의 — zone 폴리곤 밖 누락**: `reservation.latitude/longitude`로 zone 매핑할 때 `ST_Contains`가 NULL을 반환하는 케이스가 약 11% 있다 (zone 폴리곤 밖). 이 예약들은 `fr.zone_id IS NULL`이라 집계에서 빠진다. 외곽 zone(Z0, Z7, Z14, Z17)에서 더 크게 누락될 수 있음.
>
> **주의 — UTC ↔ KST**: `effective_from/to`는 UTC DateTime이다. 위 쿼리는 `DATE(effective_from)`으로 UTC 날짜만 비교한다. 현재 운영상 등록 패턴은 `effective_from = YYYY-MM-DD 06:00:00 UTC` (= KST 당일 15:00) 또는 `effective_to = YYYY-MM-DD 05:59:59 UTC` (= KST 당일 14:59:59) — 즉 UTC 날짜와 KST 날짜가 일치해서 현재는 누락 없음. 하지만 등록 방식이 바뀌면(예: KST 자정 = UTC 15:00 방식으로 저장되면) UTC 날짜가 KST 기준보다 하루 작아져 ±1일 오차 발생. 엄밀히 하려면 `DATE(effective_from + INTERVAL 9 HOUR)`로 KST 변환 후 비교. Step 2 결과가 이상하면 가장 먼저 확인할 것.

#### 2-2. 진짜 미충족 (D3초과% × 일평균 요청)

직전 28일 기준. 4주는 노이즈 (비/공휴일) 있을 수 있으니 별도 sanity check 권장.

**D3초과 정의**: 요청자가 요청일~3일 후까지 슬롯을 본 적이 없는 비율. `time_slot_request_log` 요청 → `time_slot_result_log`에서 `show_yn=1` 결과가 그 기간 안에 있는지로 판단.

```sql
WITH recent_req AS (
  SELECT
    tsrl.id AS request_id,
    tsrl.user_id,
    tsrl.address_id,
    DATE(tsrl.created_at + INTERVAL 9 HOUR) AS req_date,
    z.id AS zone_id,
    z.name AS zone_name
  FROM time_slot_request_log tsrl
  LEFT JOIN zone z
    ON ST_Contains(z.area, ST_GeomFromText(CONCAT('POINT(', tsrl.longitude, ' ', tsrl.latitude, ')')))
  WHERE tsrl.created_at + INTERVAL 9 HOUR
        BETWEEN ('{from_date}' - INTERVAL 28 DAY) AND '{from_date}'
    AND tsrl.user_id IS NOT NULL
),
req_d3 AS (
  SELECT
    rr.user_id, rr.address_id, rr.req_date, rr.zone_id, rr.zone_name,
    MAX(CASE WHEN res.id IS NOT NULL THEN 1 ELSE 0 END) AS saw_slot
  FROM recent_req rr
  LEFT JOIN time_slot_result_log res
    ON res.request_id = rr.request_id
    AND res.show_yn = 1
    AND DATE(res.time_slot + INTERVAL 9 HOUR)
        BETWEEN rr.req_date AND rr.req_date + INTERVAL 3 DAY
  GROUP BY rr.user_id, rr.address_id, rr.req_date, rr.zone_id, rr.zone_name
)
SELECT
  zone_name,
  ROUND(COUNT(*) / 28.0, 1) AS '일평균 요청',
  ROUND(SUM(CASE WHEN saw_slot = 0 THEN 1 ELSE 0 END) / COUNT(*) * 100, 0) AS 'D3초과%',
  ROUND(SUM(CASE WHEN saw_slot = 0 THEN 1 ELSE 0 END) / 28.0, 1) AS '진짜 미충족/일'
FROM req_d3
WHERE zone_id IS NOT NULL
GROUP BY zone_id, zone_name
ORDER BY SUM(CASE WHEN saw_slot = 0 THEN 1 ELSE 0 END) / 28.0 DESC;
```

> **요청 dedup 단위**: `user_id × address_id × req_date(KST)` (1명이 같은 주소·같은 날 여러 번 조회해도 1건으로 셈).

#### 2-3. 두 결과 합쳐 종합 표

```
| Zone | 인원 | 신규 여유/일 | 여유율% | D3초과% | 진짜 미충족/일 | 구독자% |
| --- | --- | --- | --- | --- | --- | --- |
| Z3  | 2  | 3.0 | 30 | 83 | 22 | 80 |
| ... | ...| ... | ...| ...|... |... |
```

여유율 낮은 순 + 진짜 미충족 큰 순으로 정렬.

### Step 3: 인터뷰 (거리·단골 자연성)

운영팀에 물어봐야 하는 질문 정리:
- 디테일러별 거주지 (직선 거리 우선, 인천 등 떨어진 곳 회피)
- home zone 단골 (자기 zone에 단골 많으면 home 우선)
- 운영팀 신호 ("이 사람은 가능하면 본인 zone")

답 받기 전엔 잠정 안 만들기. 여유율·미충족만으론 결정 안 됨.

> **단순 케이스 예외**: 신입 1명만 들어오는 경우엔 인터뷰 무겁게 가지 말고 거주지만 받고 Step 4로. 7명 임시 배치 같은 묶음 결정에선 풀 인터뷰.

### Step 4: 분배안 (산수 + 거리)

각 디테일러마다 1명씩 결정.

#### 0번 (사전 검사 — 가장 강한 제약)

배정 대상자 중 **현재 1인 zone의 유일 인원**이 있는지 먼저 본다.
→ 있으면 그 디테일러는 **home 유지 고정**. 1~3 검토 불필요.
→ 0명 zone 만들면 안 됨 > 그 외 모든 우선순위

(예: Z17이 1명짜리 zone인데 그 1명이 명단에 있으면 → Z17 유지. 미충족 5- 라도.)

#### 1번 우선순위 (그 외 디테일러)

1. **진짜 미충족 5- zone**은 후보에서 제외 (idle 손실)
2. **본인 home zone이 5+ 미충족**이면 → home 유지 (단골·운영 자연)
3. **본인 home이 5- 또는 home이 없음** → 여유율 낮고 D3초과 큰 zone 중 거리 가까운 곳

#### 분배 후 검증

- 각 zone의 신규 여유 변화 (배정된 zone에서 -5/일 됨)
- **회사 전체 흡수 = (미충족 5+ zone에 배정된 인원) × 5 × 영업일**
  - idle zone 또는 home 유지(5- zone)에 묶인 인원은 흡수 0
  - 예: 7명 중 3명이 5+ zone 배정 → 3 × 5 × 5일 = 75건
- 0명 zone 안 만들었나 (0번 사전 검사 결과 다시 확인)

### Step 5: 슬랙 글 + 다음 액션

운영팀(강희준 등)에 보낼 글 자동 생성:

```
{기간} 디테일러 {N}명 zone 배정안 공유합니다.

## 결론

| 디테일러 | 배정 zone | 거리(본인 거주지~zone) | 근거 |
| --- | --- | --- | --- |
| {이름} | {zone} | {km} | {home 유지 / 미충족 5+ 분배 / 0명 회피 등} |
| ... | ... | ... | ... |

## 산수 근거

각 zone 현재 상태 (배정 전):
- {Z3}: 인원 {2}명, 신규 여유 {3.0}/일 (여유율 {30}%), 진짜 미충족 {22}건/일, 구독자 비중 {80}%
- {...}

핵심 산수:
- 진짜 미충족 = D3초과% × 일평균 요청 = 3일 안에 슬롯 못 본 손님 수
- 신규 여유 = 인원×5 - 일평균 미래 booked = 자동 갱신으로 차고 남는 진짜 신규 capa
- 1명 = 미충족 5+ zone에서 5건/일 흡수

예상 흡수: 약 {N}건/주 (5+ zone에 배정된 {n}명 기준)

## 운영팀 확인 부탁

- 거주지·단골 맞나요?
- 충돌 예약 있을까요? (있으면 일괄 전화 변경 필요)
- {시작일} 적용 OK?

확정되면 DB UPDATE 실행 (zone-change 스킬 사용).
```

### Step 6 (선택): zone-change로 넘기기

운영팀 확정 후 디테일러별로 `/zone-change <이름> <zone>` 호출.
이 스킬에선 DB 변경 안 함 — 결정·설명까지가 끝.

---

## 절대 하지 말 것

- ❌ "요청/인당 평준화"만으로 결정 — 자동 갱신으로 다 차서 못 받는 zone 못 잡음
- ❌ "요청 - booked"를 미충족으로 정의 — 안 잡은 이유 분리 안 됨
- ❌ normalize 점수 합산 (가짜 점수)
- ❌ 진짜 미충족 5 미만 zone에 보내기 — idle 손실 (단, 1인 zone 유일 인원의 home 유지는 예외)
- ❌ 1명짜리 zone 0명 만들기 — 서비스 연속성
- ❌ fill rate 단독 기준 — supply 변동에 깨짐
- ❌ 4주 추세 단독 기준 — 비/공휴일 노이즈 큼
- ❌ 회사 흡수량 = 보낸 인원 전부 × 5 × 영업일 — idle zone에 간 인원은 흡수 0

## 함께 보면 좋은 자료

- 메모리: `project_zone_dynamic_assignment.md` — 이 스킬을 만든 대화의 전체 맥락 + 8가지 산수 원칙
- 스킬: `/zone-change` — 결정 후 실제 DB 변경 (`detailer_work_schedule_rule` UPDATE/INSERT)
- 플랜: `practice/business proposal/plan-zone-dynamic-assignment.md` — 한가한→바쁜 zone 운영 실험 (5/12 1라운드)
- 쿼리 레퍼런스: `QUERY_REFERENCE.md` — KST 변환, 예약 상태 필터, zone 매칭 방식
