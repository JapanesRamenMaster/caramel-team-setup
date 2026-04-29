-- 총 광고 금액 (6주 rolling, 주차별)
-- Grafana Barchart 패널용
WITH spend_base AS (
  SELECT DATE(date) AS dt, total_spending AS spend FROM meta_daily_performance
  UNION ALL
  SELECT DATE(date) AS dt, total_cost AS spend FROM naver_daily_performance
),
weekly AS (
  SELECT
    DATE_SUB(dt, INTERVAL WEEKDAY(dt) DAY) AS bucket,
    SUM(spend) AS total_spend
  FROM spend_base
  WHERE dt >= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
    ),
    INTERVAL 5 WEEK
  )
  GROUP BY bucket
)
SELECT
  bucket,
  total_spend AS ad_spend
FROM weekly
ORDER BY bucket
