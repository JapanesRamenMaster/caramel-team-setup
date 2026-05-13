-- Mixed CAC_설치 기준 (12개월 rolling, 월별)
-- Grafana timeseries 패널용
WITH spend_base AS (
  SELECT DATE(date) AS dt, total_spending AS spend FROM meta_daily_performance
  UNION ALL
  SELECT DATE(date) AS dt, total_cost AS spend FROM naver_daily_performance
),
spend_monthly AS (
  SELECT
    CAST(DATE_FORMAT(dt, '%Y-%m-01') AS DATE) AS bucket,
    SUM(spend) AS total_spend
  FROM spend_base
  WHERE dt >= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL (DAYOFMONTH(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) - 1) DAY
    ),
    INTERVAL 11 MONTH
  )
  GROUP BY bucket
),
install_monthly AS (
  SELECT
    CAST(DATE_FORMAT(event_date, '%Y-%m-01') AS DATE) AS bucket,
    SUM(install_users) AS installs
  FROM airbridge_daily_install
  WHERE event_date >= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL (DAYOFMONTH(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) - 1) DAY
    ),
    INTERVAL 11 MONTH
  )
  GROUP BY bucket
)
SELECT
  s.bucket AS time,
  ROUND(s.total_spend / NULLIF(iw.installs, 0)) AS '설치 CAC'
FROM spend_monthly s
LEFT JOIN install_monthly iw ON iw.bucket = s.bucket
ORDER BY time;
