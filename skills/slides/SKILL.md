---
name: slides
version: 5.2.0
description: |
  카라멜 슬라이드(Product Weekly · 타운홀 · 외부 미팅 · 일반 덱) 작업의 진입점.
  HTML canonical (`~/caramel-decks` repo). Claude Code(이 환경)에서 brief 작성 → **HTML 덱 직접 빌드** → 렌더 검증 → 보여주기까지 한 자리에서 끝낸다. (Claude.ai 핸드오프는 fallback)
  사용자 요청에서 주제·청중·발표일·핵심 메시지 인터뷰 → 자료 수집 → brief → 직접 빌드 → 겹침 검증 → 사용자 피드백 루프.
  Use when: "슬라이드", "장표", "발표 자료", "프레젠테이션", "pptx", "PPT", "피피티", "slides", "덱", "deck", "Product Weekly", "외부 미팅 슬라이드".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
  - WebFetch
  - mcp__claude_ai_Linear__list_issues
  - mcp__claude_ai_Linear__list_projects
  - mcp__claude_ai_Linear__get_project
  - mcp__claude_ai_Slack__slack_search_public_and_private
  - mcp__claude_ai_Slack__slack_read_channel
  - mcp__google-sheets__get_sheet_data
---

# /slides — 카라멜 덱 (brief → 직접 빌드 → 검증)

**산출 형식은 항상 HTML canonical (caramel-decks repo).** PPTX는 만들지 않는다. 공유가 필요하면 HTML에서 export.

**이 스킬은 brief만 쓰고 끝나지 않는다 — Claude Code(이 환경)에서 HTML 덱을 직접 빌드하고, headless chrome로 렌더해 검증하고, 사용자에게 보여주고 피드백으로 고치는 것까지 한 자리에서 한다.** caramel-decks의 디자인 시스템(`styles.css`)·레이아웃 마스터(`slide-master/` 24종)·누적 원칙(`CLAUDE.md §10`)이 다 갖춰져 있어 직접 빌드가 가능하다. Claude.ai 슬라이드 환경 핸드오프는 *fallback*(아래 Phase 6)일 뿐이다.

한국어로 소통한다.

---

## 절대 규칙

1. **HTML canonical 외 다른 형식 만들지 않는다.** PPTX/Keynote/Google Slides 다 거절. "PPT로 만들어줘"라고 와도 "산출은 HTML이고 공유 시 export"로 안내.
2. **이 스킬에서 .html을 직접 빌드한다.** (옛 버전은 brief까지가 끝이었으나 이제 직접 빌드가 기본.) brief는 콘텐츠 명세일 뿐, 산출은 완성된 .html이다.
3. **마스터를 살벌히 따른다 (§10.3 원칙 16, 최우선).** 모든 슬라이드는 `slide-master/`의 레이아웃 중 하나에 매핑. 차트·타임라인·인덱스·KPI 등 그래픽도 **해당 마스터 PDF를 `pdftoppm`으로 렌더해서 직접 보고 1:1 복제**한다. 콘텐츠가 많으면 축약할지언정 레이아웃을 새로 발명하지 않는다. "볼드함"은 안 쓰던 마스터(차트·타임라인)를 꺼내 쓰는 데서 나온다 — 임의 디자인이 아니라.
   - **그래픽 마커는 라벨과 같은 그리드에 정렬 (§10.4 원칙 23).** 타임라인 점·막대·축 눈금은 라벨/텍스트와 **동일한 `grid-template-columns`** 안에 둔다. 마커를 `calc(n/m * 100%)`(선 진행 좌표 0·⅓·⅔·1)로 잡으면 컬럼 좌표(0·¼·½·¾)와 어긋나 점이 라벨 위에 안 온다 — 레퍼런스 타임라인에도 이 버그가 있으니, 복제 시 마커-라벨 정렬을 직접 렌더해 점검하고 같은 그리드로 옮긴다.
