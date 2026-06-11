---
name: slides
version: 6.1.0
description: |
  카라멜 슬라이드(Product Weekly · 타운홀 · 외부 미팅 · 일반 덱) 작업의 진입점.
  HTML canonical (`~/caramel-decks` repo). Claude Code(이 환경)에서 brief 작성 → HTML 덱 직접 빌드 → 렌더 검증 → 보여주기까지 한 자리에서 끝낸다.
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

**산출 형식은 항상 HTML canonical.** PPTX는 만들지 않는다. 공유가 필요하면 HTML에서 export.

한국어로 소통한다.

---

## 절대 규칙

1. **HTML canonical 외 다른 형식 만들지 않는다.** "PPT로 만들어줘"가 와도 "산출은 HTML이고 공유 시 export"로 안내.
2. **이 스킬에서 .html을 직접 빌드한다.** brief는 콘텐츠 명세일 뿐, 산출은 완성된 .html이다.
3. **시각 레퍼런스는 `slide-master/*.pdf` 뿐이다.** caramel-decks 레포에 있는 기존 `.html` 덱은 시각 레퍼런스로 절대 쓰지 않는다 — 원칙을 이미 어긴 덱이 레포에 있을 수 있다. DOM 구조(deck-stage, section 태그)는 아래 보일러플레이트를 쓴다.
4. **인터뷰 메타(청중·발표자·날짜·목적)는 슬라이드에 노출하지 않는다.** 이 정보는 빌드 context와 speaker notes용이다. 어떤 슬라이드에도 텍스트로 표시하지 않는다.
5. **산출 직전 전 슬라이드 렌더 → 겹침/잘림 전수 점검은 필수 게이트.** 통과 못 하면 미완.
6. **빌드 세션은 슬라이드 이미지를 직접 Read하지 않는다.** 렌더+검수는 서브에이전트가 하고, 메인은 텍스트 보고만 받는다.
7. **완성 기준은 "client ready" — 결함이 없을 때까지 반복 수정한다.** 사용자에게 전달 전에 `open`으로 PDF를 직접 열어 눈으로 확인한다. 결함이 보이면 멈추지 않고 수정 → 재렌더 → 재확인 루프를 반복한다. 외부 리소스(Unsplash 사진, Figma 에셋 등)가 필요하면 사용해도 된다 — 완성도가 우선이다.
8. **마스터 24종으로 표현이 안 될 때는 새 마스터 추가를 제안한다.** 기존 레이아웃 중 적합한 것이 없으면 "이 슬라이드는 기존 마스터로 표현하기 어렵습니다. [제안하는 새 마스터 이름/개념]을 추가하면 좋겠습니다"로 제안하고 사용자 결정을 받는다. 기존 24종에 억지로 끼워 맞추지 않는다.

---

## 6단계 워크플로우

### Phase 1 — 인터뷰

사용자가 던진 메시지에서 이미 답이 보이는 항목은 **묻지 않는다.** 비어있는 것만 질문.

**슬라이드 내용을 결정하는 핵심 4개 (슬라이드에 영향):**

| 항목 | 예 |
|---|---|
| 덱 이름 | "Product Weekly 260504" |
| 종류 | weekly / 타운홀 / 외부 미팅 / 기타 |
| One-liner | 청중이 한 줄로 가져가야 할 것 |
| 분량 가이드 | "자유" 또는 "약 N장" |

**발표 맥락(선택, context·speaker notes 전용 — 슬라이드 미노출):**
청중 / 발표자 / 발표일 / 톤 / speaker notes 필요 여부. 수집하더라도 어떤 슬라이드에도 텍스트로 표시하지 않는다.

---

### Phase 2 — 자료 수집

사용자가 준 자료가 1차 소스. 부족분만 보강:

- **DB**: `~/claude/mysql-query.sh "SQL"`. 첫 쿼리 전 `~/claude/QUERY_REFERENCE.md` Read 필수.
- **Linear / Slack / Sheets**: MCP 도구 활용.
- **첨부 PDF/이미지**: 직접 파싱해 brief에 인용. (§10.1 원칙 1)
- **이미지·에셋**: 슬라이드에 사진/일러스트/로고가 필요한 슬라이드를 미리 파악해 수집 계획을 세운다.
  - 개념 비유(숲·나무·파이프라인 등) → Phase 4에서 SVG 직접 생성
  - 실사 사진 필요 → WebSearch로 Unsplash/Pexels 검색 후 `assets/`에 저장
  - 브랜드 에셋(로고) → Figma MCP `get_screenshot` (아래 4-6 C항 참조)

자료 신뢰도 다양하면 확정 / 가설 / 단일 데이터 / partial 표시. 예상치는 "예상", 목표치는 "목표" 명시.

