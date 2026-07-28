WITH live_users AS (SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0 AND (phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000') OR phone IS NULL)),
target_users AS (SELECT DISTINCT c.user_id FROM car c JOIN car_model_target cmt ON cmt.id=c.model_id WHERE c.deleted_yn=0 AND cmt.is_target=1),
postpaid_first AS (
  SELECT r.user_id, MIN(r.created_at) AS ts
  FROM reservation_onsite_collection oc
  JOIN reservation r ON r.id=oc.reservation_id
  JOIN live_users lu ON lu.id=r.user_id
  WHERE oc.status<>'CANCELED' AND r.deleted_yn=0
    AND r.status IN ('CONFIRMED','WASHED','REPORT_SENT')
  GROUP BY r.user_id
),
banyan_pkg AS (
  SELECT n.user_id, MIN(n.created_at) AS ts
  FROM crm_note n JOIN live_users lu ON lu.id=n.user_id
  WHERE n.memo LIKE '%회권 지급 · 수금할 금액%' AND n.deleted_yn=0
    AND EXISTS (SELECT 1 FROM user_service us
                WHERE us.user_id=n.user_id AND us.service_id=137 AND us.deleted_yn=0)
  GROUP BY n.user_id
),
purchase_events AS (
  SELECT p.user_id, p.paid_at AS ts, p.type AS ptype,
         IF(JSON_UNQUOTE(JSON_EXTRACT(p.metadata,'$.source'))='COUPON_PACKAGE_REDEEM','PARTNER','DIRECT') AS src
  FROM payment p JOIN live_users lu ON lu.id=p.user_id
  WHERE p.status = 'PAID' AND p.amount>0 AND p.deleted_yn=0 AND p.paid_at IS NOT NULL AND p.type IN ('VOUCHER','SUBSCRIPTION','PACKAGE')
  UNION ALL
  SELECT pf.user_id, pf.ts, 'VOUCHER', 'DIRECT' FROM postpaid_first pf
  UNION ALL
  SELECT b.user_id, b.ts, 'PACKAGE', 'PARTNER' FROM banyan_pkg b
),
first_purchase_all AS (
  SELECT user_id, ts, ptype, src FROM (
    SELECT pe.*, ROW_NUMBER() OVER (PARTITION BY pe.user_id ORDER BY pe.ts) AS rn FROM purchase_events pe
  ) x WHERE rn=1
),
first_only AS (
  SELECT fp.user_id, fp.ptype, CAST(DATE_FORMAT(DATE_ADD(fp.ts, INTERVAL 9 HOUR),'%Y-%m-01') AS DATE) AS `time`
  FROM first_purchase_all fp JOIN target_users tu ON tu.user_id = fp.user_id
)
SELECT `time`,
  ROUND(COUNT(DISTINCT CASE WHEN ptype='SUBSCRIPTION' THEN user_id END)
        / NULLIF(COUNT(DISTINCT user_id), 0) * 100, 2) AS sub_first_pct
FROM first_only
WHERE `time` >= CAST(DATE_FORMAT(DATE_SUB(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR), INTERVAL 11 MONTH),'%Y-%m-01') AS DATE)
GROUP BY `time` ORDER BY `time`
