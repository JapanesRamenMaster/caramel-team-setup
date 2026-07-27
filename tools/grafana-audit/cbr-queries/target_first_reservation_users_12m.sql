WITH live_users AS (SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0 AND (phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000') OR phone IS NULL)),
target_users AS (SELECT DISTINCT c.user_id FROM car c JOIN car_model_target cmt ON cmt.id=c.model_id WHERE c.deleted_yn=0 AND cmt.is_target=1),
valid_reservations AS (
  SELECT r.user_id, DATE_ADD(r.created_at, INTERVAL 9 HOUR) AS kst_created_at
  FROM reservation r
  JOIN live_users lu ON lu.id=r.user_id
  JOIN target_users tu ON tu.user_id=r.user_id
  WHERE r.deleted_yn=0 AND r.status IN ('CONFIRMED','REPORT_SENT','WASHED','IN_PROGRESS','NO_SHOW')
),
first_request AS (SELECT user_id, MIN(kst_created_at) AS first_kst FROM valid_reservations GROUP BY user_id)
SELECT CAST(DATE_FORMAT(first_kst,'%Y-%m-01') AS DATE) AS time, COUNT(*) AS target_first_reservation_users
FROM first_request
WHERE first_kst >= DATE_SUB(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR), INTERVAL 12 MONTH)
GROUP BY time ORDER BY time