4. **caramel-decks `CLAUDE.md` §10 전부 + `layouts.md` + `styles.css`를 빌드 전 반드시 Read.** §10.1~10.3에 라운드별 학습 원칙(배경 규율·뱃지/카드 단일스펙·수직그리드·hollow 금지·선언 액자금지·수치 정직성 등)이 누적돼 있다. 전부 지킨다.
5. **산출 직전 전 슬라이드 렌더 → 겹침/잘림 전수 점검은 필수 게이트 (§10.3 원칙 22).** 통과 못 하면 미완.
6. **`/townhall`은 Phase 1-4까지 자체 수집 → 이 스킬의 brief·빌드 단계로 진입한다.**
7. **빌드 세션은 슬라이드 이미지를 직접 Read하지 않는다.** 렌더 PNG를 메인이 직접 보면 토큰이 폭증하고 한 세션 누적 이미지 한도에 걸린다(실제 발생). **렌더+육안 검수·평가는 항상 서브에이전트가 하고, 메인은 텍스트 보고(겹침 목록·점수·근본원인)만 회수**한다. 메인 컨텍스트에 슬라이드 이미지를 올리지 않는다.

---

## 6단계 워크플로우

### Phase 1 — 인터뷰 (`AskUserQuestion`)

사용자가 던진 메시지에서 이미 답이 보이는 항목은 **묻지 않는다.** 비어있는 것만 한 번에 묶어 질문.

확보해야 하는 핵심 6개:

| 항목 | 예 |
|---|---|
| 덱 이름 | "Product Weekly 260504" / "[덱이름]" |
| 종류 | weekly / 타운홀 / 외부 미팅 / 기타 |
| 청중 | 제품팀 / 전사 / 투자자 / 파트너 |
| 발표일 | 2026-05-04 (절대 날짜로 변환) |
| One-liner | 청중이 한 줄로 가져가야 할 것 |
| 분량 가이드 | "자유" 또는 "약 N장" |

부가 항목(없으면 비워두면 됨): 발표자, 톤, speaker notes 필요 여부.

---

### Phase 2 — 자료 수집

사용자가 메시지·이미지로 준 자료가 1차 소스. 부족분만 보강:

- **DB 수치**: `~/claude/mysql-query.sh "SQL"`. 첫 쿼리 전 `~/claude/QUERY_REFERENCE.md` Read 필수.
- **Linear**: 이슈/프로젝트 (sub-issues 카운트, 라벨 분포 등)
- **Slack**: 최근 컨텍스트 (캠페인 회고, 인시던트 등). 승리는 `#승리` 채널 우선(townhall 규칙).
- **Sheets**: 트라이브 프로젝션, KPI 시트
- **첨부 PDF/이미지**: 내용 직접 파싱. brief 본문에 인용 끌어오기. (§10.1 원칙 1)

자료가 많고 신뢰도 다양하면 **신뢰도 표시 필수**: 확정 / 가설 / 단일 데이터 / partial. 예상치는 "예상", 목표치는 "목표" 명시(§10.3 원칙 21).

---

### Phase 3 — brief.md 작성

1. 템플릿 읽기: `~/caramel-decks/briefs/_template.md`
2. 파일 경로: `~/caramel-decks/briefs/<덱-슬러그>.md` (한글 제목 OK, 공백 허용)
3. 채울 섹션: 메타(6핵심) · one-liner · 핵심 발견/데이터(무엇/데이터/출처/신뢰도) · 액션 표(P0/P1/P2) · 제안 슬라이드 흐름(`# / 내용 / 레이아웃 / 메모`) · 제외·주의 · 첨부·링크 · 미해결.

#### 슬라이드 흐름 짤 때
- **첫 장 = 표지, 끝 장 = 인사** (다크 배경)
- **1슬라이드 = 1메시지.** 우겨넣지 말 것.
- **데이터는 시각화 후보를 명시** (§10.3 원칙 17): 추이→막대(9-x), before/after→세로막대 비교, 과정→타임라인(11-x), 비교→차트(8-x). 단 빌드는 마스터 차트 레이아웃을 충실히.
- 레이아웃은 `slide-master/` 24종 중에서만 고른다. 텍스트 많은 특수 슬라이드만 사용자 명시 허용 시 `12. 자유 변형`.

