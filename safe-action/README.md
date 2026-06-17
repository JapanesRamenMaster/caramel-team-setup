# 안전 액션 레이어 — 준수 가시성

세팅이 깨진 팀원은 Claude 도구 사용이 차단되고, 정상 세션은 중앙 시트에 하트비트를 남깁니다.

## 구성
- `gate.sh` (SessionStart): 세팅 자가체크 → 마커 기록 → 하트비트 append
- `enforce.py` (PreToolUse): 마커 FAIL이면 모든 도구 deny (fail-closed)
- `heartbeat.js`: node 빌트인으로 시트 append (외부 패키지 불필요)
- `setup-sheet.py`: 하트비트 시트 1회 생성 (메인테이너 전용)
- `config.json`: 시트 ID·경로 설정
- 현황판: 시트 `현황판` 탭 (자동 갱신) — 메인테이너가 아침에 확인

## 차단됐을 때 (팀원)
1. 터미널에서 `bash ~/.caramel-team-setup/update.sh` 실행 → 새 세션
2. 안 되면 `bash ~/.caramel-team-setup/team-diagnose.sh` 결과를 맹주성님께

## 긴급 우회 (메인테이너 전용)
가드 버그로 팀이 갇히면: `touch ~/.claude/.safe-action-gate-disable` → enforce 통과.
원인 수정 후 `rm ~/.claude/.safe-action-gate-disable`.

## 신뢰 경계
로컬 훅이라 작정하고 떼면 우회 가능(spec "신뢰 경계" 참조). 평소 쓰던 사람의 하트비트 끊김이 알림 신호. 진짜 강제는 B단계 계정 권한.
