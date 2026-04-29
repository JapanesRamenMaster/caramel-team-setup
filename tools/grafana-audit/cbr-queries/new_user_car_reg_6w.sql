-- 신규 유저 등록 차량수 (6주 rolling, 주차별)
-- 마케팅 input metric: 가입 후 차량을 등록한 신규 유저수
-- car.created_at 기준 (KST)
WITH lu AS (
  SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0
    AND phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000')
),
first_car AS (
  SELECT c.user_id, MIN(DATE_ADD(c.created_at, INTERVAL 9 HOUR)) AS first_car_kst
  FROM car c JOIN lu ON lu.id = c.user_id
  GROUP BY c.user_id
)
SELECT
  DATE_SUB(DATE(first_car_kst), INTERVAL WEEKDAY(DATE(first_car_kst)) DAY) AS time,
  COUNT(*) AS new_user_with_car
FROM first_car
WHERE DATE(first_car_kst) >= DATE_SUB(
  DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
  INTERVAL 6 WEEK
)
GROUP BY time
ORDER BY time
