---
name: slides
version: 7.1.0
description: |
  카라멜 슬라이드(Product Weekly · 타운홀 · 외부 미팅 · 일반 덱) 작업의 진입점.
  HTML canonical (`~/caramel-decks` repo). brief → 슬롯 캐스팅 → masters/ 스니펫 조립 → 기계 검증 → 보여주기까지 한 자리에서 끝낸다.
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

# /slides — 카라멜 덱 (brief → 슬롯 캐스팅 → 스니펫 조립 → 기계 검증)

> 한국어 산문은 `deslop` 스킬의 규칙(존재·이해·구조·표현 4축)을 적용해 쓰고, 내보내기 직전에 `slop-audit` 게이트를 통과시킨다.

**산출 형식은 항상 HTML canonical.** PPTX는 만들지 않는다. 공유가 필요하면 HTML에서 export.

한국어로 소통한다.

**v7의 핵심:** 마스터 31종이 `masters/*.html` 스니펫 + `masters.css` 클래스로 **이미 코드화**되어 있다. 매 덱마다 마스터 PDF를 렌더해 픽셀을 추정하는 일은 없다 — 스니펫을 복사해 콘텐츠를 **캐스팅**한다.

**v7.1에서 바뀐 것 (2026-08-03, IR 덱 반려 후):** 게이트를 PASS한 덱이 "하나도 안 읽힌다"로 반려됐다. 원인은 두 가지였고 둘 다 구조 결함이었다.

1. **brief의 줄글이 슬롯으로 직행했다.** 그 사이에 정보구조로 바꾸는 단계가 워크플로우에 없었다 → **Phase 3.5 슬롯 캐스팅** 신설. 산출물(캐스팅 표)이 있어야 빌드로 넘어간다.
2. **게이트가 "넘침"만 벌해서, 게이트를 통과하는 가장 싼 작성법이 줄글이었다** → 검증기에 `prose-block`·`flat-hierarchy`·`frame-overflow` FAIL과 `dense-caption`·`inline-geometry`·`mono-form` WARN 추가.
3. **2차 반려 (같은 날)**: 앵커 옆에 작은 수식어를 붙여 한 줄 안에서 크기를 섞었고, 표 합계행이 폰트는 큰데 행 높이는 작았다. 뿌리는 **마스터에 선례가 없는 클래스(`.unit` 0.34em)를 시스템이 용법 없이 제공한 것** → `.unit`을 같은 크기+회색으로 재정의, `.anchor-note` 신설, `mixed-size-inline`·`row-height-inversion` FAIL 추가 (원칙 32).

**v7.2에서 바뀐 것 (2026-08-04, IR 덱 2차 반려 후):** "글씨 크기가 너무 다이나믹하다 / 작은 텍스트 못 읽힘 / 동어반복 / 내부 용어"로 추가 반려. FAIL 4종 추가, 스케일 재정의, `.anchor-note` 폐지.

4. **타이포 스케일 재정의**: 기본 스케일 = 60(제목) / 32(라벨) / 28(본문) 3종. 앵커(72) 또는 KPI(96) 중 하나를 얹어 최대 4종. **`.anchor-note` 폐지** — 지표명은 라벨에, 값은 앵커에 (원칙 35).
5. **게이트 4종 추가**: `font-scale-inflation`(슬라이드 5종·카드 4종 초과), `redundant-slot`(라벨-앵커 어휘 반복), `banned-term`(내부 용어·조판 지시어·회계 파생지표), `source-note-overuse`(출처 3장+) (원칙 33~37).

**게이트가 판정할 수 있는 것과 없는 것을 혼동하지 않는다.** 게이트는 조판 바닥(넘침·겹침·줄글·계층비·프레임 이탈)만 본다. "이 수치가 이 카드의 주장인가"는 판정하지 못한다 — 그건 Phase 3.5에서 사람이 결정한다.

---

## 절대 규칙

