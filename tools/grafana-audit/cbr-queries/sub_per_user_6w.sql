-- 1인당 구독 개수 (6주 rolling, 주차별)
-- Grafana Bar Chart 패널용
-- 각 주 시점에 활성이었던 구독 수를 역산하여 유저당 평균 계산
-- ended_at은 구독 만료 예정일 (KST), stopped_at은 해지 시점 (UTC)
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
week_series AS (
  SELECT DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
    ),
    INTERVAL n WEEK
  ) AS week_start
  FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) nums
),
active_at_week AS (
  SELECT ws.week_start, s.user_id, s.id AS sub_id
  FROM week_series ws
  CROSS JOIN subscription s
  JOIN live_users u ON u.id = s.user_id
  WHERE s.status IN ('ACTIVE', 'STOPPED', 'ENDED')
    AND DATE(DATE_ADD(s.started_at, INTERVAL 9 HOUR)) <= DATE_ADD(ws.week_start, INTERVAL 6 DAY)
    AND (
      s.status = 'ACTIVE'
      OR (s.status = 'STOPPED' AND DATE(DATE_ADD(s.stopped_at, INTERVAL 9 HOUR)) > ws.week_start)
      OR (s.status = 'ENDED' AND DATE(s.ended_at) > ws.week_start)
    )
)
SELECT
  week_start AS time,
  ROUND(COUNT(*) / NULLIF(COUNT(DISTINCT user_id), 0), 2) AS '1인당 구독 개수'
FROM active_at_week
GROUP BY week_start
ORDER BY week_start
