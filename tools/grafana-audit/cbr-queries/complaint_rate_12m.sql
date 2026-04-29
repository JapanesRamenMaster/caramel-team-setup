-- Complaint rate (12개월 rolling, 월별)
-- 분자: complaint_log (CS 시트 → DB 동기화) 의 received_date 기준 월간 카운트
-- 분모: 완료 세차 건수 (reservation.washed_at, status IN WASHED/REPORT_SENT, live_user)
-- 정의서: "당월 컴플레인율 = 당월 접수 ÷ 당월 세차 완료 건수 × 100"
-- Grafana timeseries 패널용.
WITH live_users AS (
  SELECT id FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510', '01035474964', '01093277016', '01091350157',
      '01043446885', '01049664316', '01050373300', '01066943645',
      '01073740979', '01092828753', '01035420850', '01051415705',
      '01091622508', '01000000000'
    )
),
washed_monthly AS (
  SELECT
    CAST(DATE_FORMAT(DATE_ADD(r.washed_at, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS month_start,
    COUNT(*) AS wash_cnt
  FROM reservation r
  JOIN live_users lu ON lu.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
    AND r.washed_at >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 13 MONTH)
  GROUP BY month_start
),
complaint_monthly AS (
  SELECT
    CAST(DATE_FORMAT(received_date, '%Y-%m-01') AS DATE) AS month_start,
    COUNT(*) AS complaint_cnt
  FROM complaint_log
  GROUP BY month_start
)
SELECT
  w.month_start AS time,
  ROUND(100.0 * IFNULL(c.complaint_cnt, 0) / w.wash_cnt, 2) AS complaint_rate
FROM washed_monthly w
LEFT JOIN complaint_monthly c ON c.month_start = w.month_start
WHERE w.month_start >= DATE_SUB(
  DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
  INTERVAL 12 MONTH
)
ORDER BY time
