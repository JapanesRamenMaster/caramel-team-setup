-- 세차 완료수 — 직접 운영 (헤이딜러 제외, 6주 rolling, 주차별)
-- reservation 테이블 기준 (live_user, status IN WASHED/REPORT_SENT)
-- Grafana barchart 패널용
SELECT * FROM (
WITH params AS (
    SELECT
        DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR) AS now_kst,
        DATE_SUB(
            DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)) DAY),
            INTERVAL 6 WEEK
        ) AS window_start_kst
),
live_user AS (
    SELECT u.id
    FROM app_user u
    WHERE u.deleted_yn = 0 AND u.test_yn = 0 AND u.temp_yn = 0
      AND u.phone NOT IN (
        '01020866510','01035474964','01093277016','01091350157',
        '01043446885','01049664316','01050373300','01066943645',
        '01073740979','01092828753','01035420850','01051415705',
        '01091622508','01000000000'
      )
)
SELECT
    DATE_SUB(
        DATE(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)),
        INTERVAL WEEKDAY(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)) DAY
    ) AS time,
    COUNT(*) AS completed_washes
FROM reservation r
JOIN live_user lu ON r.user_id = lu.id
JOIN params p ON 1=1
WHERE r.status IN ('WASHED', 'REPORT_SENT')
  AND DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR) >= p.window_start_kst
GROUP BY time
ORDER BY time
) cbr_cutoff_wrap
WHERE cbr_cutoff_wrap.`time` < DATE_SUB(
    DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
    INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY
)
ORDER BY cbr_cutoff_wrap.`time`
