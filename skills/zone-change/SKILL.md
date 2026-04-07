---
name: zone-change
description: "디테일러 zone 변경 (예: Z1 → Z3). Use when: zone 변경, 배정 변경, 존 변경, 셀 변경, 디테일러 존 옮기기."
---

# /zone-change — 디테일러 zone 변경

디테일러의 zone 배정을 변경한다. `detailer_work_schedule_rule` 테이블만 변경하며,
기존 규칙은 soft-delete 후 새 규칙을 INSERT한다 (API `upsertRegion` 패턴과 동일).

## 입력

- `/zone-change 강지성 Z3` — 이름 + 목표 zone
- `/zone-change 01012345678 Z3` — 전화번호 + 목표 zone
- `/zone-change` — 인자 없으면 AskUserQuestion으로 안내

## DB 쿼리 방법

- 조회: `./mysql-query.sh "SQL"` 로 실행 (워크스페이스 루트 기준)
- 쓰기(Step 7만): `./mysql-query.sh --allow-zone-change "SQL"` 로 실행
- DateTime은 UTC 저장 → KST 변환 시 `+ INTERVAL 9 HOUR`
- **이 스킬에서만** `detailer_work_schedule_rule` 테이블의 UPDATE(soft-delete)/INSERT 허용
- 다른 테이블은 절대 수정 금지

## 안전 규칙

- **hard delete(DELETE FROM) 절대 금지** — soft-delete(`SET deleted_at = NOW()`)만 사용
- `detailer`, `detailer_work_schedule`, `zone` 등 다른 테이블 수정 금지
- 모든 변경 전 반드시 사용자 확인 (Step 6)
- 실행 후 반드시 검증 (Step 7c)
- 롤백 SQL 항상 제공 (Step 7d)

## 존 목록 (참조)

| id | name |
|----|------|
| 1 | Z0 (경기 성남시) |
| 2 | Z1 (마포구/용산구) |
| 3 | Z3 (강남구/송파구) |
| 4 | Z4 (강서구/경기김포시) |
| 5 | Z5 (서초구/용산구) |
| 6 | Z6 (인천 연수구/인천 서구) |
| 7 | Z7 (경기 안양시/경기 과천시) |
| 8 | Z9 (성동구/성북구) |
| 9 | Z10 (영등포구/금천구) |
| 10 | Z12 (강남구/서초구) |
| 11 | Z14 (경기 용인시/경기 화성시) |
| 12 | Z16 (강동구/송파구) |
| 13 | Z17 (경기 고양시/경기 파주시) |

> 존 목록이 변경되었을 수 있으므로 Step 4에서 항상 DB 조회로 확인한다.

---

## 변경 프로토콜 (7단계 — 순서대로 실행, 생략 불가)

### Step 1: 입력 파싱

인자에서 디테일러 식별자(이름 또는 전화번호)와 목표 zone을 파싱한다.

- 둘 다 있으면 바로 Step 2 진행
- 하나라도 누락이면 AskUserQuestion으로 요청:
  - "어떤 디테일러의 zone을 변경할까요? (이름 또는 전화번호)"
  - "어떤 zone으로 변경할까요? (예: Z3)"

### Step 2: 디테일러 검증

```sql
SELECT d.id, d.name, d.phone, d.retired_yn,
       dss.status, dss.retired_date
FROM detailer d
LEFT JOIN detailer_supply_sheet dss
  ON dss.phone_norm = d.phone COLLATE utf8mb4_general_ci
WHERE (d.name = '{input}' OR d.phone = '{input}')
  AND d.retired_yn = 0
  AND d.deleted_yn = 0;
```

**검증 규칙**:
- **결과 0건**: 유사 이름 검색 시도 (`WHERE d.name LIKE '%{입력}%' AND d.retired_yn = 0 AND d.deleted_yn = 0`). 후보가 있으면 제안, 없으면 "해당 디테일러를 찾을 수 없습니다" 중단
- **결과 2건 이상 (동명이인)**: 이름 + 전화번호 + id 목록 표시 → AskUserQuestion으로 선택
- **`retired_yn = 1`**: "퇴사한 디테일러입니다" 중단
- **`dss.status = '파견'`**: "파견 상태 디테일러입니다. zone 변경이 적절한지 확인하세요." → AskUserQuestion으로 계속 여부 확인
- **`dss.status` ∉ ('현직', '파견')**: "현직이 아닌 디테일러입니다 (상태: {status})" 중단

### Step 3: 현재 zone + 활성 스케줄 조회

