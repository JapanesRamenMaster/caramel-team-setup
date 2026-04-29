-- 14일 내 재예약율 (12개월 rolling, 월별)
-- 세차 완료 후 14일 내 다음 예약(CONFIRMED/WASHED/REPORT_SENT)을 잡은 유저 비율
-- Grafana timeseries 패널용. time = 세차 완료 월.
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
completed_washes AS (
  SELECT r.id AS reservation_id,
         r.user_id,
         DATE_ADD(r.washed_at, INTERVAL 9 HOUR) AS washed_kst,
         CAST(DATE_FORMAT(DATE_ADD(r.washed_at, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS wash_month
  FROM reservation r
  JOIN live_users lu ON lu.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
),
with_next_booking AS (
  SELECT cw.reservation_id,
         cw.user_id,
         cw.wash_month,
         MIN(DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR)) AS next_booking_kst
  FROM completed_washes cw
  LEFT JOIN reservation r2
    ON r2.user_id = cw.user_id
    AND r2.id != cw.reservation_id
    AND r2.status IN ('CONFIRMED', 'WASHED', 'REPORT_SENT')
    AND r2.deleted_yn = 0
    AND DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR) > cw.washed_kst
    AND DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR) <= DATE_ADD(cw.washed_kst, INTERVAL 14 DAY)
  GROUP BY cw.reservation_id, cw.user_id, cw.wash_month
),
monthly_stats AS (
  SELECT wash_month,
         COUNT(DISTINCT reservation_id) AS total_washes,
         COUNT(DISTINCT CASE WHEN next_booking_kst IS NOT NULL THEN reservation_id END) AS rebooked
  FROM with_next_booking
  WHERE wash_month <= DATE_SUB(
    CAST(DATE_FORMAT(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR), '%Y-%m-01') AS DATE),
    INTERVAL 1 MONTH
  )
  GROUP BY wash_month
)
SELECT
  wash_month AS time,
  ROUND(100.0 * rebooked / NULLIF(total_washes, 0), 1) AS rebooking_rate_14d
FROM monthly_stats
WHERE wash_month >= DATE_SUB(
  DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
  INTERVAL 13 MONTH
)
ORDER BY time
