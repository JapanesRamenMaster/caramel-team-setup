-- =============================================================
-- 일별 이론적 최대 세차량 (Capacity) 쿼리
--
-- 변경 이력:
--   2026-04-05 - work_schedule + supply_sheet 3-way JOIN으로 변경
--              - 기존: supply_sheet CROSS JOIN (과대 카운트 문제)
--              - 변경: work_schedule 기반 active + supply_sheet status 필터
--              - v_detailer_holiday_daily 뷰도 수정 (퇴사 필터 제거, 비활/퇴사 off_factor 추가)
--              - 교육중 미래 입사자 반영 (future_starters CTE)
--
-- 사용법:
--   ${daily_capacity} → 디테일러 1인당 하루 세차 가능 수 (기본 5)
--   ${sim_month}      → 시뮬레이션 대상 월 시작일 (예: '2026-04-01')
--
-- active_cnt 구성:
--   (A) work_schedule 있는 현직/파견/교육중 디테일러 (schedule_cnt)
--   (B) detailer 테이블 미등록 교육중 입사 예정자 (future_cnt)
--       → work_start_date 이후 biz_calendar 날짜부터 카운트
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

-- (A) supply_sheet active + detailer 테이블 매칭된 디테일러
-- detailer.retired_yn은 관리 안 되므로 supply_sheet status가 source of truth
active_detailers AS (
  SELECT DISTINCT d.id AS detailer_id
  FROM detailer_supply_sheet ss
  JOIN detailer d
    ON REPLACE(d.phone, '-', '') COLLATE utf8mb4_unicode_ci
     = ss.phone_norm COLLATE utf8mb4_unicode_ci
  WHERE ss.status IN ('현직', '파견', '교육중')
    AND d.deleted_yn = 0
),

-- (B) 교육중이지만 detailer 테이블 미등록 → work_start_date 이후부터 카운트
future_starters AS (
  SELECT
    ss.phone_norm,
    DATE(ss.work_start_date + INTERVAL 9 HOUR) AS start_d
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

-- 휴가/비활성화 off (active_detailers에 해당하는 사람만)
off_by_day AS (
  SELECT vd.d, SUM(vd.off_factor) AS off_sum
  FROM v_detailer_holiday_daily vd
  JOIN active_detailers ad ON ad.detailer_id = vd.detailer_id
  GROUP BY vd.d
),

-- work_schedule 기반 active 카운트
active_by_day AS (
  SELECT
    bc.d,
    COUNT(DISTINCT dws.detailer_id) AS schedule_cnt
  FROM biz_calendar bc
  JOIN detailer_work_schedule dws
    ON bc.d BETWEEN DATE(CONVERT_TZ(dws.effective_from, '+00:00', '+09:00'))
                 AND DATE(CONVERT_TZ(dws.effective_to, '+00:00', '+09:00'))
  JOIN active_detailers ad ON ad.detailer_id = dws.detailer_id
  GROUP BY bc.d
),

capacity_by_day AS (
  SELECT
    abd.d,
    abd.schedule_cnt + COALESCE(fbd.future_cnt, 0) AS active_cnt,
    COALESCE(obd.off_sum, 0) AS off_sum,
    GREATEST(
      abd.schedule_cnt + COALESCE(fbd.future_cnt, 0) - COALESCE(obd.off_sum, 0),
      0
    ) * bs.daily_capacity AS capacity_washes
  FROM active_by_day abd
  LEFT JOIN future_by_day fbd ON fbd.d = abd.d
  LEFT JOIN off_by_day obd ON obd.d = abd.d
  CROSS JOIN bounds bs
)

SELECT
  c.d AS date,
  COALESCE(cbd.capacity_washes, 0) AS `이론적 최대 세차량`
FROM calendar c
LEFT JOIN capacity_by_day cbd ON cbd.d = c.d
ORDER BY c.d;
