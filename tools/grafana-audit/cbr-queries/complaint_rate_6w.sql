-- Complaint rate (6주 rolling, 주차별)
-- 분자: complaint_log (CS 시트 → DB 동기화) 의 received_date 기준 주간 카운트
-- 분모: 완료 세차 건수 (reservation.washed_at, status IN WASHED/REPORT_SENT, live_user)
-- 정의서: "당월 컴플레인율 = 당월 접수 ÷ 당월 세차 완료 건수 × 100"
-- Grafana barchart 패널용.
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
washed_weekly AS (
  SELECT
    DATE_SUB(
      DATE(DATE_ADD(r.washed_at, INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(r.washed_at, INTERVAL 9 HOUR))) DAY
    ) AS week_start,
    COUNT(*) AS wash_cnt
  FROM reservation r
  JOIN live_users lu ON lu.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
    AND r.washed_at >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 8 WEEK)
  GROUP BY week_start
),
complaint_weekly AS (
  SELECT
    DATE_SUB(received_date, INTERVAL WEEKDAY(received_date) DAY) AS week_start,
    COUNT(*) AS complaint_cnt
  FROM complaint_log
  GROUP BY week_start
)
SELECT
  w.week_start AS time,
  ROUND(100.0 * IFNULL(c.complaint_cnt, 0) / w.wash_cnt, 2) AS complaint_rate
FROM washed_weekly w
LEFT JOIN complaint_weekly c ON c.week_start = w.week_start
WHERE w.week_start >= DATE_SUB(
  DATE_SUB(
    DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
    INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
  ),
  INTERVAL 6 WEEK
)
ORDER BY time
