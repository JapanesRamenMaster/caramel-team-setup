-- 세차 완료수 — 헤이딜러 (manual_wash_adjustment, 6주 rolling, 주차별)
-- 분자: manual_wash_adjustment.count (헤이딜러 등 외부 운영 합산)
-- Grafana barchart 패널용
SELECT * FROM (
WITH params AS (
    SELECT
        DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR) AS now_kst,
        DATE_SUB(
            DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)) DAY),
            INTERVAL 6 WEEK
        ) AS window_start_kst
)
SELECT
    DATE_SUB(
        DATE(a.wash_date),
        INTERVAL WEEKDAY(DATE(a.wash_date)) DAY
    ) AS time,
    COALESCE(SUM(a.count), 0) AS completed_washes
FROM manual_wash_adjustment a
JOIN params p ON 1=1
WHERE a.wash_date >= DATE(p.window_start_kst)
  AND a.wash_date <= DATE(p.now_kst)
GROUP BY time
ORDER BY time
) cbr_cutoff_wrap
WHERE cbr_cutoff_wrap.`time` < DATE_SUB(
    DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
    INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
)
ORDER BY cbr_cutoff_wrap.`time`
