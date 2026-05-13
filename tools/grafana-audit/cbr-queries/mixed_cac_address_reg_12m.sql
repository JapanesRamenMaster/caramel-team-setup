-- Mixed CAC: 주소등록 (12개월 rolling, 월별)
-- Grafana Time Series 패널용
WITH live_users AS (
  SELECT id FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510', '01035474964', '01093277016', '01091350157',
      '01043446885', '01049664316', '01050373300', '01066943645',
      '01073740979', '01092828753', '01035420850', '01051415705',
      '01091622508', '01000000000'
    )
),
spend_base AS (
  SELECT DATE(date) AS dt, total_spending AS spend FROM meta_daily_performance
  UNION ALL
  SELECT DATE(date) AS dt, total_cost AS spend FROM naver_daily_performance
),
spend_monthly AS (
  SELECT
    CAST(DATE_FORMAT(dt, '%Y-%m-01') AS DATE) AS bucket,
    SUM(spend) AS total_spend
  FROM spend_base
  WHERE dt >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 12 MONTH)
  GROUP BY bucket
),
first_address AS (
  SELECT
    CAST(DATE_FORMAT(DATE(DATE_ADD(first_at, INTERVAL 9 HOUR)), '%Y-%m-01') AS DATE) AS bucket,
    COUNT(*) AS cnt
  FROM (
    SELECT ua.user_id, MIN(ua.created_at) AS first_at
    FROM user_address ua
    JOIN live_users lu ON lu.id = ua.user_id
    WHERE IFNULL(ua.deleted_yn, 0) = 0
    GROUP BY ua.user_id
    HAVING DATE_ADD(MIN(ua.created_at), INTERVAL 9 HOUR) >= DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL 12 MONTH
    )
  ) sub
  GROUP BY bucket
)
SELECT
  s.bucket AS time,
  ROUND(s.total_spend / NULLIF(fa.cnt, 0)) AS '주소등록 CAC'
FROM spend_monthly s
LEFT JOIN first_address fa ON fa.bucket = s.bucket
ORDER BY time
