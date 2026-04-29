-- 가동률 (12개월 rolling, 월별)
-- 완료 세차수 / (스케줄된 디테일러일 × 5슬롯) × 100
-- 분모는 detailer_work_schedule + detailer_work_schedule_rule 기반 정확한 capacity
-- 현재 진행 중인 월도 포함 (partial month visible)
-- Grafana timeseries 패널용
WITH RECURSIVE date_seq AS (
  SELECT DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 12 MONTH) AS d
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
monthly_capacity AS (
  SELECT
    CAST(DATE_FORMAT(work_day, '%Y-%m-01') AS DATE) AS m,
    COUNT(*) AS scheduled_pairs
  FROM detailer_scheduled_days
  GROUP BY m
),
monthly_washes AS (
  SELECT
    CAST(DATE_FORMAT(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS m,
    COUNT(*) AS wash_count
  FROM reservation r
  JOIN detailer d ON d.id = r.detailer_id
    AND d.booking_yn = 1 AND d.retired_yn = 0 AND d.deleted_yn = 0 AND d.direct_yn = 1
    AND d.name != '이상민' AND d.id != 159
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
  GROUP BY m
)
SELECT
  c.m AS time,
  ROUND(100.0 * COALESCE(w.wash_count, 0) / NULLIF(c.scheduled_pairs * 5, 0), 1) AS utilization_pct
FROM monthly_capacity c
LEFT JOIN monthly_washes w ON w.m = c.m
WHERE c.m >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 12 MONTH)
ORDER BY time
