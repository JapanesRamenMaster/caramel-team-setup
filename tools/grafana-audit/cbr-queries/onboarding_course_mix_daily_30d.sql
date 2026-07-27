WITH live_users AS (SELECT id FROM app_user WHERE deleted_yn=0 AND test_yn=0 AND temp_yn=0 AND (phone NOT IN ('01020866510','01035474964','01093277016','01091350157','01043446885','01049664316','01050373300','01066943645','01073740979','01092828753','01035420850','01051415705','01091622508','01000000000') OR phone IS NULL)),
onboarding_purchase AS (
  SELECT DATE(DATE_ADD(us.created_at, INTERVAL 9 HOUR)) AS d,
         CASE
           WHEN pr.name LIKE '라이트%' THEN '라이트 코스'
           WHEN pr.name LIKE '베이직%' THEN '베이직 코스'
           WHEN pr.name LIKE '장마%'   THEN '장마 대비 풀코스'
         END AS course,
         us.user_id
  FROM user_service us
  JOIN live_users lu ON lu.id=us.user_id
  JOIN product pr ON pr.id=us.product_id
  WHERE us.deleted_yn=0
    AND (pr.name LIKE '라이트%' OR pr.name LIKE '베이직%' OR pr.name LIKE '장마%')
    AND pr.type='VOUCHER'
    AND us.created_at >= '2026-07-15'
)
SELECT d AS time,
  COUNT(DISTINCT CASE WHEN course='라이트 코스' THEN user_id END) AS `라이트 코스`,
  COUNT(DISTINCT CASE WHEN course='베이직 코스' THEN user_id END) AS `베이직 코스`,
  COUNT(DISTINCT CASE WHEN course='장마 대비 풀코스' THEN user_id END) AS `장마 대비 풀코스`
FROM onboarding_purchase
WHERE course IS NOT NULL
  AND d >= DATE_SUB(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)), INTERVAL 30 DAY)
GROUP BY d
ORDER BY d
