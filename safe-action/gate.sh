#!/bin/bash
# 안전 액션 레이어 세팅 게이트 (SessionStart, update.sh 뒤에 실행).
# 세팅 자가체크 → 마커 파일 기록 → 하트비트 append → 요약 출력.
# SessionStart는 세션을 차단 못 하므로, 실제 차단은 enforce.py(PreToolUse)가 이 마커를 읽어 수행.
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SA_DIR="$INSTALL_DIR/safe-action"
WORK_DIR="$HOME/caramel-claude"
CONFIG_FILE="$WORK_DIR/.setup-config"
SETTINGS_FILE="$HOME/.claude/settings.json"

# 팀원 셋업이 아닌 머신(.setup-config 없음 = 메인테이너 등)은 관찰 대상이 아니므로 조용히 종료.
# (안 그러면 현황판에 버전 미상 FAIL로 노이즈가 낀다.)
[ -f "$CONFIG_FILE" ] || exit 0

# config.json에서 값 읽기 (python3로 안전 파싱)
read_cfg() { python3 -c "import json;print(json.load(open('$SA_DIR/config.json')).get('$1',''))" 2>/dev/null; }
STATE_FILE=$(read_cfg GATE_STATE_FILE); STATE_FILE="${STATE_FILE/#\~/$HOME}"
LATEST_VERSION=$(read_cfg LATEST_VERSION)
[ -z "$STATE_FILE" ] && STATE_FILE="$HOME/.claude/.safe-action-gate-state"
[ -z "$LATEST_VERSION" ] && LATEST_VERSION=7
PHASE=$(read_cfg SAFE_ACTION_PHASE); [ -z "$PHASE" ] && PHASE=0

reasons=""
add() { reasons="${reasons:+$reasons; }$1"; }

# 1) 버전
cur_ver=$(grep "^SETUP_VERSION=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
[ "${cur_ver:-0}" -lt "$LATEST_VERSION" ] 2>/dev/null && add "버전 stale(v${cur_ver:-?}<v$LATEST_VERSION)"
# 2~4) 훅 등록
grep -q "caramel-team-setup/update.sh" "$SETTINGS_FILE" 2>/dev/null || add "update.sh 훅 미등록"
grep -q "safe-action/gate.sh"          "$SETTINGS_FILE" 2>/dev/null || add "gate.sh 훅 미등록"
# enforce.py는 Phase 1+에서만 등록됨 → Phase 0에선 부재가 정상(실패로 치지 않음)
if [ "${PHASE:-0}" -ge 1 ] 2>/dev/null; then
  grep -q "safe-action/enforce.py"     "$SETTINGS_FILE" 2>/dev/null || add "enforce.py 훅 미등록"
fi

if [ -z "$reasons" ]; then status="PASS"; else status="FAIL"; fi

# 마커 기록 (enforce.py가 읽음) — 값은 env로 넘겨 인젝션/따옴표 깨짐 방지
mkdir -p "$(dirname "$STATE_FILE")"
SA_STATUS="$status" SA_REASONS="$reasons" SA_VERSION="${cur_ver:-}" SA_STATE="$STATE_FILE" \
python3 -c "
import json, os
json.dump({'status': os.environ['SA_STATUS'], 'reasons': os.environ['SA_REASONS'],
           'version': os.environ['SA_VERSION']},
          open(os.environ['SA_STATE'], 'w'), ensure_ascii=False)
" 2>/dev/null

# 하트비트 (best-effort, 1일 1회 throttle; node 없으면 조용히 스킵)
NAME=$(grep "^EMAIL=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
[ -z "$NAME" ] && NAME=$(grep "^ROLE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
[ -z "$NAME" ] && NAME="$USER"
HEARTBEAT_STAMP="$HOME/.claude/.safe-action-heartbeat-date"
TODAY_KST=$(TZ='Asia/Seoul' date +%Y-%m-%d 2>/dev/null)
if [ "$(cat "$HEARTBEAT_STAMP" 2>/dev/null)" != "$TODAY_KST" ] && command -v node >/dev/null 2>&1; then
  node "$SA_DIR/heartbeat.js" "$NAME" "$(hostname)" "${cur_ver:-}" "$status" "$reasons" \
    "${CLAUDE_SESSION_ID:-$$}" 2>/dev/null &
  echo "$TODAY_KST" > "$HEARTBEAT_STAMP"
fi

# 요약 (additionalContext로 모델/사용자에 노출)
if [ "$status" = "PASS" ]; then
  echo "[안전세팅] 정상 — 가드 체인 OK, v${cur_ver}."
elif [ "${PHASE:-0}" -ge 1 ] 2>/dev/null; then
  echo "[안전세팅] ⚠️ 깨짐 → 도구 사용이 차단됩니다. 사유: $reasons"
  echo "  복구: 터미널에서  bash ~/.caramel-team-setup/update.sh  실행 후 새 세션."
  echo "  그래도 안 되면  bash ~/.caramel-team-setup/team-diagnose.sh  결과를 맹주성님께."
else
  echo "[안전세팅] 점검: 일부 항목 미달(기록됨, 관찰 단계라 차단 안 함). 사유: $reasons"
fi
exit 0
