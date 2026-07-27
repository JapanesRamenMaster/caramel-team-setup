WITH live_users AS (SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0 AND (phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000') OR phone IS NULL)),
target_users AS (SELECT DISTINCT c.user_id FROM car c JOIN car_model_target cmt ON cmt.id=c.model_id WHERE c.deleted_yn=0 AND cmt.is_target=1),
pay AS (
  SELECT DATE_ADD(p.paid_at, INTERVAL 9 HOUR) AS ts,
    GREATEST(p.amount
      - IF(JSON_UNQUOTE(JSON_EXTRACT(p.metadata,'$.source'))='COUPON_PACKAGE_REDEEM', 0,
           COALESCE((SELECT SUM(pm.amount) FROM payment_medium pm WHERE pm.payment_id=p.id AND pm.medium='POINT'),
                    CAST(JSON_UNQUOTE(JSON_EXTRACT(p.metadata,'$.point')) AS SIGNED), 0))
      - IF(p.status='PARTIAL_CANCELED', COALESCE(p.cancel_amount,0), 0), 0) AS amt
  FROM payment p
  JOIN live_users lu ON lu.id=p.user_id
  JOIN target_users tu ON tu.user_id=p.user_id
  WHERE p.deleted_yn=0 AND p.status IN ('PAID','PARTIAL_CANCELED') AND p.paid_at IS NOT NULL
),
onsite AS (
  SELECT DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR) AS ts,
         SUM(COALESCE(gi.gross,0)+COALESCE(aj.adj,0)) AS amt
  FROM reservation_onsite_collection oc
  JOIN reservation r ON r.id=oc.reservation_id
  JOIN live_users lu ON lu.id=r.user_id
  JOIN target_users tu ON tu.user_id=r.user_id
  LEFT JOIN (SELECT collection_id, SUM(amount_snapshot) AS gross FROM reservation_onsite_collection_item WHERE canceled_at IS NULL GROUP BY collection_id) gi ON gi.collection_id=oc.id LEFT JOIN (SELECT i.collection_id, SUM(a.amount) AS adj FROM reservation_onsite_collection_item_adjustment a JOIN reservation_onsite_collection_item i ON i.id=a.collection_item_id AND i.canceled_at IS NULL GROUP BY i.collection_id) aj ON aj.collection_id=oc.id WHERE oc.status<>'CANCELED' AND r.deleted_yn=0 AND r.status IN ('WASHED','REPORT_SENT')
  GROUP BY oc.id, r.reservation_datetime
),
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
combined AS (SELECT ts, amt FROM pay UNION ALL SELECT ts, amt FROM onsite UNION ALL SELECT DATE_ADD(ts, INTERVAL 9 HOUR), amt FROM banyan_pkg)
SELECT CAST(DATE_FORMAT(ts,'%Y-%m-01') AS DATE) AS time, ROUND(SUM(amt)) AS target_purchase_amount
FROM combined
WHERE ts >= DATE_SUB(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR), INTERVAL 12 MONTH)
GROUP BY time ORDER BY time
