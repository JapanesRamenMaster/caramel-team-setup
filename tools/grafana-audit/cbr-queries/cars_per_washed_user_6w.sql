-- 유저당 등록 차량 수 (6주 rolling, 주차별)
-- Grafana Bar Chart 패널용
-- 해당 주 세차 완료 유저의 평균 등록 차량 수 (car.deleted_yn = 0)
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
washed_users AS (
  SELECT DISTINCT r.user_id,
    STR_TO_DATE(
      DATE_FORMAT(
        DATE_SUB(
          DATE(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)),
          INTERVAL WEEKDAY(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)) DAY
        ), '%Y-%m-%d'
      ), '%Y-%m-%d'
    ) AS week_start
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
),
user_car_count AS (
  SELECT user_id, COUNT(*) AS car_count
  FROM car
  WHERE deleted_yn = 0
  GROUP BY user_id
)
SELECT
  wu.week_start AS time,
  ROUND(AVG(COALESCE(uc.car_count, 0)), 2) AS '유저당 등록 차량 수'
FROM washed_users wu
LEFT JOIN user_car_count uc ON uc.user_id = wu.user_id
GROUP BY wu.week_start
ORDER BY wu.week_start
