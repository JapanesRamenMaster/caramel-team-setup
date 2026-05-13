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
  SELECT r.id, r.user_id, r.detailer_id, r.reservation_datetime, r.washed_at
  FROM reservation r
  WHERE r.status IN ('REPORT_SENT','WASHED')
    AND r.reservation_datetime IS NOT NULL
),
svc AS (
  SELECT us.reservation_id, SUM(s.time_required) AS svc_estimated_min
  FROM filtered_reservations fr
  JOIN user_service us ON us.reservation_id = fr.id
  JOIN service s ON s.id = us.service_id
  WHERE us.deleted_yn = 0 AND us.used_yn = 1 AND us.paid_yn = 1
  GROUP BY us.reservation_id
),
opt AS (
  SELECT uo.reservation_id, SUM(o.extra_time) AS opt_estimated_min
  FROM filtered_reservations fr
  JOIN user_option uo ON uo.reservation_id = fr.id
  JOIN options o ON o.id = uo.option_id
  WHERE uo.deleted_yn = 0 AND uo.used_yn = 1 AND uo.paid_yn = 1
  GROUP BY uo.reservation_id
),
classified AS (
  SELECT
    DATE(DATE_ADD(fr.reservation_datetime, INTERVAL 9 HOUR)) AS kst_date,
    (COALESCE(svc.svc_estimated_min, 0) + COALESCE(opt.opt_estimated_min, 0)) AS estimated_min,
    TIMESTAMPDIFF(MINUTE, wr.created_at, COALESCE(wr.finished_at, fr.washed_at)) AS actual_min,
    CASE
      WHEN d.work_start_date IS NULL THEN 'regular'
      WHEN DATE(DATE_ADD(fr.reservation_datetime, INTERVAL 9 HOUR)) >= DATE_ADD(d.work_start_date, INTERVAL 3 MONTH) THEN 'regular'
      ELSE 'probation'
    END AS detailer_segment
  FROM filtered_reservations fr
  JOIN live_users u ON u.id = fr.user_id
  JOIN active_detailers d ON d.id = fr.detailer_id
  JOIN wash_result wr ON wr.reservation_id = fr.id AND wr.deleted_yn = 0
  LEFT JOIN svc ON svc.reservation_id = fr.id
  LEFT JOIN opt ON opt.reservation_id = fr.id
  WHERE wr.created_at IS NOT NULL
    AND COALESCE(wr.finished_at, fr.washed_at) IS NOT NULL
)
SELECT
  kst_date AS date,
  detailer_segment,
  0 AS first_wash_eligible,
  0 AS first_wash_late,
  0 AS nonfirst_wash_eligible,
  0 AS nonfirst_wash_late30,
  0 AS nonfirst_wash_early30,
  SUM(CASE WHEN actual_min BETWEEN 10 AND 180 AND estimated_min > 0 THEN 1 ELSE 0 END) AS estimate_eligible,
  SUM(CASE WHEN actual_min BETWEEN 10 AND 180 AND estimated_min > 0 AND actual_min > estimated_min THEN 1 ELSE 0 END) AS estimate_over
FROM classified
GROUP BY kst_date, detailer_segment
ON DUPLICATE KEY UPDATE
  estimate_eligible = VALUES(estimate_eligible),
  estimate_over = VALUES(estimate_over);
