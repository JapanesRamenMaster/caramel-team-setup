---
name: rain-retouch
description: 비오는 날 리터치 배정 작업. reservation_retouch.status=REQUESTED 건들에 대해 존별 디테일러 스케줄링 → API 배정까지 실행. "리터치 배정", "rain retouch", "리터치 넣어", "REQUESTED 리터치" 등이 나오면 사용.
---

# 비오는 날 리터치 배정 스킬

## 개요

`reservation_retouch` 테이블의 `REQUESTED` 건을 조회 → 디테일러 배정 후보 계산 → `api-prod.thetrive.com` 직접 호출로 예약 생성까지 한 번에 처리.

---

## 1단계: 데이터 조회

### REQUESTED 리터치 조회
```sql
SELECT rr.id AS retouch_id, rr.parent_reservation_id,
  rr.available_times, rr.metadata, rr.requested_at,
  au.name AS customer_name, au.phone AS customer_phone,
  d_orig.name AS original_detailer_name,
  ua.address AS customer_address, ua.latitude, ua.longitude
FROM reservation_retouch rr
JOIN reservation r ON r.id = rr.parent_reservation_id
JOIN detailer d_orig ON d_orig.id = r.detailer_id
JOIN user_address ua ON ua.id = r.address_id
JOIN app_user au ON au.id = r.user_id
WHERE rr.status = 'REQUESTED' AND rr.deleted_at IS NULL
ORDER BY rr.id DESC;
```

**metadata.zoneId** = 이미 계산된 존 ID, **available_times.selectedTimeBlocks** = 고객 희망 UTC 시간 블록.

### 시간 블록 → KST 슬롯 변환
```python
# available_times의 from/to는 UTC 문자열 (JSON 컬럼, mysql2 변환 없음)
from_kst = datetime.fromisoformat(block['from'].replace('Z', '+00:00')) + timedelta(hours=9)
to_kst   = datetime.fromisoformat(block['to'].replace('Z',   '+00:00')) + timedelta(hours=9)
# 유효 슬롯: 8, 10, 12, 14, 16, 18 중 from_kst.hour <= slot < to_kst.hour
```

---

## 2단계: 디테일러 스케줄 조회

### 존별 디테일러 + 근무시간 (holiday 제외 포함)
```sql
SELECT DISTINCT d.id AS detailer_id, d.name AS detailer_name,
       dwsr.zone_id, dwsr.day_of_week,
       HOUR(dwsr.start_time) AS start_hour_raw,   -- UTC 물리값 (DATETIME 컬럼)
       HOUR(dwsr.end_time)   AS end_hour_raw
FROM detailer d
JOIN detailer_work_schedule dws ON dws.detailer_id = d.id
  AND dws.effective_from <= :date AND dws.effective_to > :date
JOIN detailer_work_schedule_rule dwsr ON dwsr.schedule_id = dws.id
  AND dwsr.zone_id IN (:zone_ids)
  AND dwsr.day_of_week = :dow   -- 'MON','TUE',...
  AND dwsr.deleted_at IS NULL
-- ✅ 휴가 제외: 반드시 배정할 날짜 단위로 별도 체크
-- ⚠️ 여러 날짜를 OR로 묶으면 한 날만 연차여도 전부 제외됨 — 날짜별 쿼리 분리 필수
LEFT JOIN detailer_holiday dh ON dh.detailer_id = d.id
  AND :specific_date BETWEEN DATE(dh.from) AND DATE(dh.to)   -- ← 날짜 1개만!
-- ✅ booking_yn = 1 필수 (Grafana Utilization 대시보드 기준)
WHERE d.deleted_yn = 0 AND d.booking_yn = 1 AND dh.id IS NULL;
```

### ⚠️ 필수 필터 체크리스트 (2026-06-19 운영 사고에서 도출)
- **`d.booking_yn = 1`**: 미적용 시 예약 불가 디테일러 포함됨 (Grafana 대시보드 기준)
- **`detailer_holiday` LEFT JOIN + `dh.id IS NULL`**: 연차·퇴사 디테일러 제외. `from`/`to` 사이 날짜 포함 여부 체크
- **`d.deleted_yn = 0`**: 기본
- (선택) `d.retired_yn = 0`: 퇴사자 이중 필터

### 근무시간 패턴

| 그룹 | start_raw | end_raw | KST 근무 | 가능 슬롯 KST |
|------|-----------|---------|----------|--------------|
| 표준 | 1 | 10 | 10~19시 | 10,12,14,16,18 |
| 조조 | 23 | 8 | 08~17시 | 08,10,12,14,16 |

