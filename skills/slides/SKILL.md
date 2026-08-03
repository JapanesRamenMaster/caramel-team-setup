---
name: slides
version: 7.0.0
description: |
  카라멜 슬라이드(Product Weekly · 타운홀 · 외부 미팅 · 일반 덱) 작업의 진입점.
  HTML canonical (`~/caramel-decks` repo). brief 작성 → masters/ 스니펫 조립 → 기계 검증 → 보여주기까지 한 자리에서 끝낸다.
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

# /slides — 카라멜 덱 (brief → 스니펫 조립 → 기계 검증)

**산출 형식은 항상 HTML canonical.** PPTX는 만들지 않는다. 공유가 필요하면 HTML에서 export.

한국어로 소통한다.

**v7의 핵심 (v6과 다른 점):** 마스터 26종이 `masters/*.html` 스니펫 + `masters.css` 클래스로 **이미 코드화**되어 있다. 매 덱마다 마스터 PDF를 렌더해 픽셀을 추정하는 일은 없다 — 스니펫을 복사해 콘텐츠만 교체한다. 겹침/잘림 검수는 `validate-deck.sh`가 기계 판정한다.

---

## 절대 규칙

1. **HTML canonical 외 다른 형식 만들지 않는다.** "PPT로 만들어줘"가 와도 "산출은 HTML이고 공유 시 export"로 안내.
2. **슬라이드는 `masters/<번호>.html` 스니펫 복사에서 시작한다.** 위치·크기·클래스는 스니펫이 진실이다. `slide-master/*.pdf`를 빌드 중 렌더하지 않는다 (마스터 개정 작업일 때만 예외).
3. **잠금은 3층** (CLAUDE.md §1.1):
   - (a) 브랜드(색·폰트) = 항상 잠금 — `styles.css` 토큰만.
   - (b) 조판(그리드·간격·24px floor) = 항상 잠금 — `masters.css` 클래스 + validator.
   - (c) 레이아웃 선택 = 자유 — 26종이 시작점, 안 맞으면 (a)+(b)를 지키며 조합. 사전 승인 불필요. 잘 나온 조합은 세션 끝에 갤러리 추가 PR 제안.
4. **인터뷰 메타(청중·발표자·날짜·목적)는 슬라이드에 노출하지 않는다.** context와 speaker notes 전용.
5. **`validate-deck.sh` PASS는 필수 게이트.** FAIL이면 미완 — findings의 슬라이드·요소·px가 그대로 나오므로 즉시 수정한다.
6. **완성 기준은 "client ready".** 기계 게이트 통과 후 PDF를 `open`으로 직접 열어 심미 결함(로고 박스, 어색한 여백, 이미지 미표시)을 육안 확인. 결함이 보이면 수정 → 재렌더 → 재확인 루프.
7. **빌드 세션은 슬라이드 이미지를 직접 Read하지 않는다.** 심미 검수는 서브에이전트가 하고, 메인은 텍스트 보고만 받는다.

---

## 6단계 워크플로우

### Phase 1 — 인터뷰

사용자가 던진 메시지에서 이미 답이 보이는 항목은 **묻지 않는다.** 비어있는 것만 질문.

**슬라이드 내용을 결정하는 핵심 4개:**

| 항목 | 예 |
|---|---|
| 덱 이름 | "Product Weekly 260504" |
| 종류 | weekly / 타운홀 / 외부 미팅 / 기타 |
| One-liner | 청중이 한 줄로 가져가야 할 것 |
| 분량 가이드 | "자유" 또는 "약 N장" |

**발표 맥락(선택, context·speaker notes 전용 — 슬라이드 미노출):**
청중 / 발표자 / 발표일 / 톤 / speaker notes 필요 여부.

### Phase 2 — 자료 수집

사용자가 준 자료가 1차 소스. 부족분만 보강:

- **DB**: `~/claude/mysql-query.sh "SQL"`. 첫 쿼리 전 `~/claude/QUERY_REFERENCE.md` Read 필수.
- **Linear / Slack / Sheets**: MCP 도구.
- **첨부 PDF/이미지**: 직접 파싱해 brief에 인용 (§10.1 원칙 1).
- **이미지·에셋**: 사진/로고가 필요한 슬라이드를 미리 파악. 개념 비유 → SVG 직접 생성 / 실사 → Unsplash·Pexels / 로고 → Figma `get_screenshot` (원칙 26: 카라멜 로고 fileKey `EBoVMwYDtky8vW18xfrCtc`, nodeId `2494:2`, 배경 있으면 PIL 투명화).

