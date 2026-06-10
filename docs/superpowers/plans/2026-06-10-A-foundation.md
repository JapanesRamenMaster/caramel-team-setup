# 스킬 카탈로그 — Plan A: Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 팀 공용 스킬 프론트매터 표준을 정의하고 기존 11개 스킬에 적용한다.

**Architecture:** `caramel-team-setup/skills/` 내 각 SKILL.md에 거버넌스 프론트매터(scope, side-effects, owner, requires, disable-model-invocation)를 추가. `incoming/` 폴더를 만들어 제출 대기 경로로 설정. 검증 스크립트로 표준 준수 여부 확인.

**Tech Stack:** Bash, YAML 프론트매터, GitHub (caramel-team-setup 레포)

---

## 파일 구조

```
caramel-team-setup/
  skills/
    amplitude-chart/SKILL.md    → 프론트매터 추가
    cbr-query/SKILL.md          → 프론트매터 추가
    clean-multi-reservations/SKILL.md → 프론트매터 추가 (side-effects: db-write, notification)
    data-learn/SKILL.md         → 프론트매터 신규 추가 (현재 없음)
    experiment-doc/SKILL.md     → 프론트매터 추가
    feedback/SKILL.md           → 프론트매터 추가
    slides/SKILL.md             → 프론트매터 추가
    ticket-audit/SKILL.md       → 프론트매터 추가
    writing/SKILL.md            → 프론트매터 추가
    zone-assignment/SKILL.md    → 프론트매터 추가
    zone-change/SKILL.md        → 프론트매터 추가 (side-effects: db-write)
  incoming/
    .gitkeep                    → 신규 생성
    README.md                   → 제출 가이드 신규 생성
  docs/
    FRONTMATTER_STANDARD.md     → 표준 문서 신규 생성
  tools/
    validate-skill.sh           → 검증 스크립트 신규 생성
```

---

### Task 1: 프론트매터 표준 문서 작성

**Files:**
- Create: `docs/FRONTMATTER_STANDARD.md`

- [ ] **Step 1: 표준 문서 작성**

```markdown
# 팀 스킬 프론트매터 표준

팀 공용 스킬(`scope: team`)은 아래 프론트매터를 포함해야 한다.
AI 파이프라인이 제출된 스킬을 자동으로 보강하지만, 표준을 알면 직접 작성할 수 있다.

## 필수 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `name` | string | 스킬 이름 (디렉토리명과 동일) |
| `description` | string | 한 줄 설명 + 트리거 키워드 |
| `scope` | `team` \| `personal` | `team`이면 카탈로그에 노출 |
| `side-effects` | list | 비가역 액션 목록 (없으면 `[]`) |
| `owner` | string | 관리자 GitHub username |

## 선택 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `requires` | list | 없으면 실행 불가한 환경변수/도구 |
| `disable-model-invocation` | bool | `true`면 AI가 자동 실행 불가 |
| `tags` | list | 카탈로그 필터용 태그 |
| `version` | string | semver |

## side-effects 허용값

- `db-write` — DB 데이터 변경 (INSERT/UPDATE/DELETE)
- `db-read` — DB 조회만 (부작용 없음)
- `notification` — 카카오 알림톡/문자 발송
- `slack-send` — 슬랙 메시지 발송
- `file-write` — 로컬 파일 생성/수정
- `deploy` — 배포 실행
- `api-call` — 외부 API 호출 (읽기 전용)
- `api-call-write` — 외부 API 쓰기 호출

## 예시

\`\`\`yaml
---
name: clean-multi-reservations
description: |
  동일차량 다중예약 정리. 슬랙 알림 확인 → 취소 대상 분석 → 사용자 승인 후 취소 실행.
  Use when: "다중 예약 정리", "중복 예약 정리", "clean multi".
scope: team
owner: sungjiwon
side-effects:
  - db-write
  - notification
disable-model-invocation: true
tags:
  - 예약
  - 고객관리
---
\`\`\`

## 규칙

1. `side-effects`가 `notification` 또는 `db-write`를 포함하면 `disable-model-invocation: true` 필수
2. `scope: team`인 스킬은 반드시 `owner` 명시
3. 부작용이 전혀 없으면 `side-effects: []` 명시 (누락과 구분)
```

- [ ] **Step 2: 커밋**

