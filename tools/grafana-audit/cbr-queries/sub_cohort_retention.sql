-- 구독 코호트별 누적 잔존율
-- 시작 월 코호트별로 1/2/3개월 후 잔존율을 보여줌
-- 결과: 시작월, 코호트크기, 1개월잔존, 2개월잔존, 3개월잔존
WITH sub_started AS (
  SELECT s.user_id, s.id AS sub_id,
    CAST(DATE_FORMAT(DATE_ADD(s.started_at, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS cohort_month,
    DATE_ADD(s.started_at, INTERVAL 9 HOUR) AS started_kst,
    s.status,
    DATE_ADD(s.stopped_at, INTERVAL 9 HOUR) AS stopped_kst,
    s.ended_at AS ended_kst
  FROM subscription s
  WHERE s.started_at IS NOT NULL
    AND DATE_ADD(s.started_at, INTERVAL 9 HOUR) >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 12 MONTH)
),
churn_event AS (
  SELECT user_id, sub_id, cohort_month, started_kst,
    CASE
      WHEN status='STOPPED' THEN stopped_kst
      WHEN status='ENDED' THEN ended_kst
      ELSE NULL
    END AS churn_kst
  FROM sub_started
)
SELECT cohort_month AS time,
  COUNT(*) AS cohort_size,
  ROUND(100.0 * SUM(CASE WHEN churn_kst IS NULL OR DATEDIFF(churn_kst, started_kst) > 30 THEN 1 ELSE 0 END) / COUNT(*), 1) AS retained_30d_pct,
  ROUND(100.0 * SUM(CASE WHEN churn_kst IS NULL OR DATEDIFF(churn_kst, started_kst) > 60 THEN 1 ELSE 0 END) / COUNT(*), 1) AS retained_60d_pct,
  ROUND(100.0 * SUM(CASE WHEN churn_kst IS NULL OR DATEDIFF(churn_kst, started_kst) > 90 THEN 1 ELSE 0 END) / COUNT(*), 1) AS retained_90d_pct
FROM churn_event
WHERE DATE_ADD(cohort_month, INTERVAL 30 DAY) <= DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))
GROUP BY cohort_month
ORDER BY time
