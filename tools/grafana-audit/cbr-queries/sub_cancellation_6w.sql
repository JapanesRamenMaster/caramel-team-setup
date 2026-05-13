-- 구독 해지 (6주 rolling, 주차별)
-- Grafana Bar Chart 패널용
-- status = 'STOPPED', stopped_at 기준 (UTC → +9H로 KST 변환)
WITH live_users AS (
  SELECT id FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510','01035474964','01093277016','01091350157',
      '01043446885','01049664316','01050373300','01066943645',
      '01073740979','01092828753','01035420850','01051415705',
      '01091622508','01000000000'
    )
)
SELECT
  STR_TO_DATE(
    DATE_FORMAT(
      DATE_SUB(
        DATE(DATE_ADD(s.stopped_at, INTERVAL 9 HOUR)),
        INTERVAL WEEKDAY(DATE_ADD(s.stopped_at, INTERVAL 9 HOUR)) DAY
      ), '%Y-%m-%d'
    ), '%Y-%m-%d'
  ) AS time,
  COUNT(*) AS '구독 해지'
FROM subscription s
JOIN live_users u ON u.id = s.user_id
WHERE s.status = 'STOPPED'
  AND s.stopped_at IS NOT NULL
  AND DATE_ADD(s.stopped_at, INTERVAL 9 HOUR)
      >= DATE_SUB(
           DATE_SUB(
             DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
             INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
           ),
           INTERVAL 5 WEEK
         )
GROUP BY time
ORDER BY time