---

### Phase 4 — 직접 빌드 (이 환경에서 .html 생성)

1. **시스템 읽기**: `caramel-decks/CLAUDE.md`(§10 전부) · `layouts.md` · `styles.css` · `slide-master/` 파일명 목록 · 기존 덱 하나(`*.html`)를 구조 레퍼런스로.
2. **매핑 초안 → confirm**: brief의 슬라이드 흐름을 마스터 24종에 매핑한 표를 사용자에게 먼저 보여주고 확인받는다. (어디에도 안 맞고 자유변형이 필요하면 그때 명시 확인.)
3. **빌드**: ⚠️ **반드시 `git fetch origin` 후 `origin/main`에서 작업한다.** 로컬 `~/caramel-decks` main은 stale일 수 있다(과거 lineage 갈림 → `slide-master/`·`layouts.md` 누락 사례 있음). **로컬 main에서 바로 빌드하지 말 것** — slide-master 없으면 마스터 복제가 불가해 죽도밥도 안 된다. fresh worktree로:
   ```bash
   git -C ~/caramel-decks fetch origin
   git -C ~/caramel-decks worktree add /tmp/deck-wt origin/main
   # /tmp/deck-wt 에 slide-master/ 25개 있는지 확인 후 여기서 빌드
   ```
   여기서 `<덱 이름>.html` 생성.
   - 각 슬라이드 = `<section data-screen-label="NN 라벨">`, `<deck-stage>` 안, 1920×1080.
   - **쓰는 마스터마다 그 PDF를 `pdftoppm -png -r 120 -singlefile "slide-master/<이름>.pdf" /tmp/m`로 렌더해 Read하고 여백·정렬·축·바·숫자 위치를 그대로 복제** (§10.3 원칙 16).
   - §10 전부 적용: 다크는 표지·인사+임팩트 1~2장만(18) · 뱃지/카드 단일스펙(19) · 라이트 수직그리드·hollow 금지(20) · 선언 액자금지+수치 정직성(21) · 24px floor · 한국어 word-break: keep-all.
   - 분량 많으면 Sonnet 서브에이전트(`Agent`, model sonnet)에 슬라이드별 명세를 주고 위임 가능. 결과는 이 스킬이 검증.

---

### Phase 5 — 렌더 검증 + 보여주기 (필수 게이트 + 피드백 루프)

1. **렌더 (메인, 이미지 Read 없이)**: headless chrome로 PDF화 → pdftoppm로 PNG. **PDF/PNG를 만들기만 하고 메인이 Read하지 않는다** (파일 생성은 토큰 안 듦, Read가 토큰을 먹는다).
   ```bash
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf=/tmp/deck.pdf "file://<HTML 절대경로>"
   pdftoppm -png -r 90 /tmp/deck.pdf /tmp/d/s        # 슬라이드당 1장
   ```
2. **겹침/잘림 전수 점검 (게이트, §10.3 원칙 22) — 검수 서브에이전트에 위임**: 평가자 서브에이전트(`Agent`)에 `/tmp/deck.pdf`(또는 `/tmp/d/s-*.png`) 경로를 주고 **"전 슬라이드를 렌더/Read해서 박스 겹침·텍스트 경계 침범·하단 잘림을 슬라이드별로 보고하라"**고 시킨다. **메인은 그 텍스트 보고만 받는다** (슬라이드 PNG를 직접 Read 금지 — 규칙 7). 보고에 결함 있으면 그 슬라이드만 고쳐 재렌더 → 재위임. 0건이어야 통과.
3. **(품질 목표 높을 때) 평가→근본원인→재빌드 루프** (§ learned-principles R3 원칙 10): 같은 패턴으로 평가자 서브에이전트가 슬라이드를 보고 **점수 + 근본원인 + 슬라이드별 지적을 텍스트로** 회수. 메인은 개별 슬라이드가 아니라 *시스템 원인*(배경·뱃지·여백·마스터충실)을 고쳐 재빌드. 9점대까지 반복. (검수와 평가를 한 서브에이전트가 겸하면 호출 절약.)
4. **보여주기**: HTML+PDF를 `~/Downloads/<덱>-deck/`에 묶어(styles.css·deck-stage.js·assets 동봉) 사용자에게 전달. PDF는 Preview.app 마킹용.
5. **피드백 루프**: 사용자 마킹/지적 → *시스템 원인*으로 변환해 §10 누적 후보로 삼고 재빌드.