**⚠️ Zone10(Z12 강남/서초) = 대부분 조조(08~17)** → 18시 대체로 불가(17시는 운영 판단 허용). **단 예외 있음**: 염철림(165 등) 표준근무(10~19)자는 18시 가능. "전원 조조"로 단정 말고 스케줄 개별 확인(2026-07-08).

### 슬롯 유효성 체크 (Python)
```python
def slot_utc(kst): return (kst - 9 + 24) % 24

def valid_slot(kst, start_raw, end_raw):
    u = slot_utc(kst)
    if start_raw < end_raw: return start_raw <= u < end_raw   # 표준
    else: return u >= start_raw or u < end_raw                 # 조조(야간 걸침)
```

---

## 3단계: 예약 현황 조회 & 슬롯 점유 확인

### 디테일러 예약 조회
```sql
SELECT r.id AS reservation_id, r.detailer_id, d.name,
  r.reservation_datetime, r.estimated_time,
  ua.latitude, ua.longitude, ua.address,
  us.product_id, p.name AS product_name
FROM reservation r
JOIN detailer d ON d.id = r.detailer_id
LEFT JOIN user_service us ON us.reservation_id = r.id
LEFT JOIN product p ON p.id = us.product_id
LEFT JOIN user_address ua ON ua.id = r.address_id
WHERE r.detailer_id IN (:ids)
  AND DATE(CONVERT_TZ(r.reservation_datetime, '+00:00', '+09:00')) IN (:dates_kst)
  AND r.status IN ('CONFIRMED', 'WASHED')
  AND r.deleted_yn = 0;
```

### ⚠️ DB timezone 함정 (핵심)

**DB timezone = Asia/Seoul** → mysql2가 DATETIME 컬럼을 (물리값 - 9h) UTC로 반환.

```python
# 틀린 방법: dt_kst = mysql2_output + 9h  → 9시간 틀림
# 올바른 방법:
dt_mysql2 = datetime.fromisoformat(r['reservation_datetime'].replace('Z', '+00:00'))
dt_kst    = dt_mysql2 + timedelta(hours=18)   # +9h 보정 + 9h KST변환
hour_kst  = dt_kst.hour
```

> JSON 컬럼 내 datetime 문자열(available_times 등)은 mysql2 변환 없이 그대로라 별도 보정 불필요.

---

## 4단계: 배정 후보 선택 로직

### ⚠️ 수동 슬롯 체크 시 반드시 외부만+1h 포함 (배정 불가 판단 전 필수)

표준 슬롯(8,10,12,14,16,18)만 보면 안 됨. **디테일러가 해당 슬롯에 외부만 예약이 있으면 +1h 시간도 가능**.
- 예: 10시에 외부만 예약 있음 → **11시 리터치 배정 가능**
- 고객 희망 블록 범위(08~12, 12~18, 18~22) 내 모든 외부만 예약 시간+1 확인
- 이 체크 없이 "배정 불가" 선언하면 오진. #84 서은진(11시 가능), #87 김태정(9시 가능) 사례.

**Python 체크 패턴**:
```python
for slot in customer_slots:  # 고객 희망 범위 내 표준 슬롯
    if slot not in occupied:
        # ✅ 정규 슬롯
    elif slot in ext_only_hours:  # product.name LIKE '%외부만%'
        plus1 = slot + 1
        if plus1 not in occupied and valid_slot(plus1, s_utc, e_utc):
            # ✅ 외부만+1h
```

### 3가지 체크 순서 (모두 통과해야 후보 등록)

```python
occupied_hours = {r['hour_kst'] for r in reservations_on_date}

# ① 근무시간 체크 — 슬롯이 디테일러 근무 시간 내인지
if not valid_slot(slot_hour, det['start_utc_hour'], det['end_utc_hour']):
    continue  # 표준(10~19) 디테일러에게 08:00 배정 금지 등

# ② 슬롯 점유 체크 — 해당 시간에 이미 예약 있는지
if slot_hour not in occupied_hours:
    # ✅ 정규 슬롯 가능
    pass

# ③ 외부만+1h — 슬롯에 외부만 예약 있고 +1h도 근무시간+빈 슬롯이면 배정
elif any(r['hour_kst'] == slot_hour and '외부만' in (r['product_name'] or '')
         for r in reservations_on_date):
    retouch_hour = slot_hour + 1
    # +1h도 근무시간 체크 + 슬롯 체크 모두 통과해야 함
    if retouch_hour not in occupied_hours and valid_slot(retouch_hour, det['start_utc_hour'], det['end_utc_hour']):
        # ✅ 외부만+1h 가능
        pass
```

**holiday 제외는 2단계 SQL에서 이미 처리** — 여기까지 온 det는 이미 해당 날짜 휴가 없음 확인된 것.

