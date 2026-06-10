# 카라멜 스킬 카탈로그 — 설계 스펙

**작성일**: 2026-06-10
**상태**: 설계 확정, 구현 대기

---

## 배경 및 목적

팀원끼리 Claude Code 스킬을 Slack MD 파일로 주고받다가 비가역 사이드 이펙트(고객 알림톡 발송 등)가 의도치 않게 실행되는 사고가 발생함. 근본 원인: 스킬 파일에 환경 가정, 사이드 이펙트, 실행 권한 메타데이터가 없음.

**목표**:
- 팀 공용 스킬을 안전하게 공유·탐색·설치하는 플랫폼 구축
- 스킬에 거버넌스 메타데이터(프론트매터) 자동 보강
- SSOT는 GitHub, 사이트는 읽기 전용 뷰

---

## 아키텍처 개요

```
팀원
 ├─ Slack #caramel_스킬공유 → md 공유
 └─ GitHub PR → caramel-team-setup/incoming/

        ↓ 두 채널 모두

[AI 파이프라인]
 ├─ 차비스(슬랙봇): Slack 메시지 감지 → md 파싱
 └─ GitHub Action: incoming/ 감지 → 파일 읽기
        ↓ 공통
 Claude API (Opus + 카라멜 컨텍스트)
  - 스킬 분석 → 프론트매터 보강
  - caramel-team-setup/skills/에 PR 자동 생성
        ↓
 맹주성님 PR 승인 → merge

        ↓

[caramel-team-setup/skills/] ← SSOT (GitHub)

        ↓

[카탈로그 사이트] (Vercel)
 - GitHub API로 skills/ 실시간 읽기
 - 검색/필터/태그 탐색
 - 설치 커맨드 클립보드 복사
 - 스킬 제출 양식 (→ GitHub PR 생성)
```

---

## 프론트매터 표준

팀 공용 스킬의 거버넌스 계약서. AI가 제출된 스킬을 분석해 자동으로 채움.

```yaml
---
name: clean-multi-reservations
description: 동일 차량 다중 예약 자동 정리
scope: team                    # team | personal (카탈로그 노출 여부)
owner: sungjiwon               # 관리자 GitHub username
side-effects:                  # 비가역 액션 목록
  - db-write
  - notification
requires:                      # 없으면 실행 불가한 것들
  - CARAMEL_API_KEY
disable-model-invocation: true # AI 자동 실행 차단 여부
tags:
  - 예약
  - 고객관리
---
```

**필수**: `scope`, `side-effects`, `owner`
**선택**: `requires`, `disable-model-invocation`, `tags`

`side-effects` 허용값: `db-write`, `db-read`, `notification`, `slack-send`, `file-write`, `deploy`, `api-call`

---

## AI 보강 파이프라인

**입력**: 팀원이 작성한 날것의 스킬 md (프론트매터 없거나 불완전)

**처리 (Claude Opus)**:
1. 스킬 본문 읽고 수행 액션 파악
2. `side-effects` 추론
3. `disable-model-invocation` 필요 여부 판단 (비가역 액션 있으면 `true` 자동 설정)
4. `requires` 추출 (환경변수, API키, 특정 레포 접근 등)
5. `tags` 생성
6. 카라멜 컨텍스트 기준 스킬 설명 다듬기

**출력**: 프론트매터 완성된 스킬 파일 + GitHub PR

PR 형식:
```
제목: [스킬 제출] {name} — by @{submitter}
본문:
  - 제출 경로: Slack | GitHub PR
  - 제출자: {submitter}
  - side-effects: {list}
  - ⚠️ disable-model-invocation: true 자동 설정됨 (비가역 액션 감지) [해당 시]
  - 검토 후 승인해주세요
```

**트리거 경로**:
- **Slack**: 차비스가 `#caramel_스킬공유` 채널 리스닝 → md 파일 감지 → 파이프라인 호출
- **GitHub**: `incoming/` 폴더에 파일 push/PR → GitHub Action 트리거 → 파이프라인 호출
- 두 경로 모두 동일한 Claude API 보강 로직 공유

---

## 카탈로그 사이트

**기술 스택**: Next.js App Router + Tailwind CSS, Vercel 배포, GitHub API (skills/ 실시간 읽기), Vercel Edge Cache (TTL 5분)

**레포**: `the-trive/caramel-skills-catalog` (신규 생성)

**라우트**:
- `/` — 스킬 목록 (메인)
- `/skills/[name]` — 스킬 상세
- `/submit` — 제출 양식

**접근 제어**: 없음 (URL 아는 팀원만)

### 메인 페이지 (`/`)
- 스킬 카드 그리드
- 검색바 (name, description, tags 대상)
- 태그 필터 (멀티셀렉트)
- 뱃지: 🔴 사이드 이펙트 있음 / 🔒 사람만 실행
- 카드마다 "설치 커맨드 복사" 버튼

### 스킬 상세 페이지 (`/skills/[name]`)
- 스킬명 + 뱃지 (🔒, 🔴)
- 설명, 태그, 관리자
- ⚠️ 사이드 이펙트 목록 (있을 시 강조)
- 전제조건 체크리스트 (`requires`)
- 설치 커맨드 + 클립보드 복사 버튼
- 스킬 본문 마크다운 렌더링

### 설치 커맨드 형식
```bash
curl -fsSL https://raw.githubusercontent.com/the-trive/caramel-team-setup/main/skills/{name} \
  -o ~/.claude/skills/{name}
```

### 제출 양식 (`/submit`)
- md 파일 업로드 or 텍스트 붙여넣기
- 제출자 이름/슬랙 핸들 입력
- "제출" → GitHub API로 `incoming/{name}` 파일 생성 → Action 트리거
- 완료 후 PR 링크 안내

---

## 레포 구조 변경 (caramel-team-setup)

```
caramel-team-setup/
  skills/             ← 기존 (팀 공용 스킬 SSOT)
  incoming/           ← 신규 (AI 보강 전 제출 대기)
  docs/
    superpowers/specs/
      2026-06-10-skill-catalog-design.md
  .github/
    workflows/
      skill-review.yml  ← 신규 (incoming/ 감지 → AI 파이프라인)
```

---

## 구현 범위 (이번 프로젝트)

**IN**:
- 프론트매터 표준 정의 + 기존 스킬 11개 마이그레이션
- GitHub Action (incoming/ → AI 보강 → PR)
- 차비스 Slack 채널 리스닝 + 파이프라인 연동
- 카탈로그 사이트 (목록/상세/제출)
- `/install-skill` Claude Code 스킬 (팀원 로컬 설치용)

**OUT (이번 범위 아님)**:
- 조회수/평점/댓글
- 스킬 버전 히스토리 UI (git log로 대체)
- 팀원 인증/로그인
- 스킬 자동 테스트

---

## 성공 기준

1. 팀원이 Slack에 md 올리면 10분 내 PR이 자동 생성됨
2. PR에 side-effects, disable-model-invocation 프론트매터가 정확히 채워져 있음
3. 카탈로그 사이트에서 스킬 검색 → 설치 커맨드 복사까지 30초 안에 가능
4. 비가역 스킬은 🔒🔴 뱃지로 명확히 구분됨
