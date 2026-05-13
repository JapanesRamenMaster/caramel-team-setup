INSERT INTO cbr_cohort_repurchase_snapshot (cohort_week, acq_segment, cohort_size, repurchased_within_90d)
WITH live_users AS (
  SELECT id, utm_source FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510','01035474964','01093277016','01091350157',
      '01043446885','01049664316','01050373300','01066943645',
      '01073740979','01092828753','01035420850','01051415705',
      '01091622508','01000000000'
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
  WHERE r.status IN ('WASHED','REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
),
first_wash AS (
  SELECT cw.user_id,
    cw.washed_kst AS first_washed_kst,
    DATE_SUB(DATE(cw.washed_kst), INTERVAL WEEKDAY(DATE(cw.washed_kst)) DAY) AS cohort_week,
    us.acq_segment,
    CASE WHEN EXISTS (
      SELECT 1 FROM subscription s
      WHERE s.user_id = cw.user_id AND s.status='ACTIVE' AND s.started_at <= cw.washed_kst
    ) THEN 'sub' ELSE 'onetime' END AS purchase_type
  FROM completed_washes cw
  JOIN user_segment us ON us.id = cw.user_id
  WHERE cw.wash_n = 1
),
second_wash AS (
  SELECT user_id, washed_kst AS second_washed_kst
  FROM completed_washes WHERE wash_n = 2
),
cohort_full AS (
  SELECT
    fw.cohort_week,
    fw.acq_segment,
    fw.purchase_type,
    fw.user_id,
    CASE WHEN sw.second_washed_kst IS NOT NULL
              AND DATEDIFF(sw.second_washed_kst, fw.first_washed_kst) <= 90
         THEN 1 ELSE 0 END AS repurchased
  FROM first_wash fw
  LEFT JOIN second_wash sw ON sw.user_id = fw.user_id
)
SELECT cohort_week, 'all' AS acq_segment, COUNT(*) AS cohort_size, SUM(repurchased) AS repurchased_within_90d
FROM cohort_full GROUP BY cohort_week
UNION ALL
SELECT cohort_week, acq_segment, COUNT(*), SUM(repurchased) FROM cohort_full
WHERE acq_segment IN ('toss','free_other')
GROUP BY cohort_week, acq_segment
UNION ALL
SELECT cohort_week,
  CASE WHEN purchase_type='sub' THEN 'paid_subscription' ELSE 'paid_onetime' END AS acq_segment,
  COUNT(*), SUM(repurchased)
FROM cohort_full
WHERE acq_segment = 'paid'
GROUP BY cohort_week, purchase_type
ON DUPLICATE KEY UPDATE
  cohort_size = VALUES(cohort_size),
  repurchased_within_90d = VALUES(repurchased_within_90d);
