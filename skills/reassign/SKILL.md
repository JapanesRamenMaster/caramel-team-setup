---
name: reassign
description: Use when 디테일러가 휴가·휴무·퇴사·파견으로 특정 날짜 예약을 소화할 수 없어 다른 디테일러에게 옮겨야 할 때, 또는 예약 1건의 담당자·시각을 조율해야 할 때. "휴가 대체", "예약 재배정", "이 사람 그날 예약 옮겨줘", "휴무인데 예약 남았다", "존 외 예약 조율", "대체 배정".
---

# /reassign — 디테일러 예약 대체 배정

(디테일러, 날짜) 또는 예약 1건을 받아 **대체 후보를 찾고 → 예약을 옮기고 → 고객에게 문자**까지 한다.

## 절대 규칙 — 건너뛰면 사고가 난다

1. **후보표를 보여주고 "실행"이라는 지시를 받기 전에는 아무것도 바꾸지 않는다.** 조회만 한다.
2. **문자 미리보기를 보여주고 "발송"이라는 지시를 받기 전에는 문자를 보내지 않는다.** 발송은 되돌릴 수 없다.
3. **순서 고정: 재배정 → DB로 결과 검증 → 그 다음 문자.** 문자를 먼저 보내면 재배정이 실패했을 때 거짓 안내가 된다.
4. **손대는 범위는 지목된 디테일러의 그 날짜 예약뿐.** 다른 사람·다른 날짜 예약을 옮겨야 후보가 생기는 상황이면 **그 사실을 보고만 하고 멈춘다**(연쇄 재배정은 별도 승인 사항).
5. **재배정 API는 근무시간·휴무·퇴사·담당 지역을 전혀 검증하지 않는다.** API가 보는 것은 **"그 디테일러의 앞뒤 예약과 시간이 겹치는지"** 하나뿐이다(그 겹침 판정에는 실제 이동시간이 들어간다). 즉 **퇴사자·휴무자·근무 외 시각에 배정해도 API는 성공한다.** 가용 판정은 전부 3단계에서 사람이 해야 한다.

---

## 0. 준비

**DB 조회** (조회만 — UPDATE/INSERT/DELETE 금지):

```bash
~/.caramel-team-setup/mysql-query.sh "SELECT ..."
```

> 이 경로에 파일이 없으면 사용자에게 DB 조회 경로를 묻는다. 다른 방법(pymysql·mysql CLI 등)을 찾아 우회하지 않는다.
> ⚠️ SQL이 `--`로 시작하면 실패한다(옵션으로 파싱됨) → 맨 앞에 공백 한 칸을 붙인다.

**API 계정**: 본인 어드민 계정을 `~/.caramel-team-setup/.env`에 넣는다(없으면 사용자에게 1회 요청).

```
ADMIN_USERNAME=<본인 어드민 아이디>
ADMIN_PASSWORD=<비밀번호>
```

> 본인 계정으로 하는 이유: 재배정하면 `#careplus-booking` 슬랙에 변경 알림이 뜨는데 **누가 옮겼는지 본인 이름으로 찍힌다.** 공유 계정을 쓰면 전부 남의 이름으로 기록된다.

**토큰 2종 발급** (용도가 달라 각각 필요):

```bash
GW=https://gateway-prod.thetrive.com
set -a; . ~/.caramel-team-setup/.env; set +a

# ① 재배정용 (sales-admin JWT)
RE_TOKEN=$(curl -s -X POST "$GW/careplus/auth/sales-admin" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))")

# 발급 확인 (pong이 나와야 정상)
curl -s "$GW/careplus/auth/sales-admin/ping" -H "Authorization: Bearer $RE_TOKEN"

# ② 문자용 (adminLogin)
MSG_TOKEN=$(curl -s -X POST "$GW/graphql" -H 'Content-Type: application/json' \
  -d "{\"query\":\"mutation L(\$l: AdminLoginDto!){ adminLogin(loginDto: \$l){ accessToken } }\",\"variables\":{\"l\":{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}}}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['adminLogin']['accessToken'])")
```

토큰 발급이나 ping이 실패하면 **거기서 멈추고** 계정 권한을 요청한다. 다른 계정으로 우회하지 않는다.

### 날짜 경계 규칙 (이 문서 전체 공통)

DB의 시각 컬럼은 **UTC 저장**이고 KST는 +9시간이다. **KST 하루(D일 00:00~24:00) = UTC `(D-1) 15:00:00` 이상 ~ `D 15:00:00` 미만.**
아래에서 `:date`=대상 날짜(`YYYY-MM-DD`), `:prev`=그 전날, `:dow`=요일 3글자(`MON`~`FRI`)로 쓴다.

🔴 **시각 컬럼을 `DATE_FORMAT` 없이 그냥 SELECT하지 말 것.** 그냥 뽑으면 저장값보다 **9시간 이른** 값에 `...Z`가 붙어 나와서 그것을 UTC로 착각하게 된다(실제로 이 혼동으로 18시간을 틀린 사례가 있다). 저장 원문과 KST를 **문자열로 함께** 뽑아 대조한다.

---

## 1. 대상 확정 — 🔴 "옮길 일"인지부터 판정한다

**휴무가 걸렸는데 그날 예약이 남아 있다 ≠ 옮겨야 한다.** 실측해 보면 이 신호의 대부분은 옮길 일이 아니었다. 이 판정을 건너뛰고 후보를 찾기 시작하면 **하지 말아야 할 재배정**을 하게 된다.

아래 1-1 ~ 1-6을 **이 순서대로** 한다. memo 판정(1-2)이 시각 범위나 후보 탐색보다 먼저다.

### 1-1. 그날 예약이 있는지 — 쿼리 A

**결과가 0건이면 여기서 끝난다.** "휴무는 걸려 있지만 그날 예약이 없어 옮길 것이 없다"고 보고하고 종료한다. 2단계로 넘어가지 않는다.
휴무 기간이 여러 날이면(쿼리 B의 `f_kst`~`t_kst`) **어느 날짜까지 처리할지 사용자에게 먼저 확인한다.** 지시받은 날짜에 0건이어도 다른 날짜에 있을 수 있다.

**쿼리 A**:

```sql
SELECT r.id, DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%m-%d %H:%i') kst,
       r.estimated_time est, au.id user_id, au.name cust, au.phone, r.location,
       r.detailed_location, r.parking_info_content,
       ua.latitude lat, ua.longitude lng,
       GROUP_CONCAT(DISTINCT p.name) products
FROM reservation r
JOIN app_user au ON au.id = r.user_id
LEFT JOIN user_address ua ON ua.id = r.address_id
LEFT JOIN user_service us ON us.reservation_id = r.id AND us.deleted_yn = 0
LEFT JOIN product p ON p.id = us.product_id
WHERE r.detailer_id = :did AND r.status = 'CONFIRMED' AND r.deleted_yn = 0
  AND DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00')) = ':date'
GROUP BY r.id ORDER BY r.reservation_datetime;
```

### 1-2. 휴무의 성격 — 쿼리 B + memo 판정

```sql
SELECT id, DATE_FORMAT(`from`,'%m-%d %H:%i') stored_from_utc,
       DATE_FORMAT(DATE_ADD(`from`, INTERVAL 9 HOUR),'%m-%d %H:%i') f_kst,
       DATE_FORMAT(DATE_ADD(`to`,   INTERVAL 9 HOUR),'%m-%d %H:%i') t_kst,
       (`from` = `to`) AS is_dummy, memo
FROM detailer_holiday
WHERE detailer_id = :did
  AND `from` < ':date 15:00:00' AND `to` > ':prev 15:00:00';
```

🔴 **`is_dummy = 1`(`from` = `to`)이면 무력화된 빈 row다 — 휴무로 세지 않는다.** 운영이 휴무를 되돌릴 때 삭제 대신 `to`를 `from`과 같게 만들어 무력화하는 경우가 있다.

#### 🔴 memo 뒤의 꼬리는 등록한 사람 서명이다 — 일감으로 읽지 말 것

`- 강`, `- 강희준`, `(안)` 같은 꼬리는 **이 휴무를 등록한 운영자 표기**다(실측: `연차 - 강희준` 61건, `연차 - 강` 16건, `연차(안)` 18건). **판정은 꼬리를 떼고 앞부분 단어로 한다.** `말표 - 강`은 "말표(일감) + 강희준(등록자)"이고, `연차 - 강`은 "연차 + 강희준"이다. 꼬리를 일감 이름으로 오독하면 판정이 뒤집힌다.

#### memo 판정 — 실측 사전

| memo | 판정 | 행동 |
|---|---|---|
| **예약 상품·장소와 같은 일감** (`말표 - 강` + 상품 `말표산업 세차권`) | **옮길 일 아님.** 그 일을 하러 가려고 원래 존을 비운 것 | 사용자에게 알리고 멈춘다 |
| `셀원 품질 점검` | **부분 블록**(대개 KST 14~18시). 가장 흔한 memo | 그 시각대 예약만 대상. 오전은 정상 근무 |
| `상/하부 공정 교육 오토랩(안)`, `상하부 공정 교육(안)` | **부분 블록**(대개 KST 13~23시) | 위와 동일 |
| `반얀트리 보조 및 교육`, `정비별동대` | **옮길 일 아님(대개).** 파견·배치 편성 부산물 | 그날 파견 슬롯이 열려 있는지 확인 후 사용자 판단 요청 |
| `[전사휴무]...`(광복절·추석 등) | 전사 휴무일 | 애초에 예약이 없어야 한다. 있으면 이상 신호이므로 보고 |
| `오전 6시 근무`, `시간대 비활성화 - ...` | 근무시간 조정용 부분 블록 | 그 시각대만 불가 |
| `퇴사 예정` | 대체 배정 대상 | 기간이 길어 건수가 많다 → 며칠분을 할지 범위를 먼저 확인 |
| **`연차`·`휴가`** | 표준 대체 배정 | 1-3으로 진행 |

memo가 비어 있거나 이 표에 없으면 **추측하지 말고 사용자에게 묻는다.**

### 1-3. 부분 휴무면 그 시각대만 대상

`f_kst`~`t_kst`가 하루 전체(00:00~다음날 00:00)가 아니면 **부분 블록**이다.

**대상 판정은 예약 시작 시각이 아니라 예약 구간 전체로 한다:**
`[예약 시각, 예약 시각 + 소요시간)`이 `[f_kst, t_kst)`와 **겹치면** 대상이다. 시작 시각만 비교하면 **세차 도중에 휴무 구간으로 들어가는 예약**을 그대로 남긴다(예: 휴무 14:00~18:00, 예약 13:00 시작 90분 → 14:30까지라 겹침 = 대상).

⚠️ 시간 길이로 전일/부분을 판정하지 말 것 — KST 13:00~23:00처럼 10시간이어도 오전 근무는 가능한 블록이다. `f_kst`/`t_kst`를 직접 읽어 판정한다.

### 1-4. 🔴 묶음(플릿) 판정 — 쪼개면 사고

쿼리 A 결과에서 **같은 고객 + 같은 주소 + 같은 상품이 연속으로 여러 건**이면 한 장소에서 여러 대를 순차로 세차하는 묶음이다.

- **묶음은 쪼개지 않는다.** 4건을 4명에게 나누면 4명이 각자 그 먼 곳까지 왕복한다.
- 후보 조건이 "그 시각 빈 사람"이 아니라 **"그날 그 시간대를 통째로 비울 수 있는 사람 1명"**으로 바뀐다.
- 묶음째 받을 사람이 없으면 시각 이동·날짜 이동으로 넘어간다(2단계 ③④⑤).
- 묶음은 **문자도 한 통으로 묶는다**(6단계).

### 1-5. 🔴 반얀트리 예약인지 확인 — 후보 풀이 정반대가 된다

쿼리 A의 `location`이 **`서울 중구 장충단로 60`(장충동2가)** 이면 반얀트리 예약이다. 이 경우 **후보 규칙이 뒤집힌다**:

- 반얀트리는 **파견된 디테일러만** 들어갈 수 있다. 일반 디테일러는 그 장소에 배정할 수 없다.
- 후보는 **`detailer_work_schedule.type LIKE 'BANYAN_TREE%'`인 사람 중에서** 찾는다.
- **①(같은 존 담당자)·②(경로)는 존 개념 자체가 안 통한다** — 반얀 스케줄은 `zone_id`가 NULL이고 장소가 고정이다. `type LIKE 'BANYAN_TREE%'`로 좁힌 파견자 풀에서 **시각 유지 → 시각 이동** 순으로만 본다.
- **자격은 반얀 방문 이력이 아니라 파견 스케줄 유무다.** 그 기간에 `BANYAN_TREE%` 스케줄이 있으면 갈 수 있다(이력 0건이어도 자격은 있다). 이력 건수는 순위 참고로만 쓴다 — 3단계 ⑨(최근 방문 지역)은 **일반 예약용**이라 반얀에는 적용되지 않는다.
- 파견자는 오전조(대개 KST 08~16)·오후조(대개 14~21)로 나뉜다. `w_start_kst`로 조를 확인한다.
- **반얀 슬롯 격자는 일반과 다르다**: 기본 `BANYAN_TREE` = KST 09·11·14·16·18, `BANYAN_TREE_EXTENDED` = 08·10·12·14·16·18·20. 시각 이동 제안 시 이 격자를 쓴다.
- **반얀 예약은 같은 시각 겹침이 항상 막힌다** — 대상 시각에 이미 예약이 있는 파견자는 후보가 아니다.
- `[전사휴무]`로 시작하는 memo는 **전원 공통**이라 후보를 가르는 기준이 못 된다. 그날은 아무도 갈 수 없으므로 날짜 자체를 옮겨야 한다.

일반 예약과 반얀 예약이 섞여 있으면 **각각 다른 후보 풀로 따로 처리**한다.

### 1-6. 고객이 이미 담당자 이름을 봤는지 확인

담당자 실명이 고객에게 노출되는 시점은 **두 번**이다 — **D-1 18:00 KST `reservationUpcoming003`**("내일 세차를 담당할 OOO입니다")과 **당일 07:00 KST `parkingInfo001`**(디테일러 이름·연락처). 이미 나갔으면 고객이 본 이름이 바뀌는 것이므로 **문자에 기존 담당자를 함께 써야 한다**(6단계).

🔴 **D-1 발송을 09:00으로 알고 있으면 시한을 반나절 잘못 잡는다**(정본: `QUERY_REFERENCE.md` §6g, 2026-08-06 전수 교정). 오후에 재배정하면서 "이미 아침에 나갔다"고 포기하지 말 것 — 18:00 전이면 아직 안 나갔다.

```sql
SELECT id, type, DATE_FORMAT(DATE_ADD(created_at, INTERVAL 9 HOUR),'%m-%d %H:%i') sent_kst,
       SUBSTRING(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(message,'$.request.msg')),
                          JSON_UNQUOTE(JSON_EXTRACT(message,'$.request.content'))),1,150) body
FROM message
WHERE customer_id = :user_id
  AND created_at >= DATE_SUB(':prev 15:00:00', INTERVAL 2 DAY)
ORDER BY id DESC LIMIT 10;
```

⚠️ `message`에는 `user_id` 컬럼이 없다(`customer_id` = `app_user.id`, 쿼리 A의 `user_id`). D-1 알림톡은 `reservation_id`를 채우지 않으므로 고객 기준으로 조회한다. **`created_at`은 UTC 저장**이므로 KST로 보려면 위처럼 `+9h`.

🔴 **본문은 `$.request.msg` 단독으로 뽑지 말 것 — 신규 발송 경로는 `$.request.content`라 `msg`로만 보면 body가 NULL로 나온다.** 판별 키는 `$.request.channel`: `KAKAO`·`MMS`·`PUSH`(신규)는 `content` 100%, `channel` NULL(레거시)만 `msg`를 쓴다(2026-08 전수). **NULL을 "발송 안 됨"으로 읽으면 오답** — 발송 여부는 row 존재와 `sent_kst`로 판정한다.

---

## 2. 후보 탐색 — 순서대로, **3단계 검증까지 통과한** 후보가 나오면 멈춘다

⚠️ 각 단계에서 이름이 몇 개 나왔다고 멈추지 말 것. **3단계 검증에서 전원 탈락하면 다음 단계로 계속 넓힌다.** 검증을 통과한 후보가 하나도 없는데 "후보 없음"으로 끝내면 오답이다.

🔴 **순위는 이 다섯 단계로만 매긴다.** 반경(직선거리)과 최근 방문 구 분포는 순위 기준이 **아니다** — 경로를 판정할 때 쓰는 보조 지표다.

| 순위 | 조건 | 고객에게 |
|---|---|---|
| **1** | **같은 존 담당자 + 시각 유지** | 담당자만 바뀜 |
| **2** | **다른 존 담당자 + 시각 유지** — 단 그날 경로가 크게 안 벗어날 때 | 담당자만 바뀜 |
| **3** | **같은 존 담당자 + 당일 다른 시각** | 시각 변경 통보 |
| **4** | 다른 존 담당자 + 당일 다른 시각 | 시각 변경 통보 |
| **5** | 다른 날짜 | 날짜 변경 통보 |

**시각 유지가 존 유지보다 먼저다.** 고객이 이미 잡아 둔 시각을 지키는 값이 존 경계보다 크다 — 존은 배차 효율이고 시각은 고객 약속이다. 그래서 2순위에서 존 밖 후보의 경로를 먼저 따지고, 그게 안 될 때 비로소 3순위로 시각을 건드린다.

**"경로가 크게 안 벗어난다"의 기준 = detour**(직전→목표→직후 − 직전→직후, ②의 계산):

| detour | 판정 |
|---|---|
| ~5km 이하 | 2순위로 채택 |
| 5~10km | 차선 — 3순위(같은 존 다른 시각) 후보와 나란히 놓고 고른다 |
| 10km 초과 | 경로 이탈 → 2순위에서 탈락, 3순위로 넘어간다 |
| 그날 예약 0건 | **경로 판정 불가 → 2순위로 쓰지 않는다.** 동선이 없으니 그 1건만 하러 왕복하게 된다. 3순위가 전부 막혔을 때 대안으로만 제시하고 왕복 거리를 명시한다 |