```sql
SELECT dws.id AS schedule_id, dws.effective_from, dws.effective_to,
       dwsr.id AS rule_id, dwsr.day_of_week,
       DATE_FORMAT(dwsr.start_time, '%Y-%m-%d %H:%i:%s') AS start_time_raw,
       DATE_FORMAT(dwsr.end_time, '%Y-%m-%d %H:%i:%s') AS end_time_raw,
       TIME(dwsr.start_time) AS start_time_display,
       TIME(dwsr.end_time) AS end_time_display,
       dwsr.zone_id, z.name AS zone_name,
       dwsr.service_region_group_id
FROM detailer_work_schedule dws
JOIN detailer_work_schedule_rule dwsr ON dwsr.schedule_id = dws.id
LEFT JOIN zone z ON z.id = dwsr.zone_id
WHERE dws.detailer_id = {detailer_id}
  AND dws.effective_from <= NOW() AND dws.effective_to >= NOW()
  AND dwsr.deleted_at IS NULL
ORDER BY FIELD(dwsr.day_of_week, 'MON','TUE','WED','THU','FRI','SAT','SUN');
```

**검증 규칙**:
- **활성 스케줄 없음** (결과 0건): "활성 스케줄이 없습니다. 개발팀에 문의하세요." 중단
- **zone_id가 전부 NULL** (legacy): "이 디테일러는 zone 기반이 아닙니다 (service_region_group 사용 중). 개발팀에 zone 전환을 요청하세요." 중단
- **여러 zone에 배정** (겸임): 요일별 zone 표시 + AskUserQuestion으로 "어떤 요일의 zone을 변경할까요?" (전체/평일/주말/특정요일) 선택

**출력 — 현재 배정 상태**:

```
## 현재 배정 상태

디테일러: {name} (ID: {id})
상태: {status}
스케줄: #{schedule_id} ({effective_from} ~ {effective_to})

| 요일 | 근무시간(KST) | 현재 zone |
|------|--------------|---------|
| MON  | {HH:MM}~{HH:MM} | {zone_name} |
| TUE  | {HH:MM}~{HH:MM} | {zone_name} |
| ...  | ...          | ...     |
```

> KST 근무시간 표시: start_time_display + 9시간, end_time_display + 9시간으로 변환

**중요**: 이 단계에서 조회한 `rule_id`, `schedule_id`, `start_time_raw`, `end_time_raw`, `day_of_week`를
이후 Step 7에서 사용한다. 반드시 메모해둘 것.

### Step 4: 목표 zone 검증

```sql
SELECT id, name FROM zone
WHERE name LIKE '%{target}%' OR name LIKE '{target}%'
ORDER BY name;
```

**검증 규칙**:
- **매칭 1건**: 해당 zone 확인 표시
- **매칭 0건**: "해당 zone을 찾을 수 없습니다." + 전체 zone 목록 표시 + AskUserQuestion으로 재질문
- **매칭 2건 이상 (모호)**: 후보 목록 표시 + AskUserQuestion으로 선택
- **현재 zone = 목표 zone**: "이미 해당 zone에 배정되어 있습니다 ({zone_name})." 중단

### Step 5: 당일 예약 확인 + 전/후 비교

**당일 예약 확인** (경고용, 중단하지는 않음):

```sql
SELECT r.id, r.status,
       r.reservation_datetime + INTERVAL 9 HOUR AS reservation_kst
FROM reservation r
WHERE r.detailer_id = {detailer_id}
  AND DATE(r.reservation_datetime + INTERVAL 9 HOUR) = CURDATE()
  AND r.status IN ('RESERVED', 'ON_THE_WAY', 'ARRIVED', 'WASHING')
  AND r.deleted_yn = 0;
```

당일 예약이 있으면 경고:
```
주의: 오늘 진행 중인 예약이 {N}건 있습니다.
zone 변경은 향후 배정에 영향을 줍니다. 오늘 예약에는 영향 없습니다.
```

**전/후 비교 표시**:

```
## 변경 요약

디테일러: {name} (ID: {id}, schedule: #{schedule_id})

| 요일 | 근무시간(KST) | 현재 zone | → 변경 후 zone |
|------|--------------|---------|-------------|
| MON  | {HH:MM}~{HH:MM} | {현재_zone_name} | {목표_zone_name} |
| TUE  | {HH:MM}~{HH:MM} | {현재_zone_name} | {목표_zone_name} |
| ...  | ...          | ...       | ...         |

변경되는 규칙: {N}개 (soft-delete {N}개 + 새로 생성 {N}개)
```

### Step 6: 확인 게이트 (필수)

AskUserQuestion으로 확인. 선택지:
- "실행" — 변경 진행
- "취소" — 중단

**사용자가 "취소"하면 즉시 중단. "실행"에만 진행.**

### Step 7: 실행 + 검증 + 롤백 안내

> **중요**: Step 7의 모든 UPDATE/INSERT 쿼리는 반드시 `./mysql-query.sh --allow-zone-change "SQL"` 형태로 실행한다.
> 플래그 없이 실행하면 가드레일에 의해 차단된다.