---

### Phase 3 — brief.md 작성

1. 템플릿: `~/caramel-decks/briefs/_template.md` Read
2. 경로: `~/caramel-decks/briefs/<덱-슬러그>.md`
3. 채울 섹션: 메타(핵심 4개) · one-liner · 핵심 발견/데이터 · 제안 슬라이드 흐름(`#/내용/레이아웃/메모`) · 미해결.

슬라이드 흐름 원칙:
- **첫 장 = 표지, 끝 장 = 인사** (다크 배경)
- **1슬라이드 = 1메시지**
- 레이아웃은 `slide-master/` 24종 중에서만. 사용자 명시 허용 시에만 `12. 자유 변형`.

---

### Phase 4 — 직접 빌드

#### 4-1. 시스템 읽기 (빌드 전 필수)

```bash
git -C ~/caramel-decks fetch origin
git -C ~/caramel-decks worktree add /tmp/deck-wt origin/main
# slide-master/ 25개 있는지 확인
ls /tmp/deck-wt/slide-master/ | wc -l
```

읽어야 할 파일:
- `CLAUDE.md` §10 전부 (라운드별 학습 원칙 1~24)
- `layouts.md` (마스터 24종 카탈로그)
- `styles.css` (디자인 토큰)
- `slide-master/` 파일명 목록

⚠️ **기존 `.html` 덱은 읽지 않는다.** 구조 레퍼런스는 아래 보일러플레이트를 쓴다.

#### 4-2. HTML 보일러플레이트

```html
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8" />
<title>[덱 이름]</title>
<link rel="stylesheet" href="styles.css" />
<style>
/* 24px floor 보장 */
:root { --t-body: 26px; --t-body-sm: 24px; --t-caption: 26px; }
.chrome-top { font-size: 26px !important; }
.chrome-top .deck-title { font-size: 26px !important; }
.chrome-top .pageno { font-size: 26px !important; }
</style>
<script src="deck-stage.js"></script>
</head>
<body>
<deck-stage>

<!-- S01. 표지 — 마스터: 1. 표지 -->
<!-- 제목 한 줄만. 마스터에 없는 요소(오렌지 라인, 소제목, 청중/목적 박스) 추가 금지. -->
<!-- 로고: assets/caramel-logo-transparent.png 사용 (투명 배경 PNG). 텍스트 대체 금지. -->
<section data-screen-label="01 표지" style="background: radial-gradient(ellipse at 40% 38%, #282B30, #07080A);">
  <div style="position:absolute; top:60px; left:80px;">
    <img src="assets/caramel-logo-transparent.png" style="height:52px; opacity:0.85;" alt="caramel" />
  </div>
  <div style="position:absolute; left:80px; right:80px; bottom:220px;">
    <h1 style="font-size:108px; font-weight:800; color:#fff; margin:0 0 36px; line-height:1.05; letter-spacing:-0.03em; text-wrap:balance;">덱 제목</h1>
    <p style="font-size:32px; color:rgba(255,255,255,0.55); margin:0;">부제목(선택)</p>
  </div>
</section>

<!-- S02. [슬라이드명] — 마스터: [마스터 이름] -->
<section data-screen-label="02 [라벨]">
  <div class="chrome-top">
    <div class="deck-title"><strong>[덱 이름]</strong></div>
    <div class="pageno">02 / N</div>
  </div>
  <div class="page-title">
    <span class="eyebrow">[섹션명]</span>
    [페이지 제목]
  </div>
  <!-- 본문 — 마스터 PDF에서 받은 CSS 스펙 그대로 -->
</section>

<!-- SN. 인사 — 마스터: 13. 인사 -->
<!-- 내부 덱: 저작권·이메일·로고 풋터 없음. 중앙 텍스트만. -->
<section data-screen-label="NN 인사" style="background: radial-gradient(ellipse at 50% 40%, #2B2D33, #0D0E12);">
  <div style="position:absolute; left:80px; right:80px; top:50%; transform:translateY(-54%); text-align:center;">
    <h2 style="font-size:96px; font-weight:800; color:#fff; margin:0 0 28px; letter-spacing:-0.025em; line-height:1.1;">감사합니다</h2>
    <p style="font-size:32px; color:rgba(255,255,255,0.55); margin:0; font-weight:400;">부제(선택)</p>
  </div>
</section>

</deck-stage>
</body>
</html>
```

#### 4-3. 매핑 초안 → confirm

brief의 슬라이드 흐름을 마스터 24종에 매핑한 표를 사용자에게 먼저 보여주고 확인받는다.

```
| # | 슬라이드 | 레이아웃 | 이유 |
|---|---|---|---|
| 1 | 표지 | 1. 표지 | - |
| 2 | ... | ... | ... |
```

