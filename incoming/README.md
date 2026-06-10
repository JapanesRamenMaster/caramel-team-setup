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