#### Step 7a: 기존 규칙 soft-delete

```sql
UPDATE detailer_work_schedule_rule
SET deleted_at = NOW(), modified_at = NOW()
WHERE id IN ({old_rule_ids})
  AND deleted_at IS NULL;
```

- `{old_rule_ids}` = Step 3에서 조회한 `rule_id` 목록 (콤마 구분)
- 실행 후 결과의 affectedRows 확인
- **affectedRows ≠ 예상 개수이면**: "soft-delete 결과가 예상과 다릅니다 (예상: {N}, 실제: {M}). INSERT를 진행하지 않습니다." 경고 + 복원 SQL 안내 + 중단

#### Step 7b: 새 규칙 INSERT

Step 3에서 조회한 각 규칙의 `day_of_week`, `start_time_raw`, `end_time_raw`를 그대로 복사:

```sql
INSERT INTO detailer_work_schedule_rule
  (schedule_id, day_of_week, start_time, end_time, zone_id,
   service_region_group_id, created_at, modified_at)
VALUES
  ({schedule_id}, '{day_of_week_1}', '{start_time_raw_1}', '{end_time_raw_1}', {new_zone_id}, NULL, NOW(), NOW()),
  ({schedule_id}, '{day_of_week_2}', '{start_time_raw_2}', '{end_time_raw_2}', {new_zone_id}, NULL, NOW(), NOW()),
  ...;
```

**핵심 규칙**:
- `start_time_raw`/`end_time_raw`는 Step 3의 `DATE_FORMAT` 결과를 그대로 사용 (예: `'1970-01-01 01:00:00'`)
- 각 요일의 시간을 개별적으로 복사 (요일마다 시간이 다를 수 있음)
- `service_region_group_id`는 항상 `NULL`
- 디폴트값 사용 금지

#### Step 7c: 검증 쿼리

```sql
SELECT dwsr.id, dwsr.day_of_week,
       TIME(dwsr.start_time) AS start_time, TIME(dwsr.end_time) AS end_time,
       z.name AS zone_name
FROM detailer_work_schedule_rule dwsr
JOIN zone z ON z.id = dwsr.zone_id
WHERE dwsr.schedule_id = {schedule_id}
  AND dwsr.deleted_at IS NULL
ORDER BY FIELD(dwsr.day_of_week, 'MON','TUE','WED','THU','FRI','SAT','SUN');
```

**검증 항목**:
- 새 규칙 개수 = 기존 규칙 개수 → 일치해야 함
- 모든 zone_id = 목표 zone_id → 일치해야 함
- day_of_week + start/end_time 보존됨 → 일치해야 함
- **불일치 시**: 경고 + 롤백 SQL 즉시 안내

#### Step 7d: 결과 + 롤백 안내

```
## 변경 완료

{name}의 zone이 {현재_zone_name} → {목표_zone_name}로 변경되었습니다.

### 새 규칙
| 요일 | 근무시간(KST) | zone |
|------|--------------|------|
| MON  | {HH:MM}~{HH:MM} | {목표_zone_name} |
| ...  | ...          | ...  |

### 롤백이 필요한 경우
아래 명령어를 순서대로 실행하면 이전 상태로 되돌릴 수 있습니다:

./mysql-query.sh --allow-zone-change "UPDATE detailer_work_schedule_rule SET deleted_at = NOW() WHERE id IN ({new_rule_ids})"

./mysql-query.sh --allow-zone-change "UPDATE detailer_work_schedule_rule SET deleted_at = NULL WHERE id IN ({old_rule_ids})"
```

- `{new_rule_ids}` = Step 7c 검증 쿼리에서 확인한 새 규칙 ID 목록
- `{old_rule_ids}` = Step 7a에서 soft-delete한 기존 규칙 ID 목록

---

## 엣지 케이스 요약

| 시나리오 | 감지 시점 | 대응 |
|---------|----------|------|
| 이름 오타 / 0건 | Step 2 | LIKE 검색 후 제안 |
| 동명이인 | Step 2 | 목록 → 선택 |
| 퇴사/비활성 | Step 2 | 중단 |
| 파견 상태 | Step 2 | 경고 + 확인 |
| 활성 스케줄 없음 | Step 3 | 중단 |
| legacy (zone 미전환) | Step 3 | 중단 |
| 겸임 (복수 zone) | Step 3 | 범위 선택 |
| 존재하지 않는 zone | Step 4 | 목록 표시 + 재질문 |
| 현재 = 목표 zone | Step 4 | 중단 |
| 당일 예약 있음 | Step 5 | 경고 (중단 안 함) |
| affected rows 불일치 | Step 7a | 경고 + 중단 |
| INSERT 실패 | Step 7b | 에러 + 복원 SQL |
| 검증 실패 | Step 7c | 경고 + 롤백 SQL |
