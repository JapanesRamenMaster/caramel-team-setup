-- 비구독 세차 주기 중간값 (6주 rolling, 주차별)
-- Grafana Bar Chart 패널용
-- 확정 예약 기준, 직전 완료 세차와의 일수 차이 중간값. 예약 시점 활성 구독 유저 제외.
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
  confirmed_reservations AS (
    SELECT r.id AS reservation_id, r.user_id, r.reservation_datetime
    FROM reservation r
    JOIN live_users u ON u.id = r.user_id
    WHERE r.status IN ('CONFIRMED', 'WASHED', 'REPORT_SENT')
      AND r.deleted_yn = 0
      AND NOT EXISTS (
        SELECT 1 FROM subscription s
        WHERE s.user_id = r.user_id
          AND s.status IN ('ACTIVE', 'STOPPED', 'ENDED')
          AND DATE_ADD(s.started_at, INTERVAL 9 HOUR) <= DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)
          AND (
            s.status = 'ACTIVE'
            OR (s.status = 'STOPPED' AND DATE_ADD(s.stopped_at, INTERVAL 9 HOUR) > DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR))
            OR (s.status = 'ENDED' AND s.ended_at > DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR))
          )
      )
      AND DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)
          >= DATE_SUB(
               DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
               INTERVAL 5 WEEK
             )
      AND DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)
          < DATE_ADD(
              DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY),
              INTERVAL 1 WEEK
            )
  ),
  prev_wash AS (
    SELECT cr.reservation_id, cr.reservation_datetime,
           MAX(r2.reservation_datetime) AS prev_wash_datetime
    FROM confirmed_reservations cr
    JOIN reservation r2 ON r2.user_id = cr.user_id
      AND r2.status IN ('WASHED', 'REPORT_SENT')
      AND r2.deleted_yn = 0
      AND r2.reservation_datetime < cr.reservation_datetime
    GROUP BY cr.reservation_id, cr.reservation_datetime
  ),
  gaps AS (
    SELECT pw.reservation_id, pw.reservation_datetime,
           DATEDIFF(
             DATE(DATE_ADD(pw.reservation_datetime, INTERVAL 9 HOUR)),
             DATE(DATE_ADD(pw.prev_wash_datetime, INTERVAL 9 HOUR))
           ) AS gap_days
    FROM prev_wash pw
  ),
  ranked AS (
    SELECT
      STR_TO_DATE(
        DATE_FORMAT(
          DATE_SUB(
            DATE_ADD(g.reservation_datetime, INTERVAL 9 HOUR),
            INTERVAL WEEKDAY(DATE_ADD(g.reservation_datetime, INTERVAL 9 HOUR)) DAY
          ), '%Y-%m-%d'
        ), '%Y-%m-%d'
      ) AS time,
      g.gap_days,
      ROW_NUMBER() OVER (
        PARTITION BY STR_TO_DATE(
          DATE_FORMAT(
            DATE_SUB(
              DATE_ADD(g.reservation_datetime, INTERVAL 9 HOUR),
              INTERVAL WEEKDAY(DATE_ADD(g.reservation_datetime, INTERVAL 9 HOUR)) DAY
            ), '%Y-%m-%d'
          ), '%Y-%m-%d'
        )
        ORDER BY g.gap_days
      ) AS seq,
      COUNT(*) OVER (
        PARTITION BY STR_TO_DATE(
          DATE_FORMAT(
            DATE_SUB(
              DATE_ADD(g.reservation_datetime, INTERVAL 9 HOUR),
              INTERVAL WEEKDAY(DATE_ADD(g.reservation_datetime, INTERVAL 9 HOUR)) DAY
            ), '%Y-%m-%d'
          ), '%Y-%m-%d'
        )
      ) AS cnt
    FROM gaps g
  )
SELECT time,
       ROUND(AVG(gap_days)) AS '비구독 세차 주기 중간값'
FROM ranked
WHERE seq IN (FLOOR((cnt+1)/2), CEIL((cnt+1)/2))
GROUP BY time
ORDER BY time;