```bash
cd ~/.caramel-team-setup
git add docs/FRONTMATTER_STANDARD.md
git commit -m "docs: 팀 스킬 프론트매터 표준 문서 추가"
```

---

### Task 2: 검증 스크립트 작성

**Files:**
- Create: `tools/validate-skill.sh`

- [ ] **Step 1: 스크립트 작성**

```bash
#!/usr/bin/env bash
# 팀 스킬 프론트매터 표준 검증 스크립트
# 사용: ./tools/validate-skill.sh skills/zone-change/SKILL.md

set -e

FILE="${1}"
ERRORS=0

if [ -z "$FILE" ]; then
  echo "Usage: validate-skill.sh <path-to-SKILL.md>"
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "❌ 파일 없음: $FILE"
  exit 1
fi

check_field() {
  local field="$1"
  local label="$2"
  if ! grep -q "^${field}:" "$FILE" && ! grep -q "^${field}: " "$FILE"; then
    echo "❌ 필수 필드 누락: ${label} (${field}:)"
    ERRORS=$((ERRORS + 1))
  else
    echo "✅ ${label}"
  fi
}

echo "검증 중: $FILE"
echo "---"

# scope: team인 경우에만 팀 스킬 표준 적용
if grep -q "^scope: team" "$FILE"; then
  check_field "name" "name"
  check_field "description" "description"
  check_field "scope" "scope"
  check_field "owner" "owner"
  check_field "side-effects" "side-effects"

  # side-effects에 db-write 또는 notification 있으면 disable-model-invocation 필수
  if grep -qE "^\s+- (db-write|notification|slack-send|deploy)" "$FILE"; then
    if ! grep -q "disable-model-invocation: true" "$FILE"; then
      echo "❌ 비가역 side-effect 있음 → disable-model-invocation: true 필수"
      ERRORS=$((ERRORS + 1))
    else
      echo "✅ disable-model-invocation: true (비가역 액션 잠금)"
    fi
  fi
else
  echo "ℹ️  scope: team 아님 — 팀 스킬 표준 검사 생략"
fi

echo "---"
if [ "$ERRORS" -eq 0 ]; then
  echo "✅ 통과"
  exit 0
else
  echo "❌ ${ERRORS}개 오류 발견"
  exit 1
fi
```

- [ ] **Step 2: 실행 권한 부여 및 테스트**

```bash
chmod +x ~/.caramel-team-setup/tools/validate-skill.sh

# 현재 프론트매터 없는 스킬로 실패 확인
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/zone-change/SKILL.md
```

예상 출력: `ℹ️  scope: team 아님 — 팀 스킬 표준 검사 생략` (아직 scope 없으니)

- [ ] **Step 3: 커밋**

```bash
cd ~/.caramel-team-setup
git add tools/validate-skill.sh
git commit -m "feat: 팀 스킬 프론트매터 검증 스크립트 추가"
```

---

### Task 3: zone-change 프론트매터 마이그레이션

**Files:**
- Modify: `skills/zone-change/SKILL.md` (line 1-4)

> 비가역 DB 쓰기 있음 → disable-model-invocation: true 필수

- [ ] **Step 1: 프론트매터 교체**

기존 `---` ~ `---` 사이를:
```yaml
---
name: zone-change
description: "디테일러 zone 변경 (예: Z1 → Z3). Use when: zone 변경, 배정 변경, 존 변경, 셀 변경, 디테일러 존 옮기기."
scope: team
owner: juseong
side-effects:
  - db-write
disable-model-invocation: true
tags:
  - 디테일러
  - zone
---
```

- [ ] **Step 2: 검증**

```bash
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/zone-change/SKILL.md
```

예상 출력: `✅ 통과`

- [ ] **Step 3: 커밋**

```bash
cd ~/.caramel-team-setup
git add skills/zone-change/SKILL.md
git commit -m "feat: zone-change 프론트매터 표준 적용"
```

---

### Task 4: clean-multi-reservations 프론트매터 마이그레이션

**Files:**
- Modify: `skills/clean-multi-reservations/SKILL.md`

> 알림톡 발송 + DB 쓰기 → disable-model-invocation: true 필수

- [ ] **Step 1: 프론트매터 교체**

```yaml
---
name: clean-multi-reservations
description: |
  동일차량 다중예약 정리. 슬랙 알림 확인 → 취소 대상 분석 → 사용자 승인 후 취소 실행.
  Use when: "다중 예약 정리", "중복 예약 정리", "clean multi", "clean-multi-reservations", "예약 정리".
scope: team
owner: sungjiwon
side-effects:
  - db-write
  - notification
disable-model-invocation: true
tags:
  - 예약
  - 고객관리
---
```