⚠️ 한강을 건너는 삽입은 직선 detour가 작아도 한 단계 낮춰 본다(다리 우회로 실이동 30분+).

### ⓿ 예약 주소의 담당 존을 확정한다 — 모든 탐색의 출발점

예약마다(주소마다) 먼저 존을 뽑는다. 4건이면 4건 다 뽑는다 — 같은 구라도 존이 갈릴 수 있다.

```sql
-- 포함하는 존 (SRID 0 + POINT(경도 위도) 순서 — 4326으로 쓰면 Latitude out of range)
SELECT z.id zone_db_id, z.name
FROM zone z
WHERE z.area IS NOT NULL
  AND ST_Contains(z.area, ST_GeomFromText('POINT(:lng :lat)', 0)) = 1;

-- 위가 0건(폴리곤 공백, 전체 예약지의 ~12%)이면 최근접 존 = 시스템 fallback과 동일 기준
SELECT z.id zone_db_id, z.name,
       ROUND(ST_Distance(ST_ConvexHull(z.area), ST_GeomFromText('POINT(:lng :lat)',0)), 5) dist
FROM zone z WHERE z.area IS NOT NULL ORDER BY dist LIMIT 3;
```

- ⚠️ **`zone.id`(DB PK) ≠ Z-번호(운영 명칭).** Z12=10, Z16=12, Z9=8, Z10=9, Z1=2, Z3=3, Z4=4, Z5=5, Z14=11, Z0=1. **쿼리는 `zone.id`로 하고 사람에게 말할 때는 `zone.name`을 그대로 인용**한다("zone_id 10"이 아니라 "Z12").
- ⚠️ **존 이름의 행정구역 ≠ 폴리곤 커버리지.** Z16 폴리곤이 성남 중원·수정·하남 미사를 포함한다. 구 이름으로 존을 추측하지 말고 위 쿼리 결과만 쓴다.
- 휴가자 본인의 담당 존도 같이 뽑아 둔다(아래 ① 쿼리에서 `:did`를 빼지 않고 한 번 돌리면 나온다). 예약 존과 본인 존이 다르면 그 예약은 애초에 존 외 배정이므로 후보 판단이 달라진다.

### ① 같은 존 담당자 (1순위 · 일반 예약만)

**그날 그 요일에 그 존을 담당하는 사람**을 전부 뽑는다. 존은 `detailer_work_schedule_rule.zone_id`가 정본이고 **날짜 단위로 바뀐다**(하루 파견이 흔하다) — 그래서 대상 날짜의 effective 스케줄로만 판정한다.

```sql
SELECT d.id, d.name, dws.id sched, dws.type, MIN(dwsr.zone_id) zone_db_id,
       DATE_FORMAT(DATE_ADD(MIN(dwsr.start_time), INTERVAL 9 HOUR),'%H:%i') w_start_kst,
       DATE_FORMAT(DATE_ADD(MAX(dwsr.end_time),   INTERVAL 9 HOUR),'%H:%i') w_end_kst,
       (SELECT COUNT(*) FROM reservation r WHERE r.detailer_id = d.id AND r.status='CONFIRMED'
          AND r.deleted_yn = 0
          AND DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00')) = ':date') cnt,
       (SELECT GROUP_CONCAT(CONCAT(DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%H:%i'),
               '/', r.estimated_time) ORDER BY r.reservation_datetime)
          FROM reservation r WHERE r.detailer_id = d.id AND r.status='CONFIRMED' AND r.deleted_yn = 0
          AND DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00')) = ':date') day_plan,
       (SELECT GROUP_CONCAT(CONCAT(DATE_FORMAT(DATE_ADD(dh.`from`, INTERVAL 9 HOUR),'%d %H:%i'), '~',
               DATE_FORMAT(DATE_ADD(dh.`to`, INTERVAL 9 HOUR),'%d %H:%i'), ':', dh.memo) SEPARATOR ' | ')
          FROM detailer_holiday dh WHERE dh.detailer_id = d.id AND dh.`from` <> dh.`to`
          AND dh.`from` < ':date 15:00:00' AND dh.`to` > ':prev 15:00:00') holiday
FROM detailer d
JOIN detailer_work_schedule dws ON dws.detailer_id = d.id
  AND dws.effective_from <= ':prev 15:00:00' AND dws.effective_to > ':prev 15:00:00'
  AND dws.type NOT LIKE 'BANYAN_TREE%'                                  -- 🔴 파견자 배제 (아래 설명)
JOIN detailer_work_schedule_rule dwsr ON dwsr.schedule_id = dws.id      -- ⚠️ schedule_id 필터 필수
  AND dwsr.day_of_week = ':dow' AND dwsr.deleted_at IS NULL
  AND dwsr.zone_id = :zone_db_id                                        -- ⓿에서 나온 zone.id
WHERE d.booking_yn = 1 AND d.deleted_yn = 0
GROUP BY d.id, d.name, dws.id, dws.type ORDER BY cnt;
```

- 🔴 **`dws.type NOT LIKE 'BANYAN_TREE%'`를 빼면 반얀 파견자가 후보로 올라온다 (2026-08-17 실측).** 반얀 파견 스케줄의 rule도 **`zone_id = 8`(Z9)** 을 들고 있어서, 존으로만 뽑으면 그날 반얀에 묶여 있는 사람이 Z9 대체 후보로 나온다. 재배정 API는 근무 장소를 검증하지 않으므로 **그대로 200이 떨어지고, 파견 근무창 한복판에 원존 예약을 꽂는 사고**가 된다(그게 바로 이 스킬이 고치러 온 문제다). ⚠️ **같은 사람이 날짜에 따라 파견/정상이 갈린다** — 황석찬114는 9/1엔 Z16 DEFAULT 담당인데 9/4엔 반얀 파견 하나뿐이었다. 사람 단위로 배제하지 말고 **그 날짜의 effective 스케줄 type으로** 판정할 것.
- ⚠️ **`dwsr.schedule_id = dws.id` 조인을 빼면 남의 rule까지 섞여** 담당하지 않는 사람이 후보로 올라온다.
- **존 담당자는 보통 3~5명뿐이다.** `day_plan`으로 목표 시각이 비었는지, `holiday`로 그 시각이 막혔는지, `w_start/end_kst`로 근무창에 들어오는지 본다(판정 방법은 3단계).
- 존 담당자 중 **시각 유지로 가능한 사람이 있으면 거기서 끝난다.** 더 가까운 남의 존 사람이 있어도 그쪽으로 넘어가지 않는다.
- 존 담당자가 그 시각 전원 만석/휴무면 **②(존 밖 + 시각 유지)로 넘어간다.** 존 내부의 다른 시각(③)은 그 다음이다.
- **존 내부의 빈 시각은 여기서 미리 적어 둔다** — 3순위에서 바로 쓴다. 존 담당자는 3~5명뿐이라 빈 칸이 한두 개인 것이 정상이고, **그 칸을 어느 예약에 줄지가 뒤에서 경합**한다(detour가 가장 작아지는 예약에 준다).
- 반얀 예약이면 이 단계를 건너뛴다(장소 고정 → 1-5의 파견자 풀).