1. **HTML canonical 외 다른 형식 만들지 않는다.** "PPT로 만들어줘"가 와도 "산출은 HTML이고 공유 시 export"로 안내.
2. **슬라이드는 `masters/<번호>.html` 스니펫 복사에서 시작한다.** 위치·크기·클래스는 스니펫이 진실이다. `slide-master/*.pdf`를 빌드 중 렌더하지 않는다 (마스터 개정 작업일 때만 예외).
3. **잠금은 3층** (CLAUDE.md §1.1):
   - (a) 브랜드(색·폰트) = 항상 잠금 — `styles.css` 토큰만.
   - (b) 조판(그리드·간격·28px floor) = 항상 잠금 — `masters.css` 클래스 + validator.
   - (c) 레이아웃 선택 = 자유 — 31종이 시작점, 안 맞으면 (a)+(b)를 지키며 조합. 사전 승인 불필요. 잘 나온 조합은 세션 끝에 갤러리 추가 PR 제안.
4. **인터뷰 메타(청중·발표자·날짜·목적)는 슬라이드에 노출하지 않는다.** context와 speaker notes 전용.
5. **카드는 2층으로 쓴다 — 라벨(32px) → 앵커(72px) → 불렛(28px).** 카드마다 `.card-anchor` 1개 필수. `.anchor-note`는 폐지됨 — 지표명은 라벨에 흡수. "라벨 + 줄글" 2층 금지. 앵커로 뽑을 수치가 없으면 그건 카드가 아니다 (원칙 29·35 · layouts.md).
6. **같은 줄에서 폰트 크기를 섞지 않는다.** 단위는 크기가 아니라 색으로 낮춘다. 인라인 `font-size` 금지. 표 합계행은 `tbody > tr.total`(tfoot은 폰트가 커도 행이 줄어든다) (원칙 32).
7. **레이아웃을 인라인 px로 교정하지 않는다.** `height`·`padding-top`·`justify-content`를 인라인으로 덮고 싶어지면, 그건 `masters.css`를 고쳐야 하는 순간이다 (원칙 30).
8. **`validate-deck.sh` PASS는 필수 게이트.** FAIL이면 미완. **단 PASS는 "조판 바닥을 통과했다"는 뜻일 뿐 "읽힌다"는 보장이 아니다** — WARN도 전부 읽고 판단한다.
9. **완성 기준은 "client ready".** 기계 게이트 통과 후 PDF를 `open`으로 직접 열어 심미 결함(로고 박스, 어색한 여백, 이미지 미표시)을 육안 확인. 결함이 보이면 수정 → 재렌더 → 재확인 루프.
10. **빌드 세션은 슬라이드 이미지를 직접 Read하지 않는다.** 심미 검수는 서브에이전트가 하고, 메인은 텍스트 보고만 받는다.

---

## 7단계 워크플로우

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

### Phase 3.5 — 슬롯 캐스팅 (신설 · 건너뛰지 않는다)

brief는 **줄글**이고 슬라이드는 **슬롯**이다. 이 변환을 명시적으로 하지 않으면 brief의 문장이 그대로 카드에 들어가 안 읽히는 덱이 된다 (v7 첫 실전 반려의 직접 원인).

**슬라이드 1장당 아래 표 1행을 쓴다. 이 표 없이 HTML을 쓰지 않는다.**

```
| # | 앵커 (수치/6자 이내) | 불렛 (한 줄에 한 항목, ≤3개) | 버린 것 | 폰트 종류 수 |
|---|---|---|---|---|
| 5 | 72%+ | 방문 세차 구독·회차권 / 거점 스테이션 추가 | 구독 상품 구조 상세 | 4종 (제목60·라벨32·앵커72·불렛28) |
```

**폰트 종류 수 열**: 4종 초과이면 HTML로 넘어가지 못한다(원칙 33 · `font-scale-inflation` FAIL). 기본 3종(60/32/28)+앵커(72) 또는 KPI(96) 중 하나 = 최대 4종.