- [ ] **Step 2: 검증**

```bash
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/clean-multi-reservations/SKILL.md
```

예상: `✅ 통과`

- [ ] **Step 3: 커밋**

```bash
cd ~/.caramel-team-setup
git add skills/clean-multi-reservations/SKILL.md
git commit -m "feat: clean-multi-reservations 프론트매터 표준 적용"
```

---

### Task 5: zone-assignment 프론트매터 마이그레이션

**Files:**
- Modify: `skills/zone-assignment/SKILL.md`

> 읽기/분석 전용 (DB 쓰기 없음)

- [ ] **Step 1: 프론트매터 교체**

```yaml
---
name: zone-assignment
description: "디테일러를 어느 zone에 배정할지 결정하는 분석 스킬. Use when: 신입 디테일러 zone 배정, 임시 파견 배치, 디테일러 N명 어디 보낼지, 디테일러 zone 추천, 어떤 동네에 넣을까, '디테일러 배정', 'zone 배정', '존 배정'. zone-change(DB 실제 변경)와 다름 — 이건 결정 단계까지만."
scope: team
owner: juseong
side-effects:
  - db-read
tags:
  - 디테일러
  - zone
---
```

- [ ] **Step 2: 검증 + 커밋**

```bash
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/zone-assignment/SKILL.md
cd ~/.caramel-team-setup && git add skills/zone-assignment/SKILL.md && git commit -m "feat: zone-assignment 프론트매터 표준 적용"
```

---

### Task 6: cbr-query 프론트매터 마이그레이션

**Files:**
- Modify: `skills/cbr-query/SKILL.md`

- [ ] **Step 1: 프론트매터 교체**

기존 name/version/description 아래에 추가:
```yaml
---
name: cbr-query
version: 1.0.0
description: |
  CBR(Caramel Business Review) Grafana 대시보드용 분석 쿼리 생성.
  세차당 매출, 세차 완료수, 디테일러 생산성, 옵션 추가율, 전환율 등.
  Use when: "세차당 매출 쿼리", "CBR 쿼리 만들어줘", "Grafana 패널 추가".
scope: team
owner: juseong
side-effects:
  - db-read
tags:
  - 분석
  - Grafana
  - CBR
---
```

- [ ] **Step 2: 검증 + 커밋**

```bash
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/cbr-query/SKILL.md
cd ~/.caramel-team-setup && git add skills/cbr-query/SKILL.md && git commit -m "feat: cbr-query 프론트매터 표준 적용"
```

---

### Task 7: amplitude-chart 프론트매터 마이그레이션

**Files:**
- Modify: `skills/amplitude-chart/SKILL.md`

- [ ] **Step 1: 프론트매터 교체**

```yaml
---
name: amplitude-chart
version: 1.0.0
description: |
  앰플리튜드 퍼널/세그멘테이션 차트 생성. 실험 문서 또는 구두 설명 기반.
  Triggers: "앰플리튜드 차트", "amplitude chart", "차트 만들어", "퍼널 차트", "대시보드 차트".
scope: team
owner: juseong
side-effects:
  - api-call-write
tags:
  - 분석
  - Amplitude
---
```

- [ ] **Step 2: 검증 + 커밋**

```bash
~/.caramel-team-setup/tools/validate-skill.sh ~/.caramel-team-setup/skills/amplitude-chart/SKILL.md
cd ~/.caramel-team-setup && git add skills/amplitude-chart/SKILL.md && git commit -m "feat: amplitude-chart 프론트매터 표준 적용"
```

---

### Task 8: 나머지 6개 스킬 마이그레이션 (data-learn, experiment-doc, feedback, slides, ticket-audit, writing)

**Files:**
- Modify: 각 `skills/*/SKILL.md`

> data-learn은 현재 프론트매터 없음 — 신규 추가

- [ ] **Step 1: data-learn (프론트매터 신규)**

파일 상단에 추가:
```yaml
---
name: data-learn
description: |
  데이터 작업 완료 후 새로 알게 된 DB/쿼리 지식을 레퍼런스 문서에 반영.
  Use when: "data-learn", 데이터 작업 마무리 후, 쿼리 작업 끝나고 문서 반영할 때.
scope: team
owner: juseong
side-effects:
  - file-write
tags:
  - 분석
  - 문서화
---
```