### ② 다른 존이어도 그날 경로에 얹히는 사람 — **시각 유지** (2순위 · ①이 고갈된 뒤)

존 밖 사람을 볼 때의 기준은 반경이 아니라 **그날 동선에 이 건을 끼워 넣는 비용**이다. 후보의 **직전 예약 종료 위치 → 목표 주소 → 직후 예약 시작 위치**를 보고, 목표가 그 두 점 사이 경로에 얹히는지 판정한다. **여기서 걸리면 시각을 안 건드리고 끝난다** — 고객에게는 담당자 변경만 안내하면 된다.

```sql
-- 목표 시각(:hh) 기준 직전/직후 예약과 목표 주소 사이 거리·여유시간
SELECT d.id, d.name, MIN(dwsr.zone_id) zone_db_id,
       DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%H:%i') kst,
       r.estimated_time est, r.location,
       ROUND(ST_Distance_Sphere(POINT(:lng, :lat),
             POINT(COALESCE(r.longitude, ua.longitude), COALESCE(r.latitude, ua.latitude)))/1000, 1) km_to_target
FROM reservation r
JOIN detailer d ON d.id = r.detailer_id
JOIN detailer_work_schedule dws ON dws.detailer_id = d.id
  AND dws.effective_from <= ':prev 15:00:00' AND dws.effective_to > ':prev 15:00:00' AND dws.type = 'DEFAULT'
JOIN detailer_work_schedule_rule dwsr ON dwsr.schedule_id = dws.id
  AND dwsr.day_of_week = ':dow' AND dwsr.deleted_at IS NULL
LEFT JOIN user_address ua ON ua.id = r.address_id
WHERE r.status = 'CONFIRMED' AND r.deleted_yn = 0
  AND DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00')) = ':date'
  AND d.id IN (:cands)          -- 목표 시각이 빈 사람들만 넣는다
ORDER BY d.id, r.reservation_datetime;
```

판정 순서:

1. **직전 예약 종료(시작+소요) + 이동시간 ≤ 목표 시각**, **목표 종료 + 이동시간 ≤ 직후 예약 시각** — 둘 다 성립해야 후보다.
2. 성립하는 사람끼리는 **detour(직전→목표→직후 합계 − 직전→직후 직선)가 작은 순**으로 줄 세운다. "목표 주소까지 최단거리"가 아니라 **끼워 넣어서 늘어나는 거리**가 기준이다.
3. 목표가 그 사람 **하루 마지막 일정이 되면 자택까지 거리**를 detour에 더한다(3단계 ⑧).
4. **한강을 건너는 삽입은 직선거리가 짧아도 뒤로 보낸다** — 다리 우회로 실이동이 30분+ 늘고 디테일러 불만 1순위다.
5. 최근 1개월 방문 구 분포(3단계 ⑦)는 **순위 기준이 아니라 sanity check**다. detour가 작으면 이력 0건이어도 후보가 된다(그날 동선의 연장선이니까). 반대로 detour가 크면 이력이 많아도 후보가 아니다.

⚠️ `day_plan`에 목표 시각 문자열이 없다고 "빈 슬롯"으로 읽지 말 것. 앞 예약이 소요 160분이면 12:00 예약이 14:40에 끝나 14:00을 이미 잡아먹고 있다.

### ③ 같은 존 담당자의 당일 다른 시각 (3순위 · ①②가 다 막혔을 때)

①에서 적어 둔 **존 담당자의 빈 시각**을 쓴다. 격자는 **일반 예약 08·10·12·14·16·18**, **반얀 예약은 1-5의 반얀 격자**. 각 빈칸마다 ②의 앞뒤 경로 판정을 그대로 적용한다. 고객에게는 **바꿔 두고 통보**한다(4·6단계).

- 여기서부터는 고객 시각이 바뀐다. **바뀌는 예약 수를 최소화**하는 것이 목표다 — 존 내부 빈 칸이 1개인데 대상이 여러 건이면, 그 칸은 **detour가 가장 작아지는 예약**에 주고 나머지는 ④로 내린다.
- ⚠️ **08:00 예약은 `w_start_kst`가 08:00인 사람만 받을 수 있다.** 표준은 10:00~19:00이고 08시 조는 소수라, 이른 오전 슬롯은 존 내부·외부 모두 시각 유지 후보가 0이 되는 일이 흔하다(실측: 강남권 08·10·12 동시 전멸). 이때 시각 이동은 예외가 아니라 기본 경로다.

### ④ 다른 존 담당자의 당일 다른 시각 (4순위)

②에서 경로가 성립했던 사람들의 **다른 빈 시각**을 본다. 판정은 ②와 같고, 한 사람이 **두 건을 연속으로 받아 강남 루프처럼 묶이면** 각각 따로 주는 것보다 낫다(두 번째 건의 detour는 첫 건을 직전 예약으로 놓고 다시 계산한다). 건수 상한(5건)은 지킨다.

### ⑤ 다른 날짜 (④도 없으면)

그 고객의 예약 계열을 먼저 본다 — 같은 요일·같은 시각으로 반복되는 고정 슬롯이면 날짜를 옮기면 리듬이 깨지므로 **같은 날 시각 변경이 날짜 변경보다 낫다**.

