INSERT INTO cbr_daily_revenue_snapshot (date, total_revenue, completed_washes, revenue_onetime, washes_onetime, revenue_sub, washes_sub)
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
washed_reservations AS (
  SELECT r.id
  FROM reservation r
  JOIN live_users u ON u.id = r.user_id
  WHERE r.status IN ('WASHED','REPORT_SENT')
    AND r.deleted_yn = 0
    AND r.reservation_datetime IS NOT NULL
),
us_base AS (
  SELECT us.id AS user_service_id, us.reservation_id, us.payment_id,
         us.product_id, us.service_id, us.subscription_id, s.price AS service_price
  FROM user_service us
  JOIN washed_reservations wr ON wr.id = us.reservation_id
  JOIN service s ON s.id = us.service_id
  WHERE us.deleted_yn = 0 AND us.paid_yn = 1 AND us.used_yn = 1
),
uo_base AS (
  SELECT uo.id AS user_option_id, uo.reservation_id, uo.payment_id,
         uo.option_id, o.price AS option_price
  FROM user_option uo
  JOIN washed_reservations wr ON wr.id = uo.reservation_id
  JOIN options o ON o.id = uo.option_id
  WHERE uo.deleted_yn = 0 AND uo.paid_yn = 1 AND uo.used_yn = 1
),
us_counts AS (
  SELECT payment_id, product_id, COUNT(*) AS user_service_count
  FROM us_base WHERE payment_id IS NOT NULL AND product_id IS NOT NULL
  GROUP BY payment_id, product_id
),
uo_counts AS (
  SELECT payment_id, option_id, COUNT(*) AS user_option_count
  FROM uo_base WHERE payment_id IS NOT NULL GROUP BY payment_id, option_id
),
price_items AS (
  SELECT p.id AS payment_id, jt.item_type, jt.item_id,
         jt.item_price, jt.item_original_price, jt.item_quantity
  FROM payment p
  LEFT JOIN JSON_TABLE(
    p.metadata, '$.prices[*]' COLUMNS(
      item_type VARCHAR(32) PATH '$.type',
      item_id INT PATH '$.id',
      item_price INT PATH '$.price',
      item_original_price INT PATH '$.originalPrice',
      item_quantity INT PATH '$.quantity'
    )
  ) jt ON TRUE
  WHERE p.deleted_yn = false AND p.status IN ('PAID','PARTIAL_CANCELED')
),
payment_points AS (
  SELECT p.id AS payment_id,
         COALESCE(pm.point_amount,
           CAST(JSON_UNQUOTE(JSON_EXTRACT(p.metadata, '$.point')) AS SIGNED), 0) AS point_amount
  FROM payment p
  LEFT JOIN (
    SELECT payment_id, SUM(amount) AS point_amount
    FROM payment_medium WHERE medium = 'POINT' GROUP BY payment_id
  ) pm ON pm.payment_id = p.id
  WHERE p.deleted_yn = false AND p.status IN ('PAID','PARTIAL_CANCELED')
),
service_ticket_items AS (
  SELECT us.user_service_id AS item_ref_id, us.reservation_id, us.payment_id,
         'SERVICE_TICKET' AS item_kind,
         IF(us.payment_id IS NULL, 0, COALESCE(pi.item_price / NULLIF(uc.user_service_count, 0), us.service_price)) AS base_price,
         COALESCE(pi.item_original_price / NULLIF(uc.user_service_count, 0), us.service_price) AS original_price,
         IF(us.payment_id IS NULL, 1, 0) AS zero_payment_yn
  FROM us_base us
  LEFT JOIN us_counts uc ON uc.payment_id = us.payment_id AND uc.product_id = us.product_id
  LEFT JOIN price_items pi ON pi.payment_id = us.payment_id AND pi.item_type = 'PRODUCT' AND pi.item_id = us.product_id
),
option_items AS (
  SELECT uo.user_option_id AS item_ref_id, uo.reservation_id, uo.payment_id,
         'OPTION' AS item_kind,
         IF(uo.payment_id IS NULL, 0, COALESCE(pi.item_price / NULLIF(oc.user_option_count, 0), uo.option_price)) AS base_price,
         COALESCE(pi.item_original_price / NULLIF(oc.user_option_count, 0), uo.option_price) AS original_price,
         IF(uo.payment_id IS NULL, 1, 0) AS zero_payment_yn
  FROM uo_base uo
  LEFT JOIN uo_counts oc ON oc.payment_id = uo.payment_id AND oc.option_id = uo.option_id
  LEFT JOIN price_items pi ON pi.payment_id = uo.payment_id AND pi.item_type = 'OPTION' AND pi.item_id = uo.option_id
),
service_change_items AS (
  SELECT us.id AS item_ref_id, us.reservation_id, p.id AS payment_id,
         'SERVICE_CHANGE' AS item_kind, ci.price AS base_price, ci.price AS original_price, 0 AS zero_payment_yn
  FROM cart_item ci
  JOIN cart c ON c.id = ci.cart_id
  JOIN payment p ON p.cart_id = c.id
  JOIN user_service us ON us.id = ci.user_service_id
  JOIN washed_reservations wr ON wr.id = us.reservation_id
  WHERE ci.type IN ('SERVICE_UPGRADE','SERVICE_DOWNGRADE')
    AND (ci.deleted_yn = false OR ci.deleted_yn = 0)
    AND p.deleted_yn = false AND p.status IN ('PAID','PARTIAL_CANCELED')
),
all_items AS (
  SELECT * FROM service_ticket_items UNION ALL
  SELECT * FROM option_items UNION ALL
  SELECT * FROM service_change_items
),
payment_totals AS (
  SELECT payment_id,
         SUM(CASE WHEN original_price > 0 THEN original_price ELSE 0 END) AS total_positive_original_price
  FROM all_items WHERE payment_id IS NOT NULL GROUP BY payment_id
),
items_with_point AS (
  SELECT ai.*,
         COALESCE(pp.point_amount, 0) AS point_amount,
         COALESCE(pt.total_positive_original_price, 0) AS total_positive_original_price,
         IF(ai.original_price > 0 AND COALESCE(pt.total_positive_original_price, 0) > 0,
            ROUND(COALESCE(pp.point_amount, 0) * ai.original_price / pt.total_positive_original_price), 0) AS point_alloc
  FROM all_items ai
  LEFT JOIN payment_points pp ON pp.payment_id = ai.payment_id
  LEFT JOIN payment_totals pt ON pt.payment_id = ai.payment_id
),
reservation_revenue AS (
  SELECT reservation_id, SUM(base_price - point_alloc) AS sale_total
  FROM items_with_point
  GROUP BY reservation_id
),
res_kind AS (
  -- 한 reservation에 구독권 user_service가 하나라도 있으면 '구독', 없으면 '1회권'
  SELECT us.reservation_id,
         MAX(CASE WHEN us.subscription_id IS NOT NULL THEN 1 ELSE 0 END) AS is_sub
  FROM us_base us
  GROUP BY us.reservation_id
)
SELECT
  DATE(DATE_ADD(r.reservation_datetime, INTERVAL 9 HOUR)) AS date,
  ROUND(SUM(rv.sale_total)) AS total_revenue,
  COUNT(DISTINCT rv.reservation_id) AS completed_washes,
  ROUND(SUM(CASE WHEN COALESCE(rk.is_sub, 0) = 0 THEN rv.sale_total ELSE 0 END)) AS revenue_onetime,
  COUNT(DISTINCT CASE WHEN COALESCE(rk.is_sub, 0) = 0 THEN rv.reservation_id END) AS washes_onetime,
  ROUND(SUM(CASE WHEN COALESCE(rk.is_sub, 0) = 1 THEN rv.sale_total ELSE 0 END)) AS revenue_sub,
  COUNT(DISTINCT CASE WHEN COALESCE(rk.is_sub, 0) = 1 THEN rv.reservation_id END) AS washes_sub
FROM reservation_revenue rv
JOIN reservation r ON r.id = rv.reservation_id
LEFT JOIN res_kind rk ON rk.reservation_id = rv.reservation_id
GROUP BY date
ON DUPLICATE KEY UPDATE
  total_revenue = VALUES(total_revenue),
  completed_washes = VALUES(completed_washes),
  revenue_onetime = VALUES(revenue_onetime),
  washes_onetime = VALUES(washes_onetime),
  revenue_sub = VALUES(revenue_sub),
  washes_sub = VALUES(washes_sub);
