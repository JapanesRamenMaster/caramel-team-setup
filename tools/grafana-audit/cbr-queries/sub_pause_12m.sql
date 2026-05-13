-- 구독 일시정지 (12개월 rolling, 주차별)
-- Grafana Time Series 패널용
-- paused_at 기준 (이미 KST 저장 — +9H 하지 않음)
-- 일시정지 후 해지된 건도 포함 (paused_at IS NOT NULL인 모든 구독)
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
        DATE(s.paused_at),
        INTERVAL WEEKDAY(s.paused_at) DAY
      ), '%Y-%m-%d'
    ), '%Y-%m-%d'
  ) AS time,
  COUNT(*) AS '구독 일시정지'
FROM subscription s
JOIN live_users u ON u.id = s.user_id
WHERE s.paused_at IS NOT NULL
  AND s.status IN ('ACTIVE', 'STOPPED')
  AND s.paused_at
      >= DATE_SUB(
           DATE_SUB(
             DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
             INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
           ),
           INTERVAL 51 WEEK
         )
GROUP BY time
ORDER BY time
