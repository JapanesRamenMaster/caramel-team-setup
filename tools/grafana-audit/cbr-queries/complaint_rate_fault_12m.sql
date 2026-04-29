-- Complaint rate — 귀책 (12개월 rolling, 월별)
-- 분자: complaint_log.fault_yn='O' (우리 측 과실 인정 케이스)
-- 분모: 완료 세차 건수 (reservation.washed_at, status IN WASHED/REPORT_SENT, live_user)
-- 본 패널은 "귀책 컴플레인율 = 귀책O 건수 ÷ 세차 완료 × 100" — 전체 컴플레인율과 동일 분모로 비교 가능.
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
fault_monthly AS (
  SELECT
    CAST(DATE_FORMAT(received_date, '%Y-%m-01') AS DATE) AS month_start,
    COUNT(*) AS fault_cnt
  FROM complaint_log
  WHERE fault_yn = 'O'
  GROUP BY month_start
)
SELECT
  w.month_start AS time,
  ROUND(100.0 * IFNULL(f.fault_cnt, 0) / w.wash_cnt, 2) AS complaint_rate_fault
FROM washed_monthly w
LEFT JOIN fault_monthly f ON f.month_start = w.month_start
WHERE w.month_start >= DATE_SUB(
  DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
  INTERVAL 12 MONTH
)
ORDER BY time
