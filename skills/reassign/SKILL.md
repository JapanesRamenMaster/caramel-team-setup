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
5. **재배정 API는 근무시간·휴무·퇴사를 아무것도 검증하지 않는다.** 오직 "같은 사람 같은 시각 겹침"만 본다. API가 200을 주는 것은 그 사람이 갈 수 있다는 뜻이 **아니다**. 3단계 검증을 사람 대신 해줄 시스템은 없다.

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

---

## 1. 대상 확정 — 🔴 "옮길 일"인지부터 판정한다

**휴무가 걸렸는데 그날 예약이 남아 있다 ≠ 옮겨야 한다.** 실측해 보면 이 신호의 대부분은 옮길 일이 아니었다. 이 판정을 건너뛰고 후보를 찾기 시작하면 **하지 말아야 할 재배정**을 하게 된다.

아래 1-1 ~ 1-6을 **이 순서대로** 한다. 순서가 중요하다 — memo 판정(1-2)이 시각 범위나 후보 탐색보다 먼저다.

### 1-1. 그날 예약이 있는지 — 쿼리 A

**결과가 0건이면 여기서 끝난다.** "휴무는 걸려 있지만 그날 예약이 없어 옮길 것이 없다"고 보고하고 종료한다. 2단계로 넘어가지 않는다.
휴무 기간이 여러 날이면(쿼리 B의 `f_kst`~`t_kst`) **어느 날짜까지 처리할지 사용자에게 먼저 확인한다.** 지시받은 날짜에 0건이어도 다른 날짜에 있을 수 있다.

**쿼리 A** (`:did`, `:date` 치환):

```sql
SELECT r.id, DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%m-%d %H:%i') kst,
       r.estimated_time est, au.name cust, au.phone, r.location,
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

**쿼리 B** (`:date`=대상일, `:prev`=전날):

```sql
SELECT id, DATE_FORMAT(`from`,'%m-%d %H:%i') stored_from_utc,
       DATE_FORMAT(DATE_ADD(`from`, INTERVAL 9 HOUR),'%m-%d %H:%i') f_kst,
       DATE_FORMAT(DATE_ADD(`to`,   INTERVAL 9 HOUR),'%m-%d %H:%i') t_kst,
       (`from` = `to`) AS is_dummy, memo
FROM detailer_holiday
WHERE detailer_id = :did
  AND `from` < ':date 14:59:59' AND `to` > ':prev 15:00:00';