```sql
SELECT r.id, DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%Y-%m-%d(%a) %H:%i') kst,
       r.status, d.name detailer
FROM user_service us
JOIN reservation r ON r.id = us.reservation_id
LEFT JOIN detailer d ON d.id = r.detailer_id
WHERE us.subscription_id = (
        SELECT subscription_id FROM user_service
        WHERE reservation_id = :rid AND deleted_yn = 0 AND subscription_id IS NOT NULL LIMIT 1)
ORDER BY r.reservation_datetime;
```

±1일 범위에서 가능한 슬롯 2~3개를 뽑아 고객이 고를 수 있게 제시한다.

---

## 3. 후보 검증 — 전부 통과해야 후보다

재배정 API가 가용성을 검증하지 않으므로 **호출 전에 여기서 다 걸러야 한다.**

| # | 검증 | 방법 |
|---|---|---|
| 1 | **현직인가** | `detailer_supply_sheet.status = '현직'` — ⚠️ `retired_yn`은 믿지 않는다 |
| 2 | **출장 세차 인력인가** | `detailer_supply_sheet.region <> '오토랩'` (고정샵 제외) |
| 3 | **예약 수령 가능** | `d.booking_yn = 1 AND d.deleted_yn = 0` |
| 4 | **그 시각 휴무 아님** | 쿼리 B를 그 후보에게 실행(`from <> to`). 부분 블록이면 **예약 구간 전체**가 휴무 구간과 겹치지 않는지 판정 |
| 5 | **근무시간 안에 들어오는가** | `w_start_kst ≤ 예약 시각` **그리고** `예약 시각 + 소요시간 ≤ w_end_kst`. 시작만 보면 퇴근 시간에 걸치는 배정이 통과한다 |
| 6 | **겹침 없음** | 목표 시각 앞뒤 예약의 `시작 + 소요 + 이동`으로 구간 계산. 시각 문자열 비교 금지 |
| 7 | **담당 존 일치인가** | 2단계 ⓿의 `zone.id`와 후보의 그 날짜 `dwsr.zone_id`가 같은가. 다르면 후보표에 **"존 외(Zxx 담당)"를 명시**하고 ②의 detour 근거를 함께 쓴다 |
| 8 | **경로에 얹히는가** | 직전 종료→목표→직후 시작이 시간·거리로 성립하는가(②의 판정 1·2). 한강 횡단은 감점 |
| 9 | **최근 방문 지역** (sanity check) | 아래 쿼리. **순위 기준이 아니다** — detour가 작으면 이력 0건도 통과, detour가 크면 이력 많아도 탈락 (**반얀 예약에는 적용 안 함** — 1-5) |
| 10 | **퇴근 동선** | 그 건이 그 사람 **마지막 일정**이면 자택까지 거리를 본다 |

**⑨ 최근 방문 지역 (보조 확인)**:

```sql
SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(r.location,' ',2),' ',-1) gu, COUNT(*) c
FROM reservation r
WHERE r.detailer_id = :cand AND r.status IN ('WASHED','REPORT_SENT')
  AND r.reservation_datetime >= DATE_SUB(NOW(), INTERVAL 1 MONTH)
GROUP BY gu ORDER BY c DESC;
```

담당 존이 같은 사람은 이 확인이 필요 없다(존이 곧 담당 권역이다). 존 밖 후보에서만, 경로가 성립하는데도 그 권역을 한 번도 안 가봤다면 근거에 적는다. **이 분포로 순위를 매기지 말 것** — 최근 방문 구가 많다는 것은 "그 사람 담당 권역"이라는 뜻일 뿐, 이 예약이 그날 그의 경로에 얹힌다는 뜻이 아니다.

**⑩ 자택**:

```sql
SELECT d.id, d.name, ss.home_address, ss.status, ss.region
FROM detailer d
JOIN detailer_supply_sheet ss
  ON ss.phone_norm COLLATE utf8mb4_general_ci = REPLACE(d.phone,'-','')
WHERE d.id IN (:cands);
```

(현직·출장인력·자택 검증을 한 번에 하도록 `status`·`region`을 같이 뽑는다. ⚠️ 조인 컬럼은 `phone_norm`이고 `COLLATE`가 없으면 실패한다.)

🔴 **현재 담당자의 자택도 본다.** 옮기려는 예약이 실은 그 사람 집 앞일 수 있다 — 그러면 그 배정이 원래 합리적이었다는 뜻이고, 옮기는 것이 손해다.

**하루 건수 상한**: 5건을 넘기면 경고하고, 7건은 넘기지 않는다.

---

## 4. 후보 제시 — [STOP 1]

예약별로 이 표를 출력한다.

```
#89032 | 정영환 | 07-31 12:00 | 김포 양촌읍 학운산단2로 53-15 | 소요 70분 | 존 Z4(강서구/김포시)
  1순위  김민준(206)  ✅Z4 담당   10:00/40m 종료 10:40 → 6.1km → 12:00 시작,
                                14:00 다음 건까지 3.2km. detour +2.1km. 근무 10~19, 그날 4건
  2순위  김승규(190)  ✅Z4 담당   10:00/65m 종료 11:05 → 9.3km(이동 30분) 여유 25분(tight)
  3순위  최우석(143)  ⚠️존 외(Z10 담당)  detour +4.4km이나 그날 동선이 김포 방향,
                                Z4 담당 2명이 tight해 대안으로 제시
  탈락   유현종(154)  Z4 담당이지만 10:00 예약이 90분이라 11:30 종료 + 이동 45분 → 12:00 불가
```

- 후보가 0이면 **왜 0인지**(전원 휴무·근무 외 시각·묶음을 받을 사람 없음 등)를 쓰고 ③④⑤ 결과를 함께 제시한다.
- 시각·날짜가 바뀌는 후보는 **바뀐다는 사실을 표에 명시**한다.
- 여기서 멈춘다. **"실행"이라는 지시 없이 5단계로 넘어가지 않는다.**

---

## 5. 재배정 실행

### 실행 직전 재확인 — 달라졌으면 STOP 1으로 돌아간다