자료 신뢰도 다양하면 확정/가설/단일 데이터/partial 표시.

### Phase 3 — brief.md 작성

1. 템플릿: `~/caramel-decks/briefs/_template.md`
2. 경로: `~/caramel-decks/briefs/<덱-슬러그>.md`
3. 채울 섹션: 메타(핵심 4개) · one-liner · 핵심 발견/데이터 · 제안 슬라이드 흐름(`#/내용/레이아웃/메모`) · 미해결.

슬라이드 흐름 원칙: 첫 장=표지(1), 끝 장=인사(13), 1슬라이드=1메시지.

### Phase 4 — 조립 빌드

#### 4-1. 시스템 준비 (매 덱 시작)

```bash
git -C ~/caramel-decks pull --ff-only   # worktree 불필요 — 레포에 덱이 없어 로컬이 곧 main
```

읽어야 할 파일 (이게 전부다):
- `layouts.md` — 마스터 26종 카탈로그 + 스니펫·클래스 매핑 표
- `CLAUDE.md` §1~§8 (§10은 아카이브 — 읽지 않는다. 살아있는 원칙은 아래 체크리스트에 있음)

`styles.css`·`masters.css`는 읽지 않아도 된다 — 스니펫이 올바른 클래스를 이미 쓰고 있다.

#### 4-2. 매핑 초안 → confirm과 병렬 빌드

brief의 슬라이드 흐름을 layouts.md 표에서 골라 매핑 표를 사용자에게 보여준다. **확인을 기다리는 동안 표지·인사 등 확실한 슬라이드부터 빌드를 시작한다** (레이아웃 변경이 오면 해당 슬라이드만 교체 — 직렬 블로킹 금지). 수정 라운드는 confirm 없이 바로.

```
| # | 슬라이드 | 마스터 | 이유 |
|---|---|---|---|
| 1 | 표지 | 1. 표지 | - |
```

26종에 맞는 게 없으면: masters.css의 조판 프리미티브(`.content`, `.card`, grid 클래스)로 조합해 만들고, 매핑 표에 "조합: [설명]"으로 표시한다. 사전 승인 게이트 없음.

#### 4-3. 덱 파일 구성

```html
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8" />
<title>[덱 이름]</title>
<link rel="stylesheet" href="styles.css" />
<link rel="stylesheet" href="masters.css" />
<script src="deck-stage.js"></script>
</head>
<body>
<deck-stage>
  <!-- masters/<번호>.html 스니펫을 여기에 복사하고 콘텐츠 교체 -->
</deck-stage>
</body>
</html>
```

- 작업 디렉토리: `~/Downloads/<덱>-deck/` — 처음부터 여기서 빌드. `styles.css`·`masters.css`·`deck-stage.js`를 **먼저 복사**해 두고 상대경로 참조 (패키징 누락 방지).
- 각 슬라이드 = 스니펫 복사 → 플레이스홀더를 실제 콘텐츠로 교체 → `data-screen-label` 갱신.
- 반복 요소(KPI 카드, 비교 컬럼)는 스니펫 주석의 "반복 단위"를 따라 개수 조절 — grid가 자동 배분.
- 콘텐츠가 슬롯보다 길면: 우겨넣지 말고 분리(1슬라이드 1메시지). validator가 잡는다.
- 차트·막대: 스니펫의 SVG 자리표시자를 실제 데이터로 재생성 (축·라벨 위치는 스니펫 프레임 유지).
- 분량 많으면 슬라이드 명세를 Agent(Sonnet)에 위임 가능 — 위임 시에도 "스니펫 복사 + 콘텐츠 교체" 방식 유지.

### Phase 5 — 검증 (기계 → 심미 순서)

```bash
# 1) 기계 게이트 (필수 — PASS까지 반복)
~/caramel-decks/validate-deck.sh ~/Downloads/<덱>-deck/<덱>.html

# 2) PDF 렌더
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=~/Downloads/<덱>-deck/<덱>.pdf "file://<HTML절대경로>"
```

