-- 세차 완료당 옵션 추가율 (12개월 rolling, 월별)
-- Grafana timeseries 패널용
WITH
  live_users AS (
    SELECT id FROM app_user
    WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
      AND phone NOT IN (
                    '01020866510',
                    '01035474964',
                    '01093277016',
                    '01091350157',
                    '01043446885',
                    '01049664316',
                    '01050373300',
                    '01066943645',
                    '01073740979',
                    '01092828753',
                    '01035420850',
                    '01051415705',
                    '01091622508',
                    '01000000000'
                )
  ),
  washed_reservations AS (
    SELECT r.id AS reservation_id, r.reservation_datetime
    FROM reservation r
    JOIN live_users u ON u.id = r.user_id
    WHERE r.status IN ('WASHED', 'REPORT_SENT')
      AND r.deleted_yn = 0
      AND DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)
          >= DATE_SUB(
               DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
               INTERVAL 12 MONTH
             )
  ),
  res_with_option AS (
    SELECT DISTINCT uo.reservation_id
    FROM user_option uo
    JOIN washed_reservations wr ON wr.reservation_id = uo.reservation_id
    WHERE uo.deleted_yn = 0 AND uo.paid_yn = 1 AND uo.used_yn = 1
  )
SELECT
    CAST(DATE_FORMAT(DATE_ADD(wr.reservation_datetime, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS time,
    ROUND(COUNT(DISTINCT rwo.reservation_id) / COUNT(DISTINCT wr.reservation_id) * 100, 1) AS option_add_rate
FROM washed_reservations wr
LEFT JOIN res_with_option rwo ON rwo.reservation_id = wr.reservation_id
GROUP BY time
ORDER BY time
