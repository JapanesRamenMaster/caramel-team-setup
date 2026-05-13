-- 총 광고 금액 (12개월 rolling, 월간)
-- Grafana Time Series 패널용
WITH spend_base AS (
  SELECT DATE(date) AS dt, total_spending AS spend FROM meta_daily_performance
  UNION ALL
  SELECT DATE(date) AS dt, total_cost AS spend FROM naver_daily_performance
),
monthly AS (
  SELECT
    DATE_FORMAT(dt, '%Y-%m-01') AS bucket,
    SUM(spend) AS total_spend
  FROM spend_base
  WHERE dt >= DATE_SUB(
    DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
    INTERVAL 12 MONTH
  )
  GROUP BY bucket
)
SELECT
  DATE(bucket) AS bucket,
  total_spend AS ad_spend
FROM monthly
ORDER BY bucket