---

### Phase 6 — 커밋/공유 (+ Claude.ai 핸드오프 fallback)

- 사용자가 OK하면 `.html`을 caramel-decks에 PR로 올린다(기존 deck 브랜치 패턴 `deck/<슬러그>` 또는 `/handoff` 커맨드).
- **Fallback — Claude.ai 슬라이드 환경 핸드오프**: 이 환경에서 빌드/검증이 불가할 때(이미지도 못 보고 평가자도 막힘 등)만, brief를 push하고 아래 메시지 출력:
  ```
  Repo: the-trive/caramel-decks (main) · Brief: briefs/<슬러그>.md
  CLAUDE.md(§10 전부)·layouts.md·styles.css·slide-master/·deck-stage.js 가져와서
  마스터 살벌히 따라 <덱 이름>.html 빌드 → 매핑 초안 confirm 후 진행.
  ```

---

## 가드레일

### 거절해야 하는 요청
- "PPTX로 직접 만들어줘" → "산출은 HTML이고 공유 시 export"로 안내.
- (옛 규칙 "지금 .html 직접 작성 거절"은 **폐지**. 이제 직접 빌드가 기본이다.)

### caramel-decks 워크플로우 무시 케이스
`~/caramel-decks` 외 일회성 슬라이드(학습용 1장, 비-카라멜)면 brief 워크플로우는 과함 → "단순 1회용이면 그냥 HTML 직접 만들까요?"로 분기(이때도 직접 빌드).

### 메시지가 너무 짧을 때
"슬라이드 만들어줘"만 오면 Phase 1 인터뷰부터. 추측 금지.

---

## 새 덱 시작 체크리스트

- [ ] **`git fetch origin` → `origin/main` worktree에서 작업** (로컬 main stale 주의, `slide-master/` 25개 존재 확인)
- [ ] caramel-decks `CLAUDE.md` §10 전부 Read (특히 §10.3 마스터 충실·검증 게이트)
- [ ] `layouts.md` · `styles.css` · `slide-master/` · `briefs/_template.md` Read
- [ ] 인터뷰 6핵심 확보 + 자료 수집(첨부 직접 파싱, 예상치 "예상" 표기)
- [ ] `briefs/<슬러그>.md` 작성
- [ ] 슬라이드↔마스터 매핑 초안 confirm
- [ ] 직접 빌드 (쓰는 마스터마다 PDF 렌더→복제, §10 전부 적용)
- [ ] 렌더(PDF/PNG 생성, 메인은 Read 안 함) → **검수 서브에이전트가 전 슬라이드 겹침/잘림 점검·텍스트 보고** → 게이트 통과 (규칙 7)
- [ ] (선택) 평가→근본원인→재빌드 루프로 품질 상향
- [ ] HTML+PDF Downloads에 묶어 보여주기 → 피드백 루프
- [ ] OK 시 caramel-decks에 .html PR

---

## /townhall과의 관계

`/townhall`은 격주 타운홀 전용 데이터 수집기. Phase 1-4(Slack/Obsidian/Linear/MySQL/GitHub 2주치 자동 수집·검증)까지 자체 진행 → 이 스킬의 brief 작성·**직접 빌드·검증** 단계로 넘긴다. 빌드·검증 절차는 `/slides`를 단일 진실로 본다.
