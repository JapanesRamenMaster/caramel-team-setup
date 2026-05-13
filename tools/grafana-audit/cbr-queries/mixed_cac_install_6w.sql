-- Mixed CAC_설치 기준 (6주 rolling, 주차별)
-- Grafana barchart 패널용
-- 분자: Meta + Naver 광고비 (KRW)
-- 분모: airbridge_daily_install.install_users (Airbridge가 잡는 모든 채널 install — paid + organic 합산, unique user)
WITH spend_base AS (
  SELECT DATE(date) AS dt, total_spending AS spend FROM meta_daily_performance
  UNION ALL
  SELECT DATE(date) AS dt, total_cost AS spend FROM naver_daily_performance
),
spend_weekly AS (
  SELECT
    DATE_SUB(dt, INTERVAL WEEKDAY(dt) DAY) AS bucket,
    SUM(spend) AS total_spend
  FROM spend_base
  WHERE dt >= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
    ),
    INTERVAL 6 WEEK
  )
  GROUP BY bucket
),
install_weekly AS (
  SELECT
    DATE_SUB(event_date, INTERVAL WEEKDAY(event_date) DAY) AS bucket,
    SUM(install_users) AS installs
  FROM airbridge_daily_install
  WHERE event_date >= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
    ),
    INTERVAL 6 WEEK
  )
  GROUP BY bucket
)
SELECT
  s.bucket AS time,
  ROUND(s.total_spend / NULLIF(iw.installs, 0)) AS '설치 CAC'
FROM spend_weekly s
LEFT JOIN install_weekly iw ON iw.bucket = s.bucket
ORDER BY time;