#### 4-4. 마스터 1:1 복제 (사용하는 마스터마다 반드시)

```bash
pdftoppm -png -r 150 -singlefile \
  "/tmp/deck-wt/slide-master/<이름>.pdf" /tmp/master-<id>
```

서브에이전트에 위임:
> "이 PNG를 읽고 다음을 **CSS 값(px·%·hex·flex 속성) 수준**으로 보고하라:
> 배경색·그라디언트 / 각 요소의 position·top·left·width·height / 폰트 크기·굵기·색 / gap·padding·margin / 연결선·구분선 위치·두께 / **마스터에 없는 요소 목록** (없는 건 추가 금지)"

"헤드라인이 크고 굵다" 수준의 묘사는 불충분 — 픽셀 좌표와 정확한 속성값이 있어야 1:1 복제 가능.

#### 4-5. 빌드 규칙

- 슬라이드 = `<section data-screen-label="NN 라벨">`, `<deck-stage>` 안, 1920×1080
- §10 전부 적용: 다크는 표지·인사+임팩트 1~2장만(18) · 뱃지/카드 단일스펙(19) · 수직그리드·hollow 금지(20) · 선언 액자금지(21) · 24px floor · 한국어 word-break: keep-all
- 분량 많으면 Sonnet 서브에이전트(`Agent`)에 슬라이드 명세 위임 가능

#### 4-6. 이미지·도식 포함

슬라이드에 이미지나 도식이 필요할 때 맥락에 따라 아래 방법을 선택한다.

**A. 개념 비유·일러스트 (권장: 인라인 SVG 생성)**
- 정상림·나무 성장·파이프라인·흐름도 등 개념적 이미지 → SVG 코드로 직접 생성
- 슬라이드 내 `<svg viewBox="0 0 W H">` 인라인 삽입 — 외부 의존 없음, 벡터 선명

**B. 사진·실사 이미지 (웹 검색 → 임시 URL 또는 base64)**
- WebSearch로 관련 이미지 검색 (Unsplash, Pexels 등 라이선스 확인)
- `curl` 다운로드 → `~/Downloads/<덱>-deck/assets/` 저장 → `<img src="assets/파일명">`
- CDN 업로드 가능 시 `cdn.thetrive.com` URL 사용

**C. 브랜드 에셋·로고 (Figma MCP)**
- `get_screenshot(fileKey, nodeId)` → curl 다운로드 → `assets/` 저장 → `<img src="assets/logo.png">`
- Figma URL에 `?node-id=` 있으면 바로; 없으면 `get_metadata`로 nodeId 먼저 찾기
- ⚠️ `get_design_context`는 Figma 앱에서 레이어가 선택된 상태여야 함 → **항상 `get_screenshot` 사용**
- **배경이 있는 PNG를 다크 슬라이드에 쓸 때**: PIL로 배경 픽셀을 투명화한 뒤 사용
  ```python
  from PIL import Image
  import numpy as np
  img = Image.open('logo.png').convert('RGBA')
  data = np.array(img)
  r, g, b, a = data[:,:,0], data[:,:,1], data[:,:,2], data[:,:,3]
  # 어두운 단색 배경 픽셀 제거 (R≈G≈B이고 어두우면 투명 처리)
  gray_mask = (abs(r.astype(int)-g.astype(int)) < 20) & \
              (abs(g.astype(int)-b.astype(int)) < 20) & (r < 70)
  data[:,:,3] = np.where(gray_mask, 0, a)
  Image.fromarray(data).save('logo-transparent.png')
  ```
- **카라멜 로고**: fileKey `EBoVMwYDtky8vW18xfrCtc`, 투명 수평 로고 nodeId `2494:2` (1113×408)
  → `assets/caramel-logo-transparent.png` 저장, `height:52px; opacity:0.85` 표지에 적용

**B-2. 사진을 슬라이드 전체 배경으로 쓸 때**
- Unsplash 다운로드 → `assets/bg.jpg` → section background-image + 다크 오버레이
  ```html
  <section style="overflow:hidden; background:#000;">
    <div style="position:absolute; inset:0; background-image:url('assets/bg.jpg'); background-size:cover; background-position:center;"></div>
    <div style="position:absolute; inset:0; background:linear-gradient(to bottom, rgba(0,0,0,0.72) 0%, rgba(0,0,0,0.55) 50%, rgba(0,0,0,0.78) 100%);"></div>
    <!-- 텍스트에 text-shadow 추가 -->
    <h2 style="text-shadow: 0 2px 32px rgba(0,0,0,0.6);">...</h2>
  </section>
  ```

**D. 데이터 차트·막대 (인라인 SVG 유지)**
- 현재 방식(inline SVG) 최적 — 픽셀 퍼펙트 + 의존성 없음