```

🔴 **`from`/`to`를 `DATE_FORMAT` 없이 그냥 SELECT하지 말 것.** 그냥 뽑으면 저장값보다 **9시간 이른** 값이 `...Z`가 붙어 나와서 그것을 UTC로 착각하게 된다(실제로 이 혼동으로 18시간을 틀린 사례가 있다). 저장 원문과 KST를 위처럼 **문자열로 함께** 뽑아 대조한다.

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

`f_kst`~`t_kst`가 하루 전체(00:00~다음날 00:00)가 아니면 **부분 블록**이다. 그 시각 범위에 걸리는 예약만 대상이고 나머지는 그 사람이 그대로 한다.
⚠️ 시간 길이로 판정하지 말 것 — KST 13:00~23:00처럼 10시간이어도 오전 근무는 가능한 블록이 있다. `f_kst`/`t_kst`를 직접 읽고 대상 예약 시각이 그 안에 드는지로 판정한다.

### 1-4. 🔴 묶음(플릿) 판정 — 쪼개면 사고

쿼리 A 결과에서 **같은 고객 + 같은 주소 + 같은 상품이 연속으로 여러 건**이면 한 장소에서 여러 대를 순차로 세차하는 묶음이다.

- **묶음은 쪼개지 않는다.** 4건을 4명에게 나누면 4명이 각자 그 먼 곳까지 왕복한다.
- 후보 조건이 "그 시각 빈 사람"이 아니라 **"그날 그 시간대를 통째로 비울 수 있는 사람 1명"**으로 바뀐다.
- 묶음째 받을 사람이 없으면 시각 이동·날짜 이동으로 넘어간다(2단계 ③④).

### 1-5. 🔴 반얀트리 예약인지 확인 — 후보 풀이 정반대가 된다

쿼리 A의 `location`이 **`서울 중구 장충단로 60`(장충동2가)** 이면 반얀트리 예약이다. 이 경우 **후보 규칙이 뒤집힌다**:

- 반얀트리는 **파견된 디테일러만** 들어갈 수 있다. 일반 디테일러는 그 장소에 배정할 수 없다.
- 따라서 후보는 **`detailer_work_schedule.type LIKE 'BANYAN_TREE%'`인 사람 중에서** 찾는다(2단계 ②의 "반얀 제외" 규칙은 **일반 예약일 때만** 적용).
- 반얀 슬롯 격자는 일반과 다르다(KST 09·11·14·16·18, 확장 편성은 08·10·12·14·16·18·20). 파견자는 오전조(대개 KST 08~16)·오후조(대개 14~21)로 나뉘므로 `w_start_kst`로 조를 확인한다.
- **반얀 예약은 같은 시각 겹침이 항상 막힌다** — 대상 시각에 이미 예약이 있는 파견자는 후보가 아니다.

일반 예약과 반얀 예약이 섞여 있으면 **각각 다른 후보 풀로 따로 처리**한다.

반얀 예약일 때 2단계는 이렇게 바뀐다:

- **①(반경 탐색)은 건너뛴다.** 장소가 고정이라 "그 동네를 도는 사람"이라는 개념이 무의미하다. ②로 바로 가서 `type LIKE 'BANYAN_TREE%'`로 좁힌다.
- **자격은 반얀 방문 이력이 아니라 파견 스케줄 유무다.** 그 기간에 `BANYAN_TREE%` 스케줄이 있으면 갈 수 있다(이력 0건이어도 자격은 있다). 이력 건수는 순위 참고로만 쓴다 — 3단계 ⑥의 "그날 동선의 연장선인가" 판단은 **일반 예약용**이라 반얀에는 적용되지 않는다.
- `[전사휴무]`로 시작하는 memo는 **전원 공통**이라 후보를 가르는 기준이 못 된다. 대신 그날은 아무도 갈 수 없으므로 날짜 자체를 옮겨야 한다.

### 1-6. 고객이 이미 담당자 이름을 봤는지 확인

D-1 09:00에 나가는 알림톡 본문에 **"내일 세차를 담당할 OOO입니다"**가 들어간다. 이미 나갔으면 고객이 본 이름이 바뀌는 것이므로 문자에서 반드시 언급해야 한다.

```sql
SELECT id, DATE_FORMAT(created_at,'%m-%d %H:%i') sent_at,
       SUBSTRING(JSON_UNQUOTE(JSON_EXTRACT(message,'$.request.msg')),1,120) body
FROM message
WHERE customer_id = :app_user_id AND created_at >= ':prev 00:00:00'
ORDER BY id DESC LIMIT 5;
```

⚠️ `message`에는 `user_id` 컬럼이 없다(`customer_id` = `app_user.id`). D-1 알림톡은 `reservation_id`를 채우지 않으므로 고객 기준으로 조회한다.

---

## 2. 후보 탐색 — 순서대로, 앞 단계에서 나오면 멈춘다

### ① 그 시각에 그 동네를 도는 사람 (1순위)

목표 주소 좌표(`:lng`, `:lat`)를 넣어 **그날 예약이 목표 주소 근처에 있는 사람**을 거리순으로 뽑는다. 담당 존으로 후보를 만들지 말 것 — 존과 무관하게 실제로 그 동네를 도는 사람이 잡혀야 한다.

```sql
SELECT d.id, d.name,
       ROUND(MIN(ST_Distance_Sphere(POINT(:lng, :lat),
              POINT(COALESCE(r.longitude, ua.longitude), COALESCE(r.latitude, ua.latitude))))/1000, 1) min_km,
       COUNT(*) cnt,
       GROUP_CONCAT(CONCAT(DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%H:%i'),
              '/', r.estimated_time, 'm') ORDER BY r.reservation_datetime) day_plan
FROM reservation r
JOIN detailer d ON d.id = r.detailer_id
LEFT JOIN user_address ua ON ua.id = r.address_id
WHERE r.status = 'CONFIRMED' AND r.deleted_yn = 0
  AND DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00')) = ':date'
  AND d.booking_yn = 1 AND d.deleted_yn = 0
  AND d.id NOT IN (132, 125, 168, :did)
