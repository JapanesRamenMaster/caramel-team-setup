-- 1인당 세차 횟수 (6주 rolling, 주차별)
-- Grafana Bar Chart 패널용
-- 해당 주 세차 완료 수 / 세차 완료한 유니크 유저 수
WITH live_users AS (
  SELECT id FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510','01035474964','01093277016','01091350157',
      '01043446885','01049664316','01050373300','01066943645',
      '01073740979','01092828753','01035420850','01051415705',
      '01091622508','01000000000'
    )
),
washed AS (
  SELECT r.id AS reservation_id, r.user_id,
         DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR) AS kst_dt
  FROM reservation r
  JOIN live_users u ON u.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
    AND DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)
        >= DATE_SUB(
             DATE_SUB(
               DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
               INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
             ),
             INTERVAL 5 WEEK
           )
)
SELECT
  STR_TO_DATE(
    DATE_FORMAT(
      DATE_SUB(DATE(kst_dt), INTERVAL WEEKDAY(kst_dt) DAY),
      '%Y-%m-%d'
    ), '%Y-%m-%d'
  ) AS time,
  ROUND(COUNT(*) / NULLIF(COUNT(DISTINCT user_id), 0), 2) AS '1인당 세차 횟수'
FROM washed
GROUP BY time
ORDER BY time
