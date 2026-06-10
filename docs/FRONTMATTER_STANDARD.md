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

```yaml
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
```

## 규칙

1. `side-effects`가 `notification` 또는 `db-write`를 포함하면 `disable-model-invocation: true` 필수
2. `scope: team`인 스킬은 반드시 `owner` 명시
3. 부작용이 전혀 없으면 `side-effects: []` 명시 (누락과 구분)
