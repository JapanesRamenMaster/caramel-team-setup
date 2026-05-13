-- 30일 내 재예약율 (6주 rolling, 주차별)
-- 세차 완료 후 30일 내 다음 예약(CONFIRMED/WASHED/REPORT_SENT)을 잡은 유저 비율
-- Output metric: 전사 "고객이 다시 오는가" 지표
-- Grafana barchart 패널용. time = 세차 완료 주차.
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
         DATE_SUB(
           DATE(DATE_ADD(r.washed_at, INTERVAL 9 HOUR)),
           INTERVAL WEEKDAY(DATE(DATE_ADD(r.washed_at, INTERVAL 9 HOUR))) DAY
         ) AS wash_week
  FROM reservation r
  JOIN live_users lu ON lu.id = r.user_id
  WHERE r.status IN ('WASHED', 'REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.washed_at IS NOT NULL
),
with_next_booking AS (
  SELECT cw.reservation_id,
         cw.user_id,
         cw.wash_week,
         MIN(DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR)) AS next_booking_kst
  FROM completed_washes cw
  LEFT JOIN reservation r2
    ON r2.user_id = cw.user_id
    AND r2.id != cw.reservation_id
    AND r2.status IN ('CONFIRMED', 'WASHED', 'REPORT_SENT')
    AND r2.deleted_yn = 0
    AND DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR) > cw.washed_kst
    AND DATE_ADD(r2.reservation_datetime, INTERVAL 9 HOUR) <= DATE_ADD(cw.washed_kst, INTERVAL 30 DAY)
  GROUP BY cw.reservation_id, cw.user_id, cw.wash_week
),
weekly_stats AS (
  SELECT wash_week,
         COUNT(DISTINCT reservation_id) AS total_washes,
         COUNT(DISTINCT CASE WHEN next_booking_kst IS NOT NULL THEN reservation_id END) AS rebooked
  FROM with_next_booking
  WHERE wash_week <= DATE_SUB(
    DATE_SUB(
      DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
      INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
    ),
    INTERVAL 5 WEEK
  )
  GROUP BY wash_week
)
SELECT
  wash_week AS time,
  ROUND(100.0 * rebooked / NULLIF(total_washes, 0), 1) AS rebooking_rate_30d
FROM weekly_stats
WHERE wash_week >= DATE_SUB(
  DATE_SUB(
    DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
    INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
  ),
  INTERVAL 10 WEEK
)
ORDER BY time
