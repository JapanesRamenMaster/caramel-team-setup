-- =============================================================
-- 일별 이론적 최대 세차량 (Capacity) 쿼리 v5
--
-- 변경 이력:
--   2026-04-05 - work_schedule + supply_sheet 3-way JOIN으로 변경
--   2026-04-08 - v4: rule 기반 동적 슬롯 + 파견 별도 처리 + 부분 차단 holiday
--   2026-05-04 - v5: daily_capacity 스케일 의미 정정
--                - (A) rule 디테일러 slot_count를 daily_capacity / 5로 스케일
--                  (기존: slot_count는 근무시간으로만 결정되어 daily_capacity 영향 0)
--                - (B) 파견 디테일러는 daily_capacity 무관하게 매일 5슬롯 고정
--                  (기존: daily_capacity 곱셈 → 의도와 정반대)
--                - 파견자는 (A)에서 명시적으로 제외 (rule 보유한 파견자도 (B)로만 잡힘)
--                - 검증: daily_capacity=5 결과를 baseline으로, 6일 때 (rule+future) 부분만
--                  1.2배, 파견 부분은 동일 → 전체는 ~+18-19% 증가 (파견 비중에 따라)
--
-- 사용법:
--   ${daily_capacity} → rule 디테일러 1인당 풀근무일 기준 세차 수 (기본 5, 시뮬레이션 변수)
--   ${sim_month}      → 시뮬레이션 대상 월 시작일 (예: '2026-04-01')
--
-- active 구성:
--   (A) rule 디테일러 (파견 제외): 요일별 work_schedule_rule 기반 동적 슬롯
--                                  × daily_capacity / 5 스케일
--   (B) 파견 디테일러: 매일 5슬롯 고정 (daily_capacity 무관)
--   (C) 교육중 미래 입사 예정자: detailer 미등록, work_start_date 이후 카운트
--                                × daily_capacity (rule 그룹에 합류 예정이므로 스케일)
-- =============================================================

WITH RECURSIVE
params AS (
  SELECT
    ${daily_capacity} AS daily_capacity,
    STR_TO_DATE('${sim_month}', '%Y-%m-%d') AS month_start
),
bounds AS (
  SELECT p.daily_capacity, p.month_start, LAST_DAY(p.month_start) AS month_end
  FROM params p
),
calendar AS (
  SELECT b.month_start AS d FROM bounds b
  UNION ALL
  SELECT DATE_ADD(d, INTERVAL 1 DAY) FROM calendar JOIN bounds b WHERE d < b.month_end
),
biz_calendar AS (
  SELECT c.d
  FROM calendar c
  LEFT JOIN national_holiday h ON h.date = c.d
  WHERE WEEKDAY(c.d) < 5 AND h.date IS NULL
),
dow_map AS (
  SELECT 0 AS wd, 'MON' AS dow UNION ALL
  SELECT 1, 'TUE' UNION ALL SELECT 2, 'WED' UNION ALL
  SELECT 3, 'THU' UNION ALL SELECT 4, 'FRI'
),

tester_ids AS (SELECT 159 AS id),

-- 파견 디테일러 ID (supply_sheet 기준)
dispatch_ids AS (
  SELECT DISTINCT d.id AS detailer_id
  FROM detailer_supply_sheet ss
  JOIN detailer d
    ON REPLACE(d.phone, '-', '') COLLATE utf8mb4_unicode_ci
     = ss.phone_norm COLLATE utf8mb4_unicode_ci
  WHERE ss.status = '파견' AND d.deleted_yn = 0
),

-- (A) rule 디테일러: 파견 제외, 요일별 동적 슬롯 (raw, daily_capacity 미적용)
rule_detailer_day AS (
  SELECT
    bc.d,
    d.id AS detailer_id,
    SUM(
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 8  AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 9  THEN 1 ELSE 0 END) +
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 10 AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 11 THEN 1 ELSE 0 END) +
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 12 AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 13 THEN 1 ELSE 0 END) +
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 14 AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 15 THEN 1 ELSE 0 END) +
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 16 AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 17 THEN 1 ELSE 0 END) +
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 18 AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 19 THEN 1 ELSE 0 END) +
      (CASE WHEN HOUR(CONVERT_TZ(dwsr.start_time, '+00:00', '+09:00')) <= 20 AND HOUR(CONVERT_TZ(dwsr.end_time, '+00:00', '+09:00')) >= 21 THEN 1 ELSE 0 END)
    ) AS raw_slot_count
  FROM biz_calendar bc
  JOIN dow_map dm ON dm.wd = WEEKDAY(bc.d)
  JOIN detailer d
    ON d.booking_yn = 1 AND d.retired_yn = 0 AND d.deleted_yn = 0 AND d.direct_yn = 1
    AND d.id NOT IN (SELECT id FROM tester_ids)
    AND d.id NOT IN (SELECT detailer_id FROM dispatch_ids)
  JOIN detailer_work_schedule dws
    ON dws.detailer_id = d.id
    AND bc.d BETWEEN DATE(CONVERT_TZ(dws.effective_from, '+00:00', '+09:00'))
                 AND DATE(CONVERT_TZ(dws.effective_to, '+00:00', '+09:00'))
  JOIN detailer_work_schedule_rule dwsr
    ON dwsr.schedule_id = dws.id
    AND dwsr.day_of_week = dm.dow
    AND dwsr.deleted_at IS NULL
  GROUP BY bc.d, d.id
  HAVING raw_slot_count > 0
),