예약이 아직 그대로인지 쿼리 A로 다시 확인한다. **상태·시각·담당자·주소·상품 중 하나라도 후보표를 만들 때와 다르면 실행을 중단하고, 새로 후보표를 만들어 "실행" 승인을 다시 받는다.** 낡은 승인으로 이미 바뀐 예약을 건드리면 안 된다.

```bash
curl -s -X PUT "$GW/careplus/reservations-admin/<예약ID>/schedule" \
  -H "Authorization: Bearer $RE_TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "reservationDatetime": "2026-07-31T03:00:00.000Z",
    "detailerId": 206,
    "skipConflictCheckYn": false,
    "shuffleYn": false,
    "sendMessageYn": false
  }'
```

| 파라미터 | 값 | 이유 |
|---|---|---|
| `reservationDatetime` | **UTC** ISO (KST 12:00 = `03:00:00.000Z`) | 시각을 유지할 때도 반드시 기존 값을 그대로 실어 보낸다 |
| `detailerId` | 새 담당자 | |
| `skipConflictCheckYn` | `false` | 겹침 검증에 실제 이동시간이 들어간다. `true`로 우회하지 말 것 |
| `shuffleYn` | **`false`** | 🔴 안 잠그면 **그날 17시 자동 재배정이 우리가 고른 사람을 다른 사람으로 되돌린다.** 문자로 알린 담당자 이름이 어긋난다 |
| `sendMessageYn` | **`false`** | 시스템 알림톡을 끄고 6단계에서 사람이 쓴 문자로 보낸다. `true`면 문자가 중복된다 |

**400 `방문이 불가능한 시간입니다` 또는 409면 그 후보는 실제로 불가능하다.**

- **후보표에 있던 다음 순위로만 넘어간다.** 후보표에 없던 사람에게 배정하려면 **새 후보표를 보여주고 "실행" 승인을 다시 받는다.** 사용자가 승인하지 않은 사람에게 예약을 옮기면 안 된다.
- `skipConflictCheckYn`을 켜서 밀어넣지 않는다.

**성공 후 DB로 검증** (응답만 믿지 않는다):

```sql
SELECT r.id, d.name detailer,
       DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%m-%d %H:%i') kst,
       r.allow_shuffle_yn, r.status
FROM reservation r JOIN detailer d ON d.id = r.detailer_id
WHERE r.id IN (:ids);
```

`detailer`가 새 담당자이고 `allow_shuffle_yn = 0`이어야 정상이다. **여기까지 통과한 건에 대해서만** 문자를 보낸다.

---

## 6. 고객 문자 — [STOP 2]

### 보내기 전 확인

1. **이미 보낸 게 있는지** — 작업이 중단됐다 재개된 경우 같은 고객에게 두 번 갈 수 있다. 1-6 쿼리를 다시 실행해 **오늘 변경 안내가 나갔는지** 확인한다. 나갔으면 다시 보내지 않는다.
2. **한 고객에게 여러 건이면 한 통으로 묶는다.** 같은 사유·같은 날짜면 문자 1통에 여러 건을 적는다. 건별로 4통을 보내면 CS 문의가 들어온다.
3. **`app_user.name`을 눈으로 확인한다** — 숫자나 두 글자 미만이면(전화 뒷자리가 이름에 들어간 경우가 있다) 개인화를 버리고 "고객님"으로 쓴다.

톤: **정중한 컨시어지체**(`~드립니다`/`~하실 수 있습니다`). 가벼운 말투·이모지 금지.

### 담당자만 바뀔 때 (시각 동일)

```
[카라멜] {고객명}님, 세차 담당자 변경 안내

{날짜} {시각} 예정된 세차의 담당 디테일러가
{기존}에서 {신규}으로 변경되었습니다.

일정과 장소는 그대로이며, 주차 위치와 차 키는
기존과 동일하게 두시면 됩니다.

문의: 앱 > 마이 > 고객센터 또는 1544-5932
```

### 시각·날짜가 바뀔 때 (push형)

기본값이 "진행"이고 고객이 움직이는 것은 이탈할 때만이어야 한다. "편한 시간 알려주세요"로 열어 보내면 연락이 몰린다.

```
[카라멜] {고객명}님, {차량} 세차 일정 변경 안내

담당 디테일러의 급작스러운 사정으로
{날짜} {기존시각} 세차를 {신규시각}으로 옮겨 두었습니다.
불편을 드려 진심으로 사과드립니다.

담당자: {기존} → {신규}
장소: {주소} {상세위치}

괜찮으시면 따로 하실 일은 없습니다.
어려우시면 {전날} 저녁 8시 전까지 앱에서 취소해 주십시오.
그 이후 취소는 세차 회차가 소진됩니다.

문의: 앱 > 마이 > 고객센터 또는 1544-5932
```

- **D-1 알림톡이 이미 나갔으면(1-6) 담당자 `{기존} → {신규}`를 반드시 넣는다.** 고객이 이미 다른 이름을 봤다.
- 🔴 **전날 20:00 시한을 반드시 넣는다.** 그 이후 취소는 세차 회차가 사라져 **우리 사정으로 옮겼는데 고객이 손해**를 본다.
- 🔴 **이미 전날 20:00을 지났다면**(당일 변경 등) 위 문구를 쓰지 말 것. 취소 시한이 지나 고객이 취소하면 회차를 잃는다. 대신 **"취소를 원하시면 고객센터로 연락 주십시오 — 회차는 그대로 보존해 드립니다"**로 바꾸고, 실제 취소 요청이 오면 **CS에 우리 귀책 처리를 요청해 회차를 되살린다.**

### 미리보기 — 전부 보여주고 한 번에 승인받는다

수신자가 여러 명이면 **모든 사람의 미리보기를 다 출력한 뒤** "발송" 승인을 받는다. 첫 통만 보여주고 나머지를 검수 없이 보내면 안 된다.

```
[발송 미리보기] 총 2명
--- 1/2 정영환 (010-****-3466) ---
<최종 문구>
--- 2/2 김상리 (010-****-2007) ---
<최종 문구>
발신: 1544-5932 · 채널 LMS
```

**미리보기 후 수신자·본문이 바뀌면 미리보기를 다시 보여주고 승인을 다시 받는다.**

**"발송" 지시를 받은 뒤에만** 보낸다:

