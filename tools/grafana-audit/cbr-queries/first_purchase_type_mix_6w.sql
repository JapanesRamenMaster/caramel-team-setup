WITH
live_users AS (SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0 AND (phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000') OR phone IS NULL)),
target_users AS (SELECT DISTINCT c.user_id FROM car c JOIN car_model_target cmt ON cmt.id=c.model_id WHERE c.deleted_yn=0 AND cmt.is_target=1),
banyan_pkg AS (
  SELECT n.user_id,
         MIN(n.created_at) AS ts,
         CAST(REPLACE(REGEXP_SUBSTR(n.memo,'[0-9,]+원'),',','') AS UNSIGNED) AS amt
  FROM crm_note n
  JOIN live_users lu ON lu.id=n.user_id
  JOIN target_users tu ON tu.user_id=n.user_id
  WHERE n.memo LIKE '%회권 지급 · 수금할 금액%' AND n.deleted_yn=0
    AND EXISTS (SELECT 1 FROM user_service us
                WHERE us.user_id=n.user_id AND us.service_id=137 AND us.deleted_yn=0)
  GROUP BY n.user_id, DATE(DATE_ADD(n.created_at, INTERVAL 9 HOUR)),
           CAST(REPLACE(REGEXP_SUBSTR(n.memo,'[0-9,]+원'),',','') AS UNSIGNED)
),
purchase_events AS (SELECT p.user_id, p.type, p.paid_at AS ts FROM payment p JOIN live_users lu ON lu.id = p.user_id JOIN target_users tu ON tu.user_id = p.user_id WHERE p.status = 'PAID' AND p.deleted_yn = 0 AND p.amount > 0 AND p.paid_at IS NOT NULL AND p.type IN ('VOUCHER','SUBSCRIPTION','PACKAGE') UNION ALL SELECT b.user_id, 'PACKAGE', b.ts FROM banyan_pkg b),
first_payments AS (SELECT user_id, type, DATE(DATE_ADD(ts, INTERVAL 9 HOUR)) AS paid_kst, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY ts) AS rn FROM purchase_events),
first_only AS (SELECT user_id, type, paid_kst, DATE_SUB(paid_kst, INTERVAL WEEKDAY(paid_kst) DAY) AS `time` FROM first_payments WHERE rn = 1),
bucketed AS (SELECT `time`, COUNT(DISTINCT CASE WHEN type='VOUCHER' THEN user_id END) AS voucher_cnt, COUNT(DISTINCT CASE WHEN type='PACKAGE' THEN user_id END) AS package_cnt, COUNT(DISTINCT CASE WHEN type='SUBSCRIPTION' THEN user_id END) AS subscription_cnt FROM first_only GROUP BY `time`)
SELECT * FROM bucketed w
WHERE w.`time` >= DATE_SUB(DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY), INTERVAL 6 WEEK)
  AND w.`time` < DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY)
ORDER BY w.`time`;