**타임라인 2×2 정렬 주의 (2026-06-10 학습):**
구분선 기준 위/아래에 높이가 다른 블록을 배치할 때는 반드시 `bottom` 고정 사용.
```css
/* 구분선 위 블록: bottom 고정 → 하단이 라인으로부터 항상 일정 거리 */
position: absolute; bottom: [1080 - (line_top - gap)]px;
/* 구분선 아래 블록: top 고정 → 상단이 라인으로부터 일정 거리 */
position: absolute; top: [line_top + gap]px;
```
`top` 고정은 콘텐츠 높이가 모두 동일할 때만. 높이가 다를 수 있으면 반드시 `bottom` 고정.

---

### Phase 5 — 렌더 검증 + 보여주기

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=/tmp/deck.pdf "file://<HTML절대경로>"
pdftoppm -png -r 90 /tmp/deck.pdf /tmp/d/s
```

1. **전수 겹침/잘림 점검 (게이트)** — 서브에이전트에 위임, 0건이어야 통과. 메인은 PNG Read 금지.
2. **(선택) 평가→근본원인→재빌드 루프** — 점수+근본원인 텍스트 보고 회수. 9점대까지 반복.
3. **보여주기**: HTML+PDF+assets/를 `~/Downloads/<덱>-deck/`에 묶어 전달.
   - HTML은 로컬 자산 경로(`assets/`)를 참조하므로 반드시 **assets/ 폴더**를 함께 전달한다.
4. **직접 확인 (필수)**: `open ~/Downloads/<덱>-deck/<덱>.pdf` 로 PDF를 직접 열어 사람 눈으로 확인한다.
   - 로고 박스, 간격 팽창, 이미지 미표시 등은 서브에이전트가 잡지 못할 수 있다.
   - 결함 발견 시 "결함 없음" 판정이 나올 때까지 수정 → 재렌더 → 재확인 루프 반복. 중간에 멈추지 않는다.
5. **피드백 루프**: 사용자 지적 → 시스템 원인(마스터 충실·배경·뱃지) 단위로 고쳐 재빌드.

---

### Phase 6 — 산출 마무리

- **산출물 = `~/Downloads/<덱>-deck/`의 HTML+PDF.** 여기서 끝.
- **caramel-decks 레포에는 커밋하지 않는다.** 레포는 디자인 시스템(`styles.css`·`deck-stage.js`·`slide-master/`) + 누적 원칙(`CLAUDE.md`) + `layouts.md`·brief 템플릿 전용이다. 덱 `.html`은 레포에 올리지 않는다.
- 디자인 시스템·원칙 변경 시에는 브랜치+PR (이건 항상).

---

## 가드레일

- "PPTX로 만들어줘" → "산출은 HTML이고 공유 시 export"로 안내
- `~/caramel-decks` 외 일회성 슬라이드(학습용 1장, 비-카라멜)면 brief 워크플로우 과함 → 직접 빌드 분기
- "슬라이드 만들어줘"만 오면 Phase 1부터. 추측 금지.

---

## 새 덱 시작 체크리스트

- [ ] `git fetch origin` → `/tmp/deck-wt` worktree 생성 (`slide-master/` 25개 확인)
- [ ] `CLAUDE.md §10` 전부 Read (학습 원칙 1~24)
- [ ] `layouts.md` · `styles.css` · `briefs/_template.md` Read
- [ ] **`.html` 기존 덱 Read 금지** — 보일러플레이트(§4-2) 사용
- [ ] Phase 1 인터뷰 → Phase 2 자료 수집 → brief.md 작성
- [ ] 슬라이드↔마스터 매핑 초안 → 사용자 confirm
- [ ] 각 마스터 PDF pdftoppm 렌더 → 서브에이전트가 CSS 스펙 보고 → 1:1 빌드
- [ ] 렌더(PDF→PNG) → **서브에이전트 전수 검수 → 겹침/잘림 0 통과**
- [ ] `open <PDF>` 로 직접 열어 눈으로 확인 — 로고 박스, 간격 팽창, 사진 미표시 등 점검
- [ ] 결함 있으면 수정 → 재렌더 → 재확인 반복. 결함 없을 때만 전달
- [ ] HTML + PDF + **assets/** 폴더를 `~/Downloads/<덱>-deck/`에 묶어 전달
- [ ] caramel-decks에 커밋하지 않음 (원칙/시스템 변경이 있을 때만 PR)

---

## /townhall과의 관계

`/townhall`은 격주 타운홀 전용 데이터 수집기. Phase 1-3(Slack/Obsidian/Linear/MySQL/GitHub 2주치 자동 수집·검증)까지 자체 진행 → 이 스킬의 빌드·검증 단계로 진입한다.
