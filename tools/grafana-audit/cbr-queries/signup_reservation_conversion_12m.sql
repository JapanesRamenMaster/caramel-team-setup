-- 가입→예약 전환율 (12m rolling, 월별)
-- Grafana Time Series 패널용: 해당 월에 가입한 유저 중 같은 월에 첫 예약(CONFIRMED+)한 비율
WITH live_users AS (
  SELECT id, DATE_ADD(created_at, INTERVAL 9 HOUR) AS kst_created_at
  FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510','01035474964','01093277016','01091350157',
      '01043446885','01049664316','01050373300','01066943645',
      '01073740979','01092828753','01035420850','01051415705',
      '01091622508','01000000000'
    )
),
signups_monthly AS (
  SELECT id AS user_id,
         CAST(DATE_FORMAT(kst_created_at, '%Y-%m-01') AS DATE) AS month_start
  FROM live_users
  WHERE kst_created_at >= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
    ),
    INTERVAL 51 WEEK
  )
),
first_res AS (
  SELECT r.user_id,
         MIN(DATE_ADD(r.created_at, INTERVAL 9 HOUR)) AS first_res_kst
  FROM reservation r
  JOIN live_users u ON u.id = r.user_id
  WHERE r.deleted_yn = 0
    AND r.status IN ('CONFIRMED','REPORT_SENT','WASHED','IN_PROGRESS','NO_SHOW')
  GROUP BY r.user_id
),
converted AS (
  SELECT s.month_start, s.user_id
  FROM signups_monthly s
  JOIN first_res fr ON fr.user_id = s.user_id
  WHERE CAST(DATE_FORMAT(fr.first_res_kst, '%Y-%m-01') AS DATE) = s.month_start
)
SELECT
  s.month_start AS time,
  ROUND(COUNT(DISTINCT c.user_id) / COUNT(DISTINCT s.user_id) * 100, 1) AS conversion_rate
FROM signups_monthly s
LEFT JOIN converted c ON c.user_id = s.user_id AND c.month_start = s.month_start
GROUP BY s.month_start
ORDER BY s.month_start;