규칙:
- **앵커를 못 정하면 멈춘다.** 그 슬라이드는 카드 레이아웃이 틀렸다는 뜻 — 리스트나 표(8-x)로 바꾸거나 슬라이드를 쪼갠다.
- **불렛은 개조식.** 어미 통일(`~함`/`~임` 또는 명사형), 항목당 c3 28자 · c2 38자 이내. 항목 4개 이상이면 슬라이드를 쪼갠다.
- **"버린 것" 열을 반드시 채운다.** 버릴 게 없다는 건 요약을 안 했다는 뜻이다. 버린 내용은 speaker notes로 옮긴다.
- 수치가 주장의 핵심이면 `<span class="hl">`로 문장 안에서 색만 바꾸지 말고 **앵커로 꺼낸다.**
- 슬라이드 성격에 따라 형태를 고른다: **수치 대비**(앵커 중심) / **시간 방향**(현재 → 목표) / **목록·인물**(자격 한 줄) / **전제·가정 다수**(표 8-x). 같은 마스터 3연속 금지 (원칙 31).

### Phase 4 — 조립 빌드

#### 4-1. 시스템 준비 (매 덱 시작)

```bash
git -C ~/caramel-decks pull --ff-only   # worktree 불필요 — 레포에 덱이 없어 로컬이 곧 main
```

읽어야 할 파일 (이게 전부다):
- `layouts.md` — 마스터 31종 카탈로그 + 모디파이어 + 스니펫·클래스 매핑 표
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
- 각 슬라이드 = 스니펫 복사 → **Phase 3.5 캐스팅 표의 앵커·불렛을 슬롯에 넣고** → `data-screen-label` 갱신.
- 반복 요소(KPI 카드, 비교 컬럼)는 스니펫 주석의 "반복 단위"를 따라 개수 조절 — grid가 자동 배분.
- **스니펫 헤더의 `슬롯 용량:` 줄이 그 슬롯의 정본이다.** 플레이스홀더보다 길어지면 슬롯을 바꾸라는 신호 — 우겨넣지 말고 앵커+불렛으로 전환하거나 슬라이드를 분리한다. **게이트가 이걸 다 잡아주지는 못한다** (24px 이상·안 겹치고·안 넘치는 줄글은 `prose-block` 임계 아래면 통과한다).
- 카드 = `라벨 → .card-anchor(80px) → .bullets`(한 줄에 한 항목). `.compare-body`·`.parallel-desc`(28px 산문)와 섞지 않는다.
- **인라인 style로 `height`·`padding-top`·`justify-content`를 쓰지 않는다** (원칙 30 · `inline-geometry` 경고). `--content-top`/`--content-bottom`만 section에 준다.
- 차트·막대: 스니펫의 SVG 자리표시자를 실제 데이터로 재생성 (축·라벨 위치는 스니펫 프레임 유지).
- 분량 많으면 슬라이드 명세를 Agent(Sonnet)에 위임 가능 — 위임 시에도 캐스팅 표 + "스니펫 복사" 방식 유지.

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

   | 판정 | 뜻 | 조치 |
   |---|---|---|
   | `clipped` / `scroll-clipped` | 슬라이드 박스 밖으로 나감 | 즉시 수정 |
   | `frame-overflow` | `.content` 프레임 밖으로 나감 (슬라이드 안이어도 결함) | 인라인 px 제거 → 프레임 상대 정렬 |
   | `text-overlap` | 텍스트 잉크 겹침 | 즉시 수정 |
   | `font-floor` | 콘텐츠 24px 미만 | 즉시 수정 |
   | `prose-block` | 카드·패널 본문 4줄 이상 = 줄글 | 앵커+불렛으로 재캐스팅 |
   | `flat-hierarchy` | 본문 3줄+ 카드에 지배 요소 없음(계층비 <2.2) | `.card-anchor` 추가 |
   | `mixed-size-inline` | 같은 줄 폰트 크기 비 ≥1.25 | 단위를 같은 크기+회색으로 |
   | `row-height-inversion` | 폰트 큰 행의 높이가 더 작다 | 표 합계행을 `tbody tr.total`로 |
   | `font-scale-inflation` | 슬라이드 폰트 종 ≥5, 카드 내 ≥4 | 기본 3종(60/32/28)+앵커 1종으로 줄인다 (원칙 33) |
   | `redundant-slot` | 같은 카드 내 두 슬롯 어휘 교집합 ≥60% | 라벨에 지표명·앵커에 값으로 합친다 (원칙 35) |
   | `banned-term` | 조판 지시어·내부 운영 용어·회계 파생지표 | 고객 언어로 환산하거나 삭제 (원칙 36·37) |
   | `source-note-overuse` | 덱 전체 `.chrome-source` ≥3장 | 핵심 1장에만 출처 표기 |
   | **WARN** `dense-caption` | 앵커 옆 설명이 3줄+ | 열거를 `.bullets`로 쪼갠다 |
   | **WARN** `inline-geometry` | 이미지 레이아웃에 인라인 height/padding-top | CSS를 고친다 (원칙 30) |
   | **WARN** `mono-form` | 같은 마스터 3연속 | 한 장을 다른 형태로 (원칙 31) |

   **WARN은 exit code에 영향이 없다 — 그래서 반드시 읽는다.** PASS + WARN 0을 목표로 한다.
