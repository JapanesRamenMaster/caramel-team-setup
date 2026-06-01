---
name: slides
version: 4.0.0
description: |
  카라멜 슬라이드(Product Weekly · 타운홀 · 외부 미팅 · 일반 덱) 작업의 진입점.
  HTML canonical, brief.md 핸드오프 워크플로우(`~/caramel-decks` repo) 자동화.
  사용자 요청에서 주제·청중·발표일·핵심 메시지 인터뷰 → 자료 수집 → brief.md 작성 → repo push → 핸드오프 메시지 출력.
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

# /slides — 카라멜 덱 brief 자동화

**산출 형식은 항상 HTML canonical (caramel-decks repo).** PPTX는 만들지 않는다. 공유가 필요하면 HTML에서 export.

이 스킬은 `~/caramel-decks` 워크플로우의 진입점 — Claude Code(이 환경)가 brief.md를 작성해 push하면, Claude(슬라이드 환경)이 GitHub에서 가져가 HTML로 빌드한다.

한국어로 소통한다.

---

## 절대 규칙

1. **HTML canonical 외 다른 형식 만들지 않는다.** PPTX/Keynote/Google Slides 다 거절. "PPT로 만들어줘"라고 와도 "산출은 HTML이고 공유 시 export"로 안내.
2. **brief.md 푸시까지 = 이 스킬의 끝.** 슬라이드(.html) 자체는 다른 환경(Claude)에서 만든다. 이 스킬에서 .html을 만들려 하지 않는다.
3. **`/townhall`은 Phase 1-4까지 자체 수집 → 이 스킬의 brief 작성 단계로 진입한다.** 타운홀이라고 별도 PPTX 만들지 않는다.
4. **caramel-decks CLAUDE.md를 brief 작성 전 반드시 Read.** §10(라운드별 학습 원칙) 누적되는 곳 — 인용 / quote 슬라이드 / 24px floor 등 brief에 반영해야 할 가드레일이 거기 있다.
5. **푸시는 `the-trive/caramel-decks` main에 직접.** 별도 브랜치 안 씀(brief 단계는 review-free).

---

## 5단계 워크플로우

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
- **Slack**: 최근 컨텍스트 (캠페인 회고, 인시던트 등)
- **Sheets**: 트라이브 프로젝션, KPI 시트
- **첨부 PDF/이미지**: 내용 직접 파싱. brief 본문에 인용 끌어오기. (caramel-decks CLAUDE.md §10.1 원칙 1)

자료가 많고 신뢰도 다양하면 **신뢰도 표시 필수**: 확정 / 가설 / 단일 데이터 / partial.

---

### Phase 3 — brief.md 작성

1. 템플릿 읽기: `~/caramel-decks/briefs/_template.md`
2. 파일 경로: `~/caramel-decks/briefs/<덱-슬러그>.md`
   - 슬러그: 한글 제목 그대로 OK. 공백 허용. 예: `product-weekly-260504.md`, `4월 타운홀.md`
3. 채울 섹션:
   - 메타 (6개 핵심)
   - 오늘의 메시지 (one-liner)
   - 핵심 발견 / 데이터 (각 발견마다 무엇/데이터/출처/신뢰도)
   - 액션·우선순위 표 (P0/P1/P2)
   - 제안 슬라이드 흐름 (`# / 내용 / 레이아웃 후보 / 메모`)
   - 제외·주의 (가드레일)
   - 첨부·링크
   - 미해결 / TBD

#### 슬라이드 흐름 짤 때

- **첫 장 = 표지, 끝 장 = 인사** (다크 배경 "감사합니다")
- **1슬라이드 = 1메시지.** 우겨넣지 말 것
- **레이아웃 후보** 모르면 비워둠 — Claude(슬라이드)가 매핑 초안 짜서 confirm 받음
- **caramel-decks `layouts.md` 참조해 의도 기반으로 추천**: hero quote / 비교 2단 / KPI 3카드 / 표(recap) / 카드 4개 / 차트 강조 / 인덱스
- 한국어 본문은 word-break: keep-all 전제 (caramel-decks CLAUDE.md §10.1 원칙 3, styles.css 적용 완료)

---

### Phase 4 — Push

`~/caramel-decks` main에 직접:

```bash
cd ~/caramel-decks
git status                       # working tree clean 확인
git pull --ff-only
# brief 파일 작성된 상태
git add "briefs/<덱-슬러그>.md"
git commit -m "brief: <덱 이름>"
git push origin main
```

working tree dirty면 사용자에게 알리고 멈춤.

---

### Phase 5 — 핸드오프 메시지 출력

Claude(슬라이드 환경)에 그대로 붙여넣을 메시지를 출력:

```
새 덱 작업 시작.

Repo: the-trive/caramel-decks (main)
Brief: briefs/<덱-슬러그>.md

System 파일 (반드시 같이 가져올 것):
- CLAUDE.md (작업 규칙, §10 라운드별 학습 원칙 전부 읽기)
- layouts.md (레이아웃 카탈로그)
- styles.css (v3.1 디자인 토큰)
- deck-stage.js (수정 금지)

`github_import_files`로 위 5개 파일 가져온 뒤:
1. CLAUDE.md §0.2 사전 확인 절차대로 매핑 초안 표 먼저 보여주고 confirm 받기
2. 파일명: <덱 이름>.html
3. 24px floor / 한국어 word-break: keep-all 가드 지키기
4. 끝나면 .html 다운로드 → /handoff 로 PR 올림
```

이후 사용자가 .html을 받아오면 `/handoff` 슬래시 커맨드(caramel-decks의 project 커맨드)로 PR 오픈.

---

## 가드레일

### 거절해야 하는 요청

- "PPTX로 직접 만들어줘" → "산출은 HTML이고 공유 시 export. brief까지 만들고 다른 환경에서 HTML 빌드"로 안내
- "지금 .html 직접 작성해줘" → 이 스킬은 brief 단계까지. .html은 분업된 다른 환경. 사용자가 굳이 원하면 별도 작업으로 분리

### caramel-decks 워크플로우 무시 케이스

`~/caramel-decks` 외 디렉토리에서 일회성 슬라이드를 만들어 달라는 요청이 오면 (예: 학습용 1장 짜리, 비-카라멜 자료) brief 워크플로우는 과함. 이때만 사용자에게 "단순 1회용이면 그냥 마크다운/HTML 직접 만들까요?"로 분기.

### 메시지가 너무 짧을 때

"슬라이드 만들어줘"만 들어오면 Phase 1 인터뷰부터 진행. 추측 금지.

---

## 새 덱 시작 체크리스트

- [ ] caramel-decks `CLAUDE.md` Read (§10 누적 원칙 포함)
- [ ] `briefs/_template.md` Read
- [ ] 인터뷰 6개 핵심 확보
- [ ] 자료 수집 (DB / Linear / Slack / 첨부 직접 파싱)
- [ ] `briefs/<슬러그>.md` 작성
- [ ] working tree clean 확인 → commit & push
- [ ] 핸드오프 메시지 출력
- [ ] 사용자가 .html 받아오면 `/handoff`로 PR 오픈

---

## /townhall과의 관계

`/townhall`은 격주 타운홀 전용 데이터 수집기. Phase 1-4(Slack/Obsidian/Linear/MySQL/GitHub 2주치 자동 수집·검증)까지 자체 진행 → 결과를 이 스킬의 Phase 3로 넘긴다. 즉 `/townhall`이 자료를 모은 뒤 brief 작성·push·핸드오프는 `/slides`와 동일.