**⚠️ 외부만+1h 함정 (2026-07-08 재검증 — 기준 좁힘)**: 기존 예약 종료 후 **~30분 버퍼**가 필요해, slot+1h(기존 시작+60분) 리터치는 **기존 est ≤ 30일 때만 안전**하다. est 40~60도 409 거절됨(실측: 오주영 10:00 est40→11:00 리터치 409 / 박건엽 10:00 est30→11:00 성공). "est ≤ 60이면 OK"는 낙관적이니 신뢰 말 것. est>30이면 slot+2h 또는 다른 디테일러/정규 빈슬롯으로.

### ⭐ 배정 우선순위 (2026-07-03 운영 방침 확정)

**외부만+1h 슬롯을 정규 빈슬롯보다 우선 배정한다.** 정규 빈슬롯은 신규 예약을 받을 여지로 남기고, 리터치는 이미 잡힌 외부만 예약 뒤에 붙여(=동선·슬롯 절약) 처리하는 게 낫다.

선택 순서:
1. **외부만+1h** 후보 (기존 예약 **est ≤ 30** 확인 — est 40~60은 409 거절) — 최우선
2. 없으면 **정규 빈슬롯**
3. 동점이면 원디테일러(리터치 책임 연속성) → 이른 슬롯 → 동선

```python
cands = build_candidates(...)  # 각 후보에 kind='ext1h' | 'regular'
ext1h   = [c for c in cands if c['kind']=='ext1h']
regular = [c for c in cands if c['kind']=='regular']
pool = ext1h if ext1h else regular   # 외부만+1h 우선
# pool 안에서 원디테일러 우선 → 이른 슬롯 → route_score
```

### 동선 최적화 (후보 多시)
```python
def route_score(reservations, lat, lon, hour):
    prev = max((r for r in reservations if r['hour_kst'] < hour), default=None, key=lambda r: r['hour_kst'])
    next_ = min((r for r in reservations if r['hour_kst'] > hour), default=None, key=lambda r: r['hour_kst'])
    return haversine(prev, lat, lon) + haversine(lat, lon, next_) - haversine(prev, next_)
# 낮을수록 동선 추가 적음. 예약 없으면 0.
```

---

## 5단계: API 배정

### 어드민 토큰 발급
```bash
TOKEN=$(curl -s -X POST "https://api-prod.thetrive.com/v1/auth/admin/token" \
  -H "Content-Type: application/json" \
  -d '{"username":"gobul21","password":"xkck66791!"}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])")
```

`caramel-sales-admin` JWT ≠ 이 토큰. `AdminPartnerJwtGuard`는 `role:admin` 전용.

### 배정 호출
```python
import subprocess, json

def assign(token, retouch_id, detailer_id, dt_kst_iso):
    # dt_kst_iso 예: "2026-06-22T10:00:00+09:00"
    r = subprocess.run([
        'curl','-s','-X','POST',
        f'https://api-prod.thetrive.com/v1/admin/retouches/{retouch_id}/reservation',
        '-H', f'Authorization: Bearer {token}',
        '-H', 'Content-Type: application/json',
        '-d', json.dumps({'detailerId': detailer_id, 'reservationDatetime': dt_kst_iso}),
    ], capture_output=True, text=True)
    d = json.loads(r.stdout)
    if 'retouch' in d:
        return d['retouch']['retouchReservation']['id']
    raise Exception(d.get('error', {}).get('message', '?'))
```

### API 충돌 체크 로직
- 후보 범위: KST 하루 전체(`startOf('day', Seoul)` ~ `+1day`)
- 정밀 overlap: `existing.start + estimatedTime > target.start AND existing.start < target.start + retouch_duration`
- 슬롯 비어있어도 긴 예약(60분+)이 앞에 있으면 충돌 가능

### 사전 검증 (DB)
```sql
-- 배정 전 UTC 물리값으로 직접 확인 (KST H시 = 물리값 H:00:00)
SELECT id FROM reservation
WHERE detailer_id = :id
  AND reservation_datetime = :utc_datetime   -- '2026-06-22 01:00:00' for KST 10:00
  AND status IN ('CONFIRMED','WASHED')
  AND deleted_yn = 0;
```

---

## 참조 정보

- **배정 어드민 UI**: `caramel-zero/apps/web` `/admin/retouch` (caramel-sales-admin 아님)
- **외부만 판별**: `user_service.reservation_id = reservation.id` 조인 → `product.name LIKE '%외부만%'`
- **detailer_work_schedule_rule**: `HOUR(start_time)` = UTC 물리값 시간 (mysql2 변환 없음)
- 날짜 지난 REQUESTED 건은 배정 불가 → 고객 재신청 유도
