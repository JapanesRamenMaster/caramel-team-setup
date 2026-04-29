INSERT INTO cbr_daily_time_compliance_snapshot (
  date, detailer_segment,
  first_wash_eligible, first_wash_late,
  nonfirst_wash_eligible, nonfirst_wash_late30, nonfirst_wash_early30,
  estimate_eligible, estimate_over
)
WITH live_users AS (
  SELECT id FROM app_user
  WHERE deleted_yn = 0 AND test_yn = 0 AND temp_yn = 0
    AND phone NOT IN (
      '01020866510','01035474964','01093277016','01091350157',
      '01043446885','01049664316','01050373300','01066943645',
      '01073740979','01092828753','01035420850','01051415705',
      '01091622508','01000000000'
    )
),
active_detailers AS (
  SELECT d.id, dss.work_start_date
  FROM detailer d
  JOIN detailer_supply_sheet dss
    ON d.name COLLATE utf8mb4_general_ci = dss.name COLLATE utf8mb4_general_ci
  WHERE d.deleted_yn = 0 AND dss.status = '현직'
),
filtered_reservations AS (
  SELECT r.id, r.user_id, r.detailer_id, r.reservation_datetime
  FROM reservation r
  WHERE r.status IN ('IN_PROGRESS','WASHED','REPORT_SENT')
    AND r.reservation_datetime IS NOT NULL
),
all_washes AS (
  SELECT
    fr.detailer_id,
    DATE(DATE_ADD(fr.reservation_datetime, INTERVAL 9 HOUR)) AS kst_date,
    TIMESTAMPDIFF(MINUTE, fr.reservation_datetime, wr.created_at) AS diff_min,
    wr.created_at AS start_at,
    d.work_start_date
  FROM filtered_reservations fr
  JOIN live_users u ON fr.user_id = u.id
  JOIN wash_result wr ON wr.reservation_id = fr.id AND wr.deleted_yn = 0
  JOIN active_detailers d ON fr.detailer_id = d.id
  WHERE wr.created_at IS NOT NULL
),
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY kst_date, detailer_id ORDER BY start_at) AS rn
  FROM all_washes
),
classified AS (
  SELECT
    kst_date,
    rn,
    diff_min,
    CASE
      WHEN work_start_date IS NULL THEN 'regular'
      WHEN kst_date >= DATE_ADD(work_start_date, INTERVAL 3 MONTH) THEN 'regular'
      ELSE 'probation'
    END AS detailer_segment
  FROM ranked
)
SELECT
  kst_date AS date,
  detailer_segment,
  SUM(CASE WHEN rn = 1 THEN 1 ELSE 0 END) AS first_wash_eligible,
  SUM(CASE WHEN rn = 1 AND diff_min > 1 THEN 1 ELSE 0 END) AS first_wash_late,
  SUM(CASE WHEN rn > 1 THEN 1 ELSE 0 END) AS nonfirst_wash_eligible,
  SUM(CASE WHEN rn > 1 AND diff_min >= 31 THEN 1 ELSE 0 END) AS nonfirst_wash_late30,
  SUM(CASE WHEN rn > 1 AND diff_min <= -31 THEN 1 ELSE 0 END) AS nonfirst_wash_early30,
  0 AS estimate_eligible,
  0 AS estimate_over
FROM classified
GROUP BY kst_date, detailer_segment
ON DUPLICATE KEY UPDATE
  first_wash_eligible = VALUES(first_wash_eligible),
  first_wash_late = VALUES(first_wash_late),
  nonfirst_wash_eligible = VALUES(nonfirst_wash_eligible),
  nonfirst_wash_late30 = VALUES(nonfirst_wash_late30),
  nonfirst_wash_early30 = VALUES(nonfirst_wash_early30);
