-- 가동률 (6주 rolling, 주차별)
-- 완료 세차수 / (스케줄된 디테일러일 × 5슬롯) × 100
-- 분모는 detailer_work_schedule + detailer_work_schedule_rule 기반 정확한 capacity
-- Grafana barchart 패널용
WITH RECURSIVE date_seq AS (
  SELECT DATE_SUB(
    DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
    INTERVAL 6 WEEK
  ) AS d
  UNION ALL
  SELECT DATE_ADD(d, INTERVAL 1 DAY) FROM date_seq
  WHERE d < DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))
),
business_days AS (
  SELECT d FROM date_seq WHERE WEEKDAY(d) < 5
),
detailer_scheduled_days AS (
  SELECT DISTINCT
    dws.detailer_id,
    bd.d AS work_day
  FROM business_days bd
  JOIN detailer_work_schedule dws
    ON bd.d BETWEEN DATE(CONVERT_TZ(dws.effective_from, '+00:00', '+09:00'))
                 AND DATE(CONVERT_TZ(dws.effective_to, '+00:00', '+09:00'))
  JOIN detailer_work_schedule_rule dwsr ON dwsr.schedule_id = dws.id
    AND dwsr.deleted_at IS NULL
    AND dwsr.day_of_week = ELT(WEEKDAY(bd.d) + 1, 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN')
  JOIN detailer d ON d.id = dws.detailer_id
    AND d.booking_yn = 1 AND d.retired_yn = 0 AND d.deleted_yn = 0 AND d.direct_yn = 1
    AND d.name != '이상민' AND d.id != 159
),
weekly_capacity AS (
  SELECT
    DATE_SUB(work_day, INTERVAL WEEKDAY(work_day) DAY) AS wk,
    COUNT(*) AS scheduled_pairs
  FROM detailer_scheduled_days
  GROUP BY wk
),
weekly_washes AS (
  SELECT
    DATE_SUB(
      DATE(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR))) DAY
    ) AS wk,
    COUNT(*) AS wash_count
  FROM reservation r
  JOIN detailer d ON d.id = r.detailer_id
    AND d.booking_yn = 1 AND d.retired_yn = 0 AND d.deleted_yn = 0 AND d.direct_yn = 1
    AND d.name != '이상민' AND d.id != 159
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
  GROUP BY wk
)
SELECT
  c.wk AS time,
  ROUND(100.0 * COALESCE(w.wash_count, 0) / NULLIF(c.scheduled_pairs * 5, 0), 1) AS utilization_pct
FROM weekly_capacity c
LEFT JOIN weekly_washes w ON w.wk = c.wk
WHERE c.wk >= DATE_SUB(
  DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
  INTERVAL 6 WEEK
)
ORDER BY time