1. **기계 게이트**: `validate-deck.sh` PASS까지. findings(슬라이드·요소·px)가 좌표를 특정해주므로 VLM 왕복 없이 바로 수정.
2. **심미 검수 (서브에이전트)**: PDF→PNG(`pdftoppm -png -r 90`) 후 서브에이전트가 전 슬라이드를 보고 심미 결함만 보고 (겹침/잘림은 이미 기계가 봤다 — 어색한 여백, 시각 비중 불균형, 이미지 미표시, 로고 박스 등).
3. **직접 확인 (필수)**: `open <PDF>` — 육안 확인. 결함 발견 시 수정 → 1번부터 재검. "결함 없음"까지 반복.
4. **피드백 루프**: 사용자 지적 → 시스템 원인 단위로 수정. 같은 지적이 재발할 구조면 masters/ 또는 CLAUDE.md 개정 PR 제안.

### Phase 6 — 산출 마무리

- **산출물 = `~/Downloads/<덱>-deck/`** — HTML + PDF + `styles.css` + `masters.css` + `deck-stage.js` + `assets/` 전부 포함 확인 (HTML이 상대경로 참조하므로 하나라도 빠지면 안 열림).
- **caramel-decks 레포에 덱 `.html`은 커밋하지 않는다.** 디자인 시스템·원칙·masters/ 변경만 브랜치+PR.
- 이번 덱에서 조합으로 만든 새 레이아웃이 잘 나왔으면: "갤러리에 마스터로 추가할까요?" 제안 → 승인 시 masters/에 스니펫 추가 PR.

---

## 살아있는 원칙 체크리스트 (매 덱 적용 — §10 전독 대체)

- [ ] 표지=제목 한 줄만·끝 장=인사. 인터뷰 메타 미노출 (원칙 12)
- [ ] 내지에 로고·출처·액션 면 노출 금지 (원칙 13)
- [ ] 다크 배경 = 표지·인사 + 임팩트 1~2장만 (원칙 18)
- [ ] 뱃지 2종·카드 단일 스펙·강조 슬라이드당 1개 (원칙 19)
- [ ] 선언은 액자 금지·예상/목표 수치 명시 (원칙 21)
- [ ] 추이=막대(9-x)·과정=타임라인(11-x)·비교=차트(8-x) — 텍스트 카드로 평탄화하지 않기 (원칙 17)
- [ ] 글씨 크게·텍스트 적게, SO WHAT은 한 문장 (원칙 6·15)
- [ ] `<br>`은 문장 사이만 (원칙 4) · 직접 편집은 표현 그대로 (원칙 9)
- [ ] 슬라이드 삽입/삭제 시 pageno 일괄 보정 + `grep pageno | sort | uniq -c` (원칙 10)
- [ ] 첨부 PDF/이미지 본문까지 파싱해 인용 (원칙 1)

(전체 배경 학습 기록은 CLAUDE.md §10 아카이브)

---

## 가드레일

- "PPTX로 만들어줘" → "산출은 HTML이고 공유 시 export"로 안내
- `~/caramel-decks` 외 일회성 슬라이드(학습용 1장, 비-카라멜)면 brief 워크플로우 과함 → 직접 빌드 분기 (masters.css는 그래도 쓰면 좋다)
- "슬라이드 만들어줘"만 오면 Phase 1부터. 추측 금지.

---

## /townhall과의 관계

`/townhall`은 격주 타운홀 전용 데이터 수집기. Phase 1-3(자료 수집·검증)까지 자체 진행 → 이 스킬의 Phase 4(조립 빌드)로 진입한다.

---

## 마스터 개정 작업일 때 (덱 빌드 아님)

masters/ 스니펫이 마스터 PDF와 어긋났거나 새 마스터를 추가할 때만:
1. `slide-master/<이름>.pdf` → `pdftoppm -png -r 72` (1px=1 CSS px) + `pdftotext -bbox`로 실측
2. 스니펫·masters.css 수정 → 렌더해 마스터 PNG와 나란히 비교
3. layouts.md 매핑 표 갱신 → PR (레포 변경은 항상 PR)
