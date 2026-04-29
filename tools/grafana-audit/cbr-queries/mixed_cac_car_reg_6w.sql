-- Mixed CAC: 차량등록 (6주 rolling, 주차별)
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
    INTERVAL 5 WEEK
  )
  GROUP BY bucket
),
first_car AS (
  SELECT
    DATE_SUB(
      DATE(DATE_ADD(first_at, INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(first_at, INTERVAL 9 HOUR))) DAY
    ) AS bucket,
    COUNT(*) AS cnt
  FROM (
    SELECT c.user_id, MIN(c.created_at) AS first_at
    FROM car c
    JOIN live_users lu ON lu.id = c.user_id
    WHERE c.deleted_yn = 0
    GROUP BY c.user_id
    HAVING DATE_ADD(MIN(c.created_at), INTERVAL 9 HOUR) >= DATE_SUB(
      DATE_SUB(
        DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
        INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
      ),
      INTERVAL 5 WEEK
    )
  ) sub
  GROUP BY bucket
)
SELECT
  s.bucket AS time,
  ROUND(s.total_spend / NULLIF(fc.cnt, 0)) AS '차량등록 CAC'
FROM spend_weekly s
LEFT JOIN first_car fc ON fc.bucket = s.bucket
ORDER BY time