2. **심미 검수 (서브에이전트)**: PDF→PNG(`pdftoppm -png -r 90`) 후 서브에이전트가 전 슬라이드를 보고 심미 결함만 보고 (겹침/잘림은 이미 기계가 봤다 — 어색한 여백, 시각 비중 불균형, 이미지 미표시, 로고 박스 등). **검수 지시에 "30초에 이 장에서 뭘 가져가는가"를 반드시 포함한다** — 여백만 보게 하면 안 읽히는 덱이 통과한다.
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
- [ ] 카드마다 앵커(72px) + 불렛(28px) — 라벨(32px)+줄글 2층 금지, `.anchor-note` 쓰지 않는다 (원칙 29·35)
- [ ] 슬라이드 폰트 종류 ≤4종, 카드 내 ≤3종 — 캐스팅 표의 "폰트 종류 수" 열 확인 (원칙 33)
- [ ] 같은 마스터 3연속 없음 — `grep -o 'data-master="[^"]*"' <덱>.html | uniq -c` (원칙 31)
- [ ] 인라인 height·padding-top·justify-content 없음 (원칙 30)
- [ ] 인라인 font-size 없음 · 표 합계행은 `tbody tr.total` (원칙 32)
- [ ] 조판 지시어("막대/좌측/우측/x축/y축/범례/이 표") 없음 (원칙 36)
- [ ] 내부 용어("개 존/셀 배정/티어/O·E/배차") · 회계 파생지표("공헌이익률/BEP/블렌디드") 없음 (원칙 37)
- [ ] `.chrome-source` 덱 전체 ≤2장 (3장+ = `source-note-overuse` FAIL)
- [ ] `.conclusion-banner`는 덱 전체 2~3장 이내 (희소해야 읽힌다)
- [ ] 마스터 16(대시보드)은 "추이+스냅샷 동시"일 때만 — 아니면 9-1·4-1로 분리
- [ ] 사업 소개 장 앵커 = 반복·유지·전환 증거 / 재무 장 앵커 = 규모·성장률 (원칙 40)
- [ ] **레퍼런스 장표가 있으면 마스터 19로 원본 그대로** — 로고 크롭·재조합 금지 (원칙 39)
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

`/townhall`은 격주 타운홀 전용 데이터 수집기. Phase 1-3(자료 수집·검증)까지 자체 진행 → 이 스킬의 **Phase 3.5(슬롯 캐스팅)** 로 진입한다. brief에서 곧장 HTML로 넘어가지 않는다.

---

## 마스터 개정 작업일 때 (덱 빌드 아님)

masters/ 스니펫이 마스터 PDF와 어긋났거나 새 마스터를 추가할 때만:
1. `slide-master/<이름>.pdf` → `pdftoppm -png -r 72` (1px=1 CSS px) + `pdftotext -bbox`로 실측
2. 스니펫·masters.css 수정 → 렌더해 마스터 PNG와 나란히 비교
3. layouts.md 매핑 표 갱신 → PR (레포 변경은 항상 PR)
