-- 세차 완료수 — 헤이딜러 (manual_wash_adjustment, 12개월 rolling, 월별)
-- Grafana timeseries 패널용
WITH params AS (
    SELECT
        DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR) AS now_kst,
        DATE_SUB(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR), INTERVAL 12 MONTH) AS window_start_kst
)
SELECT
    CAST(CONCAT(DATE_FORMAT(DATE(a.wash_date), '%Y-%m-01'), ' 00:00:00') AS DATETIME) AS time,
    COALESCE(SUM(a.count), 0) AS completed_washes
FROM manual_wash_adjustment a
JOIN params p ON 1=1
WHERE a.wash_date >= DATE(p.window_start_kst)
  AND a.wash_date <= DATE(p.now_kst)
GROUP BY time
ORDER BY time
