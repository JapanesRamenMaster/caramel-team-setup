-- 첫 구매 구독자 비율 (12개월 rolling, 월별)
-- Grafana timeseries 패널용
-- 정의: 그 달에 첫 세차 완료한 unique user 중, 첫 세차 시점에 ACTIVE 구독 보유한 사람 비율 (%)
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
completed_washes AS (
  SELECT r.user_id,
         DATE_ADD(r.washed_at, INTERVAL 9 HOUR) AS washed_kst,
         ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY r.washed_at) AS wash_n
  FROM reservation r
  JOIN live_users lu ON lu.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
),
first_wash AS (
  SELECT cw.user_id,
         cw.washed_kst,
         CAST(DATE_FORMAT(cw.washed_kst, '%Y-%m-01') AS DATE) AS month_start,
         CASE WHEN EXISTS (
           SELECT 1 FROM subscription s
           WHERE s.user_id = cw.user_id
             AND s.status = 'ACTIVE'
             AND s.started_at <= cw.washed_kst
         ) THEN 1 ELSE 0 END AS is_sub
  FROM completed_washes cw
  WHERE cw.wash_n = 1
)
SELECT month_start AS time,
       ROUND(100.0 * SUM(is_sub) / COUNT(*), 1) AS first_purchase_sub_share_pct
FROM first_wash
WHERE month_start >= DATE_SUB(
  DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
           INTERVAL (DAYOFMONTH(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) - 1) DAY),
  INTERVAL 11 MONTH
)
GROUP BY time
ORDER BY time;
