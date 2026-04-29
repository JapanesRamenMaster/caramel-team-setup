-- 근무 디테일러수_헤이딜러+파견 포함 (12개월 rolling, 월별)
-- Grafana timeseries 패널용
-- 정의: 그 달에 세차 1건+ 잡힌 디테일러 ∪ 현재 status='파견'인 디테일러 (UNION으로 중복 제거)
WITH live_users AS (
    SELECT *
    FROM app_user u
    WHERE u.deleted_yn = 0
      AND u.test_yn = 0
      AND u.temp_yn = 0
      AND u.phone NOT IN (
        '01020866510','01035474964','01093277016','01091350157',
        '01043446885','01049664316','01050373300','01066943645',
        '01073740979','01092828753','01035420850','01051415705',
        '01091622508','01000000000'
      )
),
valid_reservations AS (
    SELECT r.*
    FROM reservation r
    JOIN live_users u ON r.user_id = u.id
    WHERE r.status IN ('REPORT_SENT','WASHED','IN_PROGRESS')
),
active_detailers AS (
    SELECT d.id, dss.status
    FROM detailer d
    JOIN detailer_supply_sheet dss
      ON d.name COLLATE utf8mb4_general_ci = dss.name COLLATE utf8mb4_general_ci
    WHERE d.deleted_yn = 0
      AND dss.status IN ('현직', '파견')
),
dispatched_detailers AS (
    SELECT id FROM active_detailers WHERE status = '파견'
),
months AS (
    SELECT DATE_SUB(
        DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
                 INTERVAL (DAYOFMONTH(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) - 1) DAY),
        INTERVAL n MONTH
    ) AS month_start
    FROM (
        SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
        UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
        UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
    ) seq
),
base AS (
    SELECT
        r.id AS reservation_id,
        r.detailer_id,
        DATE(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)) AS kst_date,
        CAST(DATE_FORMAT(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR), '%Y-%m-01') AS DATE) AS month_start
    FROM valid_reservations r
    JOIN active_detailers d ON r.detailer_id = d.id
),
bounded AS (
    SELECT *
    FROM base
    WHERE kst_date >= DATE_SUB(
        DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),
                 INTERVAL (DAYOFMONTH(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) - 1) DAY),
        INTERVAL 11 MONTH
    )
),
worked_per_month AS (
    SELECT month_start, detailer_id
    FROM bounded
    GROUP BY month_start, detailer_id
    HAVING COUNT(DISTINCT kst_date) > 0
),
dispatched_per_month AS (
    SELECT m.month_start, dd.id AS detailer_id
    FROM months m
    CROSS JOIN dispatched_detailers dd
)
SELECT month_start AS time, COUNT(*) AS value
FROM (
    SELECT month_start, detailer_id FROM worked_per_month
    UNION
    SELECT month_start, detailer_id FROM dispatched_per_month
) u
GROUP BY month_start
ORDER BY month_start;