-- (B) 파견 디테일러: 매일 5슬롯 고정 (daily_capacity 무관)
dispatch_day AS (
  SELECT bc.d, di.detailer_id, 5 AS slot_count
  FROM biz_calendar bc
  CROSS JOIN dispatch_ids di
),

-- (C) 교육중 미래 입사 예정자
future_starters AS (
  SELECT ss.phone_norm, DATE(ss.work_start_date + INTERVAL 9 HOUR) AS start_d
  FROM detailer_supply_sheet ss
  LEFT JOIN detailer d
    ON REPLACE(d.phone, '-', '') COLLATE utf8mb4_unicode_ci
     = ss.phone_norm COLLATE utf8mb4_unicode_ci
  WHERE ss.status = '교육중'
    AND ss.work_start_date IS NOT NULL
    AND d.id IS NULL
),
future_by_day AS (
  SELECT bc.d, COUNT(*) AS future_cnt
  FROM biz_calendar bc
  JOIN future_starters fs ON fs.start_d <= bc.d
  GROUP BY bc.d
),

-- (A+B) 통합 (source로 daily_capacity 스케일 여부 분기)
all_detailer_day AS (
  SELECT d, detailer_id, raw_slot_count AS slot_count, 'RULE' AS source FROM rule_detailer_day
  UNION ALL
  SELECT d, detailer_id, slot_count, 'DISPATCH' AS source FROM dispatch_day
),

-- Off: 단기(≤7일) full-day holiday → 해당 디테일러 전체 제외
short_fullday_off AS (
  SELECT DISTINCT a.d, a.detailer_id
  FROM all_detailer_day a
  JOIN detailer_holiday dh ON dh.detailer_id = a.detailer_id
    AND CONVERT_TZ(dh.`from`, '+00:00', '+09:00') <= CONCAT(a.d, ' 00:00:00')
    AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') >= CONCAT(DATE_ADD(a.d, INTERVAL 1 DAY), ' 00:00:00')
    AND TIMESTAMPDIFF(DAY, dh.`from`, dh.`to`) <= 7
),

-- 부분 차단: 단기 holiday 중 시간 단위 비활성화 → 겹치는 슬롯만 감소
partial_blocked AS (
  SELECT a.d, a.detailer_id,
    SUM(
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 09:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 08:00:00') THEN 1 ELSE 0 END) +
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 11:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 10:00:00') THEN 1 ELSE 0 END) +
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 13:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 12:00:00') THEN 1 ELSE 0 END) +
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 15:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 14:00:00') THEN 1 ELSE 0 END) +
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 17:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 16:00:00') THEN 1 ELSE 0 END) +
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 19:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 18:00:00') THEN 1 ELSE 0 END) +
      (CASE WHEN CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(a.d, ' 21:00:00') AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 20:00:00') THEN 1 ELSE 0 END)
    ) AS blocked_slots
  FROM all_detailer_day a
  JOIN detailer_holiday dh ON dh.detailer_id = a.detailer_id
    AND CONVERT_TZ(dh.`from`, '+00:00', '+09:00') < CONCAT(DATE_ADD(a.d, INTERVAL 1 DAY), ' 00:00:00')
    AND CONVERT_TZ(dh.`to`, '+00:00', '+09:00') > CONCAT(a.d, ' 00:00:00')
    AND TIMESTAMPDIFF(DAY, dh.`from`, dh.`to`) <= 7
  LEFT JOIN short_fullday_off sfo ON sfo.d = a.d AND sfo.detailer_id = a.detailer_id
  WHERE sfo.detailer_id IS NULL
  GROUP BY a.d, a.detailer_id
),

-- 최종 집계 (RULE만 daily_capacity / 5 스케일, DISPATCH는 고정)
capacity_by_day AS (
  SELECT
    a.d,
    SUM(
      CASE
        WHEN sfo.detailer_id IS NOT NULL THEN 0
        WHEN a.source = 'RULE'
          THEN GREATEST(a.slot_count - COALESCE(pb.blocked_slots, 0), 0) * p.daily_capacity / 5.0
        ELSE GREATEST(a.slot_count - COALESCE(pb.blocked_slots, 0), 0)
      END
    ) + COALESCE(fbd.future_cnt, 0) * p.daily_capacity AS capacity_washes
  FROM all_detailer_day a
  CROSS JOIN params p
  LEFT JOIN short_fullday_off sfo ON sfo.d = a.d AND sfo.detailer_id = a.detailer_id
  LEFT JOIN partial_blocked pb ON pb.d = a.d AND pb.detailer_id = a.detailer_id
  LEFT JOIN future_by_day fbd ON fbd.d = a.d
  GROUP BY a.d, fbd.future_cnt, p.daily_capacity
)

SELECT
  c.d AS date,
  COALESCE(cbd.capacity_washes, 0) AS `이론적 최대 세차량`
FROM calendar c
LEFT JOIN capacity_by_day cbd ON cbd.d = c.d
ORDER BY c.d;