- [ ] **Step 2: experiment-doc**

기존 프론트매터에 추가:
```yaml
scope: team
owner: juseong
side-effects:
  - api-call-write
tags:
  - 실험
  - 제품
```

- [ ] **Step 3: feedback**

```yaml
scope: team
owner: juseong
side-effects: []
tags:
  - 팀워크
  - 문서
```

- [ ] **Step 4: slides**

```yaml
scope: team
owner: juseong
side-effects:
  - file-write
tags:
  - 슬라이드
  - 발표
```

- [ ] **Step 5: ticket-audit**

```yaml
scope: team
owner: juseong
side-effects:
  - db-read
tags:
  - 구독
  - 세차권
  - 고객관리
```

- [ ] **Step 6: writing**

```yaml
scope: team
owner: juseong
side-effects: []
tags:
  - 문서
  - 글쓰기
```

- [ ] **Step 7: 전체 검증**

```bash
for skill in ~/.caramel-team-setup/skills/*/SKILL.md; do
  echo "=== $skill ==="
  ~/.caramel-team-setup/tools/validate-skill.sh "$skill"
done
```

예상: 11개 전부 `✅ 통과`

- [ ] **Step 8: 커밋**

```bash
cd ~/.caramel-team-setup
git add skills/data-learn/SKILL.md skills/experiment-doc/SKILL.md skills/feedback/SKILL.md \
        skills/slides/SKILL.md skills/ticket-audit/SKILL.md skills/writing/SKILL.md
git commit -m "feat: 나머지 6개 스킬 프론트매터 표준 적용"
```

---

### Task 9: incoming/ 폴더 및 README 생성

**Files:**
- Create: `incoming/.gitkeep`
- Create: `incoming/README.md`

- [ ] **Step 1: 폴더 및 파일 생성**

`incoming/README.md`:
```markdown
# 스킬 제출 대기 폴더

이 폴더에 스킬 파일을 올리면 AI가 자동으로 프론트매터를 보강해 `skills/`로 이동하는 PR을 만들어줍니다.

## 제출 방법

### 방법 1: Slack
`#caramel_스킬공유` 채널에 md 파일을 첨부하거나 내용을 붙여넣으면 됩니다.

### 방법 2: GitHub
이 폴더(`incoming/`)에 `your-skill-name.md` 파일을 push하면 자동으로 처리됩니다.

### 방법 3: 카탈로그 사이트
사이트의 `/submit` 페이지에서 양식을 작성하면 됩니다.

## 파일 형식

스킬 파일은 최소한 스킬 내용(본문)만 있으면 됩니다. 프론트매터는 AI가 채워줍니다.
직접 프론트매터를 작성하고 싶으면 `docs/FRONTMATTER_STANDARD.md`를 참고하세요.

## 처리 흐름

1. 파일 감지 → Claude Opus가 본문 분석
2. 프론트매터 자동 생성 (side-effects, requires 등)
3. `skills/{name}/SKILL.md`로 이동하는 PR 생성
4. 맹주성님 승인 → merge → 카탈로그 자동 반영
```

- [ ] **Step 2: 커밋**

```bash
cd ~/.caramel-team-setup
touch incoming/.gitkeep
git add incoming/.gitkeep incoming/README.md
git commit -m "feat: incoming/ 폴더 및 제출 가이드 추가"
```

---

### Task 10: PR 생성 및 머지

- [ ] **Step 1: PR 생성**

```bash
cd ~/.caramel-team-setup
git push origin docs/skill-catalog-spec
gh pr create \
  --title "feat: 스킬 카탈로그 Foundation — 프론트매터 표준 + 마이그레이션" \
  --body "$(cat <<'EOF'
## 변경 내용

- 팀 스킬 프론트매터 표준 정의 (`docs/FRONTMATTER_STANDARD.md`)
- 검증 스크립트 추가 (`tools/validate-skill.sh`)
- 기존 11개 팀 스킬 프론트매터 마이그레이션 완료
- `incoming/` 폴더 및 제출 가이드 추가

## 검증

전체 스킬 validate-skill.sh 통과 확인

🤖 Generated with Claude Code
EOF
)"
```

- [ ] **Step 2: PR 확인 후 머지**

```bash
gh pr merge --squash --delete-branch
```