```bash
curl -s -X POST "$GW/careplus/message/send/v2" \
  -H "Authorization: Bearer $MSG_TOKEN" -H 'Content-Type: application/json' \
  -d '{
    "signalType": "MMS",
    "messageChannelType": "LMS",
    "from": "15445932",
    "to": ["01083813466"],
    "subject": "세차 일정 변경 안내",
    "content": "<본문>\n\n[무료수신거부] 0808701439"
  }'
```

사람마다 문구가 다르므로 **수신자별로 따로 호출**한다. 실패하면 HTTP 코드와 응답 본문을 그대로 보고한다.

---

## 7. 마감 보고

| 예약 | 고객 | 기존 담당·시각 | 변경 후 | 문자 |
|---|---|---|---|---|
| #89032 | 정영환 | 최우석 07-31 12:00 | 김민준 07-31 12:00 | 발송 완료 |
| #89033 | 정영환 | 최우석 07-31 14:00 | — (후보 없음) | — |

처리하지 못한 건은 **이유와 함께** 남긴다. 조용히 빠뜨리지 않는다.

---

## 함정 목록

| 함정 | 실제로 무슨 일이 나는가 |
|---|---|
| 존 후보 쿼리에서 파견자를 안 뺀다 | 반얀 파견 rule도 `zone_id=8`이라 파견자가 Z9 후보로 올라온다. API는 200을 주고, 파견 근무창 한복판에 원존 예약이 꽂힌다 |
| 파견자를 사람 단위로 기억해 배제한다 | 같은 사람이 날짜에 따라 파견/정상이 갈린다(황석찬114: 9/1 Z16 정상, 9/4 반얀 전용). 그 날짜 effective 스케줄 type으로만 판정 |
| 휴무 memo를 안 보고 옮긴다 | 그 일을 하러 가려고 비운 날인데 그 일감을 남에게 흩어놓는다 |
| memo 꼬리(`- 강`·`(안)`)를 일감으로 읽는다 | 등록자 서명인데 일감으로 오독해 판정이 뒤집힌다 |
| 묶음을 쪼갠다 | 한 장소 4대를 4명이 각자 왕복한다 |
| 반얀 예약을 일반 후보에게 준다 | 파견자만 들어갈 수 있는 장소라 배정 자체가 불가능하다 |
| `shuffleYn`을 안 잠근다 | 그날 17시 자동 재배정이 되돌려 통지한 담당자 이름이 어긋난다 |
| 시각 문자열로 빈 슬롯 판정 | 앞 예약 소요시간이 그 시각을 이미 잡아먹고 있다 |
| 부분 휴무를 예약 시작 시각만으로 판정 | 세차 도중 휴무 구간에 들어가는 예약을 그대로 남긴다 |
| 근무 시작 시각만 본다 | 퇴근 시간에 걸치는 배정이 통과한다 |
| 휴무 시간 길이로 전일 판정 | KST 13~23시 부분 블록을 전일로 읽어 오전 가능자를 탈락시킨다 |
| 근무시간을 10~19로 가정 | 이른 조(08~17)에게 18:00을 배정한다 |
| 반경(직선거리)·최근 방문 구로 순위를 만든다 | 담당 존이 기준인데 남의 존 사람이 1순위로 올라온다. 존 → 그날 앞뒤 경로 순으로만 줄 세운다 |
| 존 유지를 시각 유지보다 앞세운다 | 존 밖 사람이 경로에 얹히는데도 존 담당자의 다른 시각으로 옮겨 **고객 시각을 불필요하게 바꾼다.** 존은 배차 효율, 시각은 고객 약속 — 2순위(존 밖 시각 유지)가 3순위(존 내부 시각 이동)보다 먼저다 |
| 그날 예약 0건인 사람을 "여유 있다"고 2순위에 넣는다 | 동선이 없어 경로 판정 자체가 불가하다. 그 1건만 하러 왕복하게 되므로 3순위가 다 막힌 뒤 왕복 거리를 명시해 대안으로만 |
| 존을 `supply_sheet.region`이나 구 이름으로 판정한다 | region은 낡은 값이고 존 폴리곤은 이름의 행정구역보다 넓다. `ST_Contains` + 그 날짜 `dwsr.zone_id`가 정본 |
| `zone.id`를 Z-번호로 착각한다 | Z12=10·Z16=12·Z9=8. 엉뚱한 존 담당자를 후보로 올린다 |
| 존 밖 후보를 "목표까지 최단거리"로 고른다 | 끼워 넣어 늘어나는 거리(detour)가 기준이다. 최단거리 1위가 동선을 왕복으로 찢을 수 있다 |
| 1차 탐색에서 나온 이름만 보고 "후보 없음" 결론 | 검증 전 원자료다. 전원 탈락하면 다음 탐색 단계로 넓혀야 한다 |
| 자택을 안 본다 | 그날 마지막 일정이면 퇴근길 편도 수십km를 얹는다 |
| 실패 후 후보표에 없던 사람에게 배정 | 사용자가 승인하지 않은 배정이 된다 |
| 재확인 없이 낡은 승인으로 실행 | 이미 취소·변경된 예약을 건드린다 |
| 문자를 먼저 보낸다 | 재배정이 실패하면 거짓 안내가 된다 |
| 첫 통만 미리보고 발송 | 나머지 고객에게 검수 안 된 문자가 간다 |
| 전날 20:00 시한을 안 쓴다 | 우리 사정으로 옮겼는데 고객 세차 회차가 사라진다 |
| 시한이 지났는데 "취소하세요"로 안내 | 고객이 취소하면 회차를 잃는다. 고객센터 경로로 유도해야 한다 |
| 휴무 `from`/`to`를 raw로 SELECT | 렌더가 저장값 −9h라 UTC로 착각한다. `DATE_FORMAT`으로 저장 원문+KST를 함께 뽑는다 |
| `from = to` row를 휴무로 센다 | 무력화된 빈 row다. 가능한 사람을 탈락시킨다 |
| `[전사휴무]`를 후보 판별에 쓴다 | 전원 공통이라 아무도 못 간다. 날짜를 옮겨야 한다 |
| API 200을 가용으로 읽는다 | 퇴사자·휴무자·근무 외 시각에도 200이 나온다 |