GROUP BY d.id HAVING min_km <= 25 ORDER BY min_km;
```

`day_plan`이 그 사람의 그날 일정(시각/소요분)이다. **여기서 겹침을 직접 계산한다** — 목표 시각 앞 예약의 `시작 + 소요 + 이동시간`이 목표 시각을 넘으면 불가.
⚠️ `day_plan`에 목표 시각 문자열이 없다고 "빈 슬롯"으로 읽지 말 것. 앞 예약이 소요 160분이면 12:00 예약이 14:40에 끝나 14:00을 이미 잡아먹고 있다.

### ② 그날 여유 있는 사람 (①에 없으면)

그날 근무는 하는데 예약이 적은 사람. `:dow`는 요일 3글자(`MON`~`FRI`), `:prev`는 전날.

```sql
SELECT d.id, d.name, dws.type, dwsr.zone_id,
       DATE_FORMAT(DATE_ADD(dwsr.start_time, INTERVAL 9 HOUR),'%H:%i') w_start_kst,
       DATE_FORMAT(DATE_ADD(dwsr.end_time,   INTERVAL 9 HOUR),'%H:%i') w_end_kst,
       (SELECT COUNT(*) FROM reservation r WHERE r.detailer_id = d.id AND r.status='CONFIRMED'
          AND r.deleted_yn = 0
          AND DATE(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00')) = ':date') cnt,
       (SELECT COUNT(*) FROM detailer_holiday dh WHERE dh.detailer_id = d.id
          AND dh.`from` < ':date 14:59:59' AND dh.`to` > ':prev 15:00:00') holi
FROM detailer d
JOIN detailer_work_schedule dws ON dws.detailer_id = d.id
  AND dws.effective_from <= ':prev 15:00:00' AND dws.effective_to > ':prev 15:00:00'
JOIN detailer_work_schedule_rule dwsr ON dwsr.schedule_id = dws.id
  AND dwsr.day_of_week = ':dow' AND dwsr.deleted_at IS NULL
WHERE d.booking_yn = 1 AND d.deleted_yn = 0 AND d.id NOT IN (132, 125, 168, :did)
ORDER BY cnt, d.id;
```

이 결과에서 바로 읽어야 하는 것:

- **`type`이 `BANYAN_TREE%`인 사람은 후보에서 제외** — 단 **일반 예약일 때만**. 반얀트리 파견자는 그 장소에 묶여 있어 밖에 아예 나갈 수 없다. 반대로 **대상이 반얀 예약(장충단로 60)이면 이 사람들만 후보**다(1-5 참조).
- **`w_start_kst`가 08:00인 사람은 이른 조(08~17)라 18:00 예약을 받을 수 없다.** 표준은 10:00~19:00. 사람마다 다르므로 표준으로 가정하지 말 것.
- **`holi > 0`이면 휴무 후보** — 단 전일인지 부분인지 쿼리 B로 그 사람에 대해 다시 확인해야 한다(부분 블록이면 다른 시각은 가능).

### ③ 같은 날 다른 시각 (①②에 없으면)

후보의 빈 시각(격자 08·10·12·14·16·18)마다 앞뒤 예약 좌표로 삽입 가능한지 보고 제시한다. 고객에게는 **바꿔 두고 통보**한다(4·6단계).

### ④ 다른 날짜 (③도 없으면)

그 고객의 예약 계열을 먼저 본다 — 같은 요일·같은 시각으로 반복되는 고정 슬롯이면 날짜를 옮기면 리듬이 깨지므로 **같은 날 시각 변경이 날짜 변경보다 낫다**.

```sql
SELECT r.id, DATE_FORMAT(CONVERT_TZ(r.reservation_datetime,'+00:00','+09:00'),'%Y-%m-%d(%a) %H:%i') kst,
       r.status, d.name detailer
FROM user_service us
JOIN reservation r ON r.id = us.reservation_id
LEFT JOIN detailer d ON d.id = r.detailer_id
WHERE us.subscription_id = (SELECT subscription_id FROM user_service WHERE reservation_id = :rid LIMIT 1)
ORDER BY r.reservation_datetime;
```

±1일 범위에서 가능한 슬롯 2~3개를 뽑아 고객이 고를 수 있게 제시한다.

---

## 3. 후보 검증 — 전부 통과해야 후보다

재배정 API가 아무것도 검증하지 않으므로 **호출 전에 여기서 다 걸러야 한다.**

| # | 검증 | 방법 |
|---|---|---|
| 1 | **현직인가** | `detailer_supply_sheet.status = '현직'` — ⚠️ `retired_yn`은 믿지 않는다. 조인은 `ss.phone_norm COLLATE utf8mb4_general_ci = REPLACE(d.phone,'-','')` |
| 2 | **출장 세차 인력인가** | `supply_sheet.region <> '오토랩'` (고정샵 제외) |
| 3 | **예약 수령 가능** | `d.booking_yn = 1 AND d.deleted_yn = 0` |
| 4 | **그 시각 휴무 아님** | 쿼리 B를 그 후보에게 실행. 부분 블록이면 목표 시각이 범위에 드는지 직접 판정 |
| 5 | **겹침 없음** | 목표 시각 앞뒤 예약의 `시작 + 소요 + 이동`으로 구간 계산. 시각 문자열 비교 금지 |
| 6 | **실제 다니는 지역인가** | 아래 쿼리로 최근 1개월 방문 구 분포 확인 |
| 7 | **퇴근 동선** | 그 건이 그 사람 **마지막 일정**이면 자택까지 거리를 본다 |

**⑥ 실제 다니는 지역**:

```sql
SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(r.location,' ',2),' ',-1) gu, COUNT(*) c
FROM reservation r
WHERE r.detailer_id = :cand AND r.status IN ('WASHED','REPORT_SENT')
  AND r.reservation_datetime >= DATE_SUB(NOW(), INTERVAL 1 MONTH)
GROUP BY gu ORDER BY c DESC;
```

거리·근무시간·겹침을 다 통과해도 **한 번도 안 가본 권역**일 수 있다. 거리는 "그날 인접 예약과의 직선거리"라서 하루 일정 중간에 낯선 권역을 끼워 넣는 것을 못 걸러낸다. 이력이 0이어도 **그날 동선의 연장선**이면 수용 가능하다 — 기계적으로 탈락시키지는 말고 근거를 쓴다.

**⑦ 자택** (`home_address`):

```sql
SELECT d.id, d.name, ss.home_address
FROM detailer d
JOIN detailer_supply_sheet ss
  ON ss.phone_norm COLLATE utf8mb4_general_ci = REPLACE(d.phone,'-','')
WHERE d.id IN (:cands);
```

🔴 **현재 담당자의 자택도 본다.** 옮기려는 예약이 실은 그 사람 집 앞일 수 있다 — 그러면 그 배정이 원래 합리적이었다는 뜻이고, 옮기는 것이 손해다.

**하루 건수 상한**: 5건을 넘기면 경고하고, 7건은 넘기지 않는다.

---

## 4. 후보 제시 — [STOP 1]

예약별로 이 표를 출력한다.

```
#89032 | 정영환 | 07-31 12:00 | 김포 양촌읍 학운산단2로 53-15 | 소요 70분
  1순위  김민준(206)  6.1km  그날 10:00/40m·14:00/40m → 12:00 삽입 가능, 김포 이력 23건, 현직
  2순위  김승규(190)  9.3km  10:00/65m 종료 11:05 → 이동 30분, 여유 25분(tight)
  탈락   유현종(154)  10:00 예약이 90분이라 11:30 종료 + 이동 45분 → 12:00 불가
```

- 후보가 0이면 **왜 0인지**(전원 휴무·근무 외 시각·묶음을 받을 사람 없음 등)를 쓰고 ③④ 결과를 함께 제시한다.
- 시각·날짜가 바뀌는 후보는 **바뀐다는 사실을 표에 명시**한다.
- 여기서 멈춘다. **"실행"이라는 지시 없이 5단계로 넘어가지 않는다.**

---

## 5. 재배정 실행

실행 직전 **예약이 아직 그대로인지 다시 확인**한다(그 사이 취소·변경됐을 수 있다).

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
| `skipConflictCheckYn` | `false` | 실제 이동시간 기반 검증이 공짜로 붙는다. `true`로 우회하지 말 것 |
| `shuffleYn` | **`false`** | 🔴 안 잠그면 **그날 17시 자동 재배정이 우리가 고른 사람을 다른 사람으로 되돌린다.** 문자로 알린 담당자 이름이 어긋난다 |
| `sendMessageYn` | **`false`** | 시스템 알림톡을 끄고 6단계에서 사람이 쓴 문자로 보낸다. `true`면 문자가 중복된다 |

**응답이 400 `방문이 불가능한 시간입니다` 또는 409**면 그 후보는 실제로 불가능하다. 다음 후보로 넘어가고, `skipConflictCheckYn`을 켜서 밀어넣지 않는다.

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

톤: **정중한 컨시어지체**(`~드립니다`/`~하실 수 있습니다`). 가벼운 말투·이모지 금지.

⚠️ `app_user.name`을 눈으로 확인한다 — 숫자나 두 글자 미만이면(전화 뒷자리가 이름에 들어간 경우가 있다) 개인화를 버리고 "고객님"으로 쓴다.

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

새 담당자: {신규}
장소: {주소} {상세위치}

괜찮으시면 따로 하실 일은 없습니다.
어려우시면 {전날} 저녁 8시 전까지 앱에서 취소해 주십시오.
그 이후 취소는 세차 회차가 소진됩니다.

문의: 앱 > 마이 > 고객센터 또는 1544-5932
```

🔴 **전날 20:00 시한을 반드시 넣는다.** 그 이후 취소는 세차 회차가 사라져 **우리 사정으로 옮겼는데 고객이 손해를 본다.** 늦게 취소된 건은 CS에 우리 귀책으로 처리를 요청해 회차를 되살린다.

**미리보기를 출력하고 멈춘다:**

```
[발송 미리보기]
받는 사람: 정영환 (010-8381-3466) 1명
발신: 1544-5932
본문 (N바이트):
---
<최종 문구>
---
```

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

여러 명이면 사람마다 문구가 달라야 하므로 **건별로 따로 호출**한다. 실패하면 HTTP 코드와 응답 본문을 그대로 보고한다.

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
| 휴무 memo를 안 보고 옮긴다 | 그 일을 하러 가려고 비운 날인데 그 일감을 남에게 흩어놓는다 |
| memo 꼬리(`- 강`·`(안)`)를 일감으로 읽는다 | 등록자 서명인데 일감으로 오독해 판정이 뒤집힌다 |
| 반얀 예약을 일반 후보에게 준다 | 파견자만 들어갈 수 있는 장소라 배정 자체가 불가능하다 |
| 그날 예약 0건인데 후보를 찾는다 | 옮길 것이 없는데 남의 일정을 들여다본다. 0건이면 즉시 종료 |
| 휴무 `from`/`to`를 raw로 SELECT | 렌더가 저장값 −9h라 UTC로 착각한다. `DATE_FORMAT`으로 저장 원문+KST를 함께 뽑는다 |
| `from = to` row를 휴무로 센다 | 무력화된 빈 row다. 가능한 사람을 탈락시킨다 |
| `[전사휴무]`를 후보 판별에 쓴다 | 전원 공통이라 아무도 못 간다. 날짜를 옮겨야 한다 |
| 묶음을 쪼갠다 | 한 장소 4대를 4명이 각자 왕복한다 |
| `shuffleYn`을 안 잠근다 | 그날 17시 자동 재배정이 되돌려 통지한 담당자 이름이 어긋난다 |
| 시각 문자열로 빈 슬롯 판정 | 앞 예약 소요시간이 그 시각을 이미 잡아먹고 있다 |
| 휴무 시간 길이로 전일 판정 | KST 13~23시 부분 블록을 전일로 읽어 오전 가능자를 탈락시킨다 |
| 근무시간을 10~19로 가정 | 이른 조(08~17)에게 18:00을 배정한다 |
| 반얀 파견자를 후보에 넣는다 | 그 장소에 묶여 있어 밖에 나갈 수 없다 |
| 존으로 후보를 만든다 | 실제로 그 동네를 도는 다른 존 사람이 통째로 안 보인다 |
| 자택을 안 본다 | 그날 마지막 일정이면 퇴근길 편도 수십km를 얹는다 |
| 문자를 먼저 보낸다 | 재배정이 실패하면 거짓 안내가 된다 |
| 전날 20:00 시한을 안 쓴다 | 우리 사정으로 옮겼는데 고객 세차 회차가 사라진다 |
| API 200을 가용으로 읽는다 | 퇴사자·휴무자·근무 외 시각에도 200이 나온다 |
