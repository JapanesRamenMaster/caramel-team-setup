-- 세차 완료 구독자 비율 (6주 rolling, 주차별)
-- Grafana barchart 패널용
-- 정의: 그 주에 세차 완료한 unique user 중, 그 시점에 ACTIVE 구독 보유한 사람 비율 (%)
-- 1쿼리 = 1메트릭 원칙 준수
WITH lu AS (
  SELECT id FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510','01035474964','01093277016','01091350157',
      '01043446885','01049664316','01050373300','01066943645',
      '01073740979','01092828753','01035420850','01051415705',
      '01091622508','01000000000'
    )
),
washes AS (
  SELECT DISTINCT r.user_id,
    DATE_SUB(DATE(DATE_ADD(r.washed_at, INTERVAL 9 HOUR)),
             INTERVAL WEEKDAY(DATE(DATE_ADD(r.washed_at, INTERVAL 9 HOUR))) DAY) AS wk,
    DATE_ADD(r.washed_at, INTERVAL 9 HOUR) AS w
  FROM reservation r
  JOIN lu ON lu.id = r.user_id
  WHERE r.status IN ('WASHED','REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
),
weekly_users AS (
  SELECT wk, user_id, MAX(w) AS last_w FROM washes GROUP BY wk, user_id
),
classified AS (
  SELECT wu.wk,
    CASE WHEN EXISTS (
      SELECT 1 FROM subscription s
      WHERE s.user_id = wu.user_id AND s.status = 'ACTIVE' AND s.started_at <= wu.last_w
    ) THEN 1 ELSE 0 END AS is_sub
  FROM weekly_users wu
)
SELECT wk AS time,
       ROUND(100.0 * SUM(is_sub) / COUNT(*), 1) AS '세차 완료 구독자 비율'
FROM classified
WHERE wk >= DATE_SUB(
  DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
           INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
  INTERVAL 6 WEEK
)
GROUP BY wk
ORDER BY time;
