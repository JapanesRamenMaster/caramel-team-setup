-- 구독자 비중 (12개월, 월별)
WITH lu AS (
  SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0
    AND phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000')
),
washes AS (
  SELECT DISTINCT r.user_id,
    CAST(DATE_FORMAT(DATE_ADD(r.washed_at, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS m,
    DATE_ADD(r.washed_at, INTERVAL 9 HOUR) AS w
  FROM reservation r JOIN lu ON lu.id=r.user_id
  WHERE r.status IN ('WASHED','REPORT_SENT') AND r.deleted_yn=0 AND r.washed_at IS NOT NULL
),
monthly_users AS (
  SELECT m, user_id, MAX(w) AS last_w FROM washes GROUP BY m, user_id
),
classified AS (
  SELECT mu.m,
    CASE WHEN EXISTS(SELECT 1 FROM subscription s WHERE s.user_id=mu.user_id AND s.status='ACTIVE' AND s.started_at <= mu.last_w)
         THEN 'subscriber' ELSE 'non_subscriber' END AS seg
  FROM monthly_users mu
)
SELECT m AS time,
  ROUND(100.0 * SUM(CASE WHEN seg='subscriber' THEN 1 ELSE 0 END) / COUNT(*), 1) AS subscriber_share_pct,
  ROUND(100.0 * SUM(CASE WHEN seg='non_subscriber' THEN 1 ELSE 0 END) / COUNT(*), 1) AS non_subscriber_share_pct
FROM classified
WHERE m >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 12 MONTH)
GROUP BY m
ORDER BY time
