-- 30일 재예약율: 구독자 vs 비구독자 (12개월, 월별)
WITH lu AS (
  SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0
    AND phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000')
),
washes AS (
  SELECT r.id AS rid, r.user_id, DATE_ADD(r.washed_at, INTERVAL 9 HOUR) AS w,
    CAST(DATE_FORMAT(DATE_ADD(r.washed_at, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS m
  FROM reservation r JOIN lu ON lu.id=r.user_id
  WHERE r.status IN ('WASHED','REPORT_SENT') AND r.deleted_yn=0 AND r.washed_at IS NOT NULL
),
classified AS (
  SELECT w.rid, w.user_id, w.w, w.m,
    CASE WHEN EXISTS(SELECT 1 FROM subscription s WHERE s.user_id=w.user_id AND s.status='ACTIVE' AND s.started_at <= w.w)
         THEN 'subscriber' ELSE 'non_subscriber' END AS seg,
    EXISTS(SELECT 1 FROM reservation r2
           WHERE r2.user_id=w.user_id AND r2.id!=w.rid
             AND r2.status IN ('CONFIRMED','WASHED','REPORT_SENT') AND r2.deleted_yn=0
             AND DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR) > w.w
             AND DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR) <= DATE_ADD(w.w, INTERVAL 30 DAY)
    ) AS has_next
  FROM washes w
)
SELECT m AS time, seg AS segment,
  ROUND(100.0 * SUM(CASE WHEN has_next THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0), 1) AS rebook_30d_pct
FROM classified
WHERE m >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 13 MONTH)
  AND m <= DATE_SUB(CAST(DATE_FORMAT(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR), '%Y-%m-01') AS DATE), INTERVAL 1 MONTH)
GROUP BY m, seg
ORDER BY time, segment
