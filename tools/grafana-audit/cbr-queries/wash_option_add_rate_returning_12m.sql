-- 재구매 옵션 추가율 (12개월 rolling, 월별)
-- Grafana Time Series 패널용
-- 재구매 = 해당 예약이 유저의 첫 번째 완료 세차가 아닌 건
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
    SELECT r.id AS reservation_id, r.user_id, r.reservation_datetime
    FROM reservation r
    JOIN live_users u ON u.id = r.user_id
    WHERE r.status IN ('WASHED', 'REPORT_SENT')
      AND r.deleted_yn = 0
      AND DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)
          >= DATE_SUB(
               DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
               INTERVAL 51 WEEK
             )
  ),
  first_wash AS (
    SELECT r.user_id, MIN(r.id) AS first_reservation_id
    FROM reservation r
    JOIN live_users u ON u.id = r.user_id
    WHERE r.status IN ('WASHED', 'REPORT_SENT')
      AND r.deleted_yn = 0
    GROUP BY r.user_id
  ),
  res_with_option AS (
    SELECT DISTINCT uo.reservation_id
    FROM user_option uo
    JOIN washed_reservations wr ON wr.reservation_id = uo.reservation_id
    WHERE uo.deleted_yn = 0 AND uo.paid_yn = 1 AND uo.used_yn = 1
  )
SELECT
    CAST(DATE_FORMAT(DATE_ADD(wr.reservation_datetime, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS time,
    ROUND(
      COUNT(DISTINCT rwo.reservation_id)
      / NULLIF(COUNT(DISTINCT wr.reservation_id), 0) * 100, 1
    ) AS '재구매 옵션 추가율'
FROM washed_reservations wr
JOIN first_wash fw ON fw.user_id = wr.user_id
LEFT JOIN res_with_option rwo ON rwo.reservation_id = wr.reservation_id
WHERE fw.first_reservation_id != wr.reservation_id
GROUP BY time
ORDER BY time;
