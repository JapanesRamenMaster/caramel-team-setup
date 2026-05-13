-- 3개월 재구매율: 토스 (12개월 rolling, 월별)
-- Grafana Time Series 패널용. time = 코호트월 (첫 세차 시점). 90일 관찰 확정 코호트만 표시..
WITH live_users AS (
  SELECT id, utm_source FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510', '01035474964', '01093277016', '01091350157',
      '01043446885', '01049664316', '01050373300', '01066943645',
      '01073740979', '01092828753', '01035420850', '01051415705',
      '01091622508', '01000000000'
    )
),
user_segment AS (
  SELECT lu.id,
    CASE
      WHEN lu.utm_source = 'toss_promotion' THEN 'toss'
      WHEN lu.id NOT IN (SELECT user_id FROM user_utm_triage) THEN 'free_other'
      ELSE 'paid'
    END AS acq_segment
  FROM live_users lu
),
completed_washes AS (
  SELECT r.user_id,
         DATE_ADD(r.washed_at, INTERVAL 9 HOUR) AS washed_kst,
         ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY r.washed_at) AS wash_n
  FROM reservation r
  JOIN user_segment us ON us.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT') AND r.deleted_yn = 0 AND r.washed_at IS NOT NULL
),
first_wash AS (
  SELECT cw.user_id,
         cw.washed_kst AS first_washed_kst,
         DATE_FORMAT(cw.washed_kst, '%Y-%m-01') AS cohort_month,
         us.acq_segment,
         CASE WHEN EXISTS (
           SELECT 1 FROM subscription s
           WHERE s.user_id = cw.user_id AND s.status = 'ACTIVE' AND s.started_at <= cw.washed_kst
         ) THEN 'sub' ELSE 'onetime' END AS purchase_type
  FROM completed_washes cw
  JOIN user_segment us ON us.id = cw.user_id
  WHERE cw.wash_n = 1
),
second_wash AS (
  SELECT user_id, washed_kst AS second_washed_kst
  FROM completed_washes WHERE wash_n = 2
),
cohort_stats AS (
  SELECT fw.cohort_month,
         COUNT(*) AS cohort_size,
         SUM(CASE WHEN sw.second_washed_kst IS NOT NULL
                   AND DATEDIFF(sw.second_washed_kst, fw.first_washed_kst) <= 90
                  THEN 1 ELSE 0 END) AS repurchased
  FROM first_wash fw
  LEFT JOIN second_wash sw ON sw.user_id = fw.user_id
  WHERE fw.acq_segment = 'toss'
  GROUP BY fw.cohort_month
  HAVING DATE_ADD(DATE(cohort_month), INTERVAL 3 MONTH) <= DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))
)
SELECT
  DATE(cohort_month) AS time,
  ROUND(100.0 * repurchased / NULLIF(cohort_size, 0), 1) AS repurchase_rate
FROM cohort_stats
WHERE DATE(cohort_month) >= DATE_SUB(
  DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
  INTERVAL 15 MONTH
)
ORDER BY time
