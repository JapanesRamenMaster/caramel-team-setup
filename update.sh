#!/bin/bash
# caramel-team-setup 자동 업데이트 스크립트
# Claude Code SessionStart 훅에서 호출됨
# - git pull로 최신 코드 반영
# - 버전 기반 마이그레이션으로 구조적 변경 자동 적용
# - 매 세션 날짜 갱신

# 스크립트 자기 위치를 INSTALL_DIR로 사용 (어디 클론되어 있든 동작)
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$HOME/caramel-claude"
CONFIG_FILE="$WORK_DIR/.setup-config"

# === 최신 버전 (새 마이그레이션 추가 시 이 숫자를 올리고 아래에 로직 추가) ===
LATEST_VERSION=7

# SSH deploy key for code repo (setup.sh와 동일)
DEPLOY_KEY_PATH="$HOME/.ssh/caramel-deploy-key"

# Google Sheets 서비스 계정 키 다운로드 URL (setup.sh와 동일)
SHEETS_KEY_URL="https://drive.google.com/uc?export=download&id=1IDdvvu7k3v7R2zjptVKADhX97fsUGxZ4"

# Deploy keys tarball (setup.sh와 동일) — v6 마이그레이션에서 caramel-decks 키 추출용
DEPLOY_KEYS_URL="https://drive.google.com/uc?export=download&id=1vgZClzDTcTlnEpcfSrxfQNVLMy5qnJ6D"

cd "$INSTALL_DIR" || exit 0

# 1) Pull 전 상태 저장
#    재실행된 프로세스에선 env로 넘겨받은 원래 OLD_HEAD를 우선 사용한다.
#    (안 그러면 pull 이후 rev-parse가 NEW와 같아져서 아래 전파 블록이 통째로 스킵됨 — 과거 버그)
OLD_HEAD="${CARAMEL_OLD_HEAD:-$(git rev-parse HEAD 2>/dev/null)}"

# 2) Pull (fast-forward only, 충돌 방지)
git pull --ff-only 2>/dev/null || true

# 3) Pull 후 상태 비교 → 변경 시 새 스크립트로 재실행
NEW_HEAD=$(git rev-parse HEAD 2>/dev/null)

if [ "$OLD_HEAD" != "$NEW_HEAD" ] && [ "${CARAMEL_UPDATE_REEXEC:-}" != "1" ]; then
  # update.sh 자체가 변경됐을 수 있으므로 새 버전으로 재실행. OLD_HEAD를 넘겨 전파가 스킵되지 않게 함.
  export CARAMEL_UPDATE_REEXEC=1
  export CARAMEL_OLD_HEAD="$OLD_HEAD"
  exec "$INSTALL_DIR/update.sh" "$@"
fi
unset CARAMEL_UPDATE_REEXEC CARAMEL_OLD_HEAD

if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
  # 4) 스킬 심링크 재생성 (새 스킬 포함)
  SKILLS_DIR="$HOME/.claude/skills"
  mkdir -p "$SKILLS_DIR"
  for skill_dir in "$INSTALL_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    ln -sfn "$skill_dir" "$SKILLS_DIR/$skill_name"
  done

  # 5) 참조 문서 + 헬퍼 스크립트 + grafana-audit 도구 업데이트
  if [ -d "$WORK_DIR" ]; then
    cp "$INSTALL_DIR/QUERY_REFERENCE.md" "$WORK_DIR/" 2>/dev/null || true
    cp "$INSTALL_DIR/DB_SCHEMA.md" "$WORK_DIR/" 2>/dev/null || true
    cp "$INSTALL_DIR/mysql-query.sh" "$WORK_DIR/mysql-query.sh" 2>/dev/null || true
    chmod +x "$WORK_DIR/mysql-query.sh" 2>/dev/null || true
    cp "$INSTALL_DIR/mysql-cols.sh" "$WORK_DIR/mysql-cols.sh" 2>/dev/null || true
    chmod +x "$WORK_DIR/mysql-cols.sh" 2>/dev/null || true
    # grafana-audit 도구 (CBR 작업용) — setup.sh와 동일하게 매 업데이트마다 갱신
    if [ -d "$INSTALL_DIR/tools/grafana-audit" ]; then
      mkdir -p "$WORK_DIR/tools/grafana-audit"
      cp -R "$INSTALL_DIR/tools/grafana-audit/." "$WORK_DIR/tools/grafana-audit/" 2>/dev/null || true
      chmod +x "$WORK_DIR/tools/grafana-audit/"*.sh 2>/dev/null || true
    fi
  fi

  # 6) 변경사항 요약 출력 (Claude Code에 표시됨)
  echo "caramel-team-setup 업데이트:"
  git log --oneline "$OLD_HEAD".."$NEW_HEAD" | while read line; do
    echo "  $line"
  done
fi

# 6.5) CLAUDE.md (재)생성 — 베이스 규칙 전파(HEAD 변경) 또는 마커 없음(legacy/깨짐) 시 자가복구.
#      역할은 .setup-config에서 보존, 개인 메모는 END 마커 아래 보존. (build-claude-md.sh)
if [ -d "$WORK_DIR" ] && [ -f "$INSTALL_DIR/build-claude-md.sh" ]; then
  if [ "$OLD_HEAD" != "$NEW_HEAD" ] || ! grep -qF "TEAM-SETUP:BEGIN" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
    ROLE_CFG=""
    [ -f "$CONFIG_FILE" ] && ROLE_CFG=$(grep "^ROLE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    bash "$INSTALL_DIR/build-claude-md.sh" "$INSTALL_DIR" "$WORK_DIR" "$ROLE_CFG" >&2 || true
  fi
fi

# ============================================================
# 7) SessionStart 훅 등록 상태 검증 + 복구 (자가 치유)
#    - 다른 도구가 settings.json을 덮어써서 훅이 사라진 경우 자동 복구
#    - 글로벌 + 프로젝트 레벨 모두 검증
#    - WORK_DIR 존재 여부와 무관하게 항상 실행
# ============================================================
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_CMD="$HOME/.caramel-team-setup/update.sh 2>/dev/null || true"

ensure_hook() {
  local target_file="$1"
  [ -f "$target_file" ] || return 0

  # 이미 등록되어 있으면 스킵 (grep으로 확인 — jq 없어도 동작)
  if grep -q "caramel-team-setup/update.sh" "$target_file" 2>/dev/null; then
    return 0
  fi

  if command -v jq &>/dev/null; then
    # jq 있으면 정확한 JSON 조작
    if jq -e '.hooks.SessionStart' "$target_file" &>/dev/null 2>&1; then
      jq --arg cmd "$HOOK_CMD" \
        '.hooks.SessionStart += [{"type": "command", "command": $cmd}]' \
        "$target_file" > "${target_file}.tmp" && mv "${target_file}.tmp" "$target_file"
    else
      jq --arg cmd "$HOOK_CMD" \
        '.hooks.SessionStart = [{"type": "command", "command": $cmd}]' \
        "$target_file" > "${target_file}.tmp" && mv "${target_file}.tmp" "$target_file"
    fi
  elif command -v python3 &>/dev/null; then
    # jq 없으면 python3 fallback
    python3 -c "
import json, sys
with open('$target_file', 'r') as f:
    data = json.load(f)
hook = {'type': 'command', 'command': '$HOOK_CMD'}
if 'hooks' not in data:
    data['hooks'] = {}
if 'SessionStart' not in data['hooks']:
    data['hooks']['SessionStart'] = []
data['hooks']['SessionStart'].append(hook)
with open('$target_file', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null
  else
    return 0
  fi
  echo "caramel-team-setup: SessionStart 훅 복구됨 ($(basename $(dirname "$target_file")))"
}

# 안전 액션 레이어 훅 보강: gate.sh(SessionStart) + enforce.py(PreToolUse)
ensure_safe_action_hooks() {
  local target_file="$1"
  [ -f "$target_file" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local gate_cmd="$INSTALL_DIR/safe-action/gate.sh"
  local py; py="$(command -v python3 || echo /usr/bin/python3)"
  local enforce_cmd="$py $INSTALL_DIR/safe-action/enforce.py"

  GATE_CMD="$gate_cmd" ENFORCE_CMD="$enforce_cmd" TARGET="$target_file" python3 - <<'PYEOF'
import json, os
target = os.environ["TARGET"]
gate_cmd = os.environ["GATE_CMD"]
enforce_cmd = os.environ["ENFORCE_CMD"]
try:
    with open(target) as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
hooks = data.setdefault("hooks", {})

def has(cmd_substr, groups):
    return any(cmd_substr in h.get("command", "")
               for g in groups for h in g.get("hooks", []))

ss = hooks.setdefault("SessionStart", [])
if not has("safe-action/gate.sh", ss):
    ss.append({"matcher": "", "hooks": [{"type": "command", "command": gate_cmd}]})

pre = hooks.setdefault("PreToolUse", [])
if not has("safe-action/enforce.py", pre):
    pre.append({"matcher": "", "hooks": [{"type": "command", "command": enforce_cmd, "timeout": 5}]})

with open(target, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
}

# 글로벌 settings.json 검증
ensure_hook "$SETTINGS_FILE"
ensure_safe_action_hooks "$SETTINGS_FILE"

# 프로젝트 레벨 settings.json 검증
PROJECT_SETTINGS="$WORK_DIR/.claude/settings.json"
if [ -d "$WORK_DIR" ]; then
  if [ ! -f "$PROJECT_SETTINGS" ]; then
    mkdir -p "$WORK_DIR/.claude"
    echo '{}' > "$PROJECT_SETTINGS"
  fi
  ensure_hook "$PROJECT_SETTINGS"
  ensure_safe_action_hooks "$PROJECT_SETTINGS"
fi

# ============================================================
# 8) 버전 기반 마이그레이션
#    - 새 구조적 변경이 있으면 LATEST_VERSION을 올리고 여기에 추가
#    - 각 마이그레이션은 멱등성(idempotent) 보장
# ============================================================

[ ! -d "$WORK_DIR" ] && exit 0

# 현재 설치된 버전 확인
CURRENT_VERSION=0
if [ -f "$CONFIG_FILE" ]; then
  CURRENT_VERSION=$(grep "^SETUP_VERSION=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
  CURRENT_VERSION=${CURRENT_VERSION:-0}
fi

if [ "$CURRENT_VERSION" -lt "$LATEST_VERSION" ] 2>/dev/null; then
  # 저장된 설정 로드
  ROLE=""
  EMAIL=""
  if [ -f "$CONFIG_FILE" ]; then
    ROLE=$(grep "^ROLE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    EMAIL=$(grep "^EMAIL=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
  fi

  MIGRATED=""

  # --- Migration v1 → v2: 코드 레포, 날짜 마커, CLAUDE.md 역할 섹션 ---
  if [ "${CURRENT_VERSION}" -lt 2 ]; then

    # 2a) 코드 레포 클론 (SSH deploy key 방식 — GitHub 계정 불필요)
    REPOS_DIR="$WORK_DIR/repos"
    if [ ! -d "$REPOS_DIR/caramel-all/.git" ]; then
      if [ -f "$DEPLOY_KEY_PATH" ]; then
        mkdir -p "$REPOS_DIR"
        GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
        git clone --depth 1 --recurse-submodules --shallow-submodules \
          "git@github.com:the-trive/caramel-all.git" \
          "$REPOS_DIR/caramel-all" 2>/dev/null && {
          MIGRATED="$MIGRATED 코드레포"
        } || true
      fi
    fi

    # 2b) CLAUDE.md에 코드 레포 섹션 추가 (없으면)
    if [ -d "$REPOS_DIR/caramel-all/.git" ] && ! grep -q "## 코드 레포" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      # DATE_MARKER 앞에 삽입
      if grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md"; then
        LINE_NUM=$(grep -n "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
        head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
        echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
        cat >> "$WORK_DIR/CLAUDE.md.tmp" << 'REPOEOF'
## 코드 레포

리팩토링으로 **고객 앱은 caramel-zero**, **디테일러앱/어드민은 caramel-all** 로 분리되어 있어. 코드 질문이 오면 아래 매핑에 따라 올바른 레포부터 검색할 것.

### `repos/caramel-zero/` — 신규 고객 앱 (Turborepo)
- `apps/customer-app/` — 고객 모바일 앱 (React Native / Expo)
- `apps/web/` — 고객 웹
- `apps/api/` — 고객 앱 API
- `packages/` — 공용 패키지 (date-common, refund-common, typescript-config)
- 고객 앱·웹·API 관련 질문은 **여기를 먼저 검색**

### `repos/caramel-all/` — 어드민/디테일러 (모노레포)
- `caramel-detailer-app/` — 디테일러 앱
- `caramel-sales-admin/` — 영업 어드민
- 그 외 서브모듈(`caramel-app`, `caramel-api`, `careplus-web`)은 리팩토링 이전 코드 — 참조용으로만 보고, 현행 동작 확인이 필요하면 caramel-zero를 우선

### 공통 규칙
- 코드는 **읽기 전용**. 절대 수정하지 말 것
- 어느 레포를 봐야 할지 불확실하면 사용자에게 먼저 확인
REPOEOF
        echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
        tail -n "+$LINE_NUM" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
        mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
      else
        echo "" >> "$WORK_DIR/CLAUDE.md"
        cat >> "$WORK_DIR/CLAUDE.md" << 'REPOEOF'
## 코드 레포

리팩토링으로 **고객 앱은 caramel-zero**, **디테일러앱/어드민은 caramel-all** 로 분리되어 있어. 코드 질문이 오면 아래 매핑에 따라 올바른 레포부터 검색할 것.

### `repos/caramel-zero/` — 신규 고객 앱 (Turborepo)
- `apps/customer-app/` — 고객 모바일 앱 (React Native / Expo)
- `apps/web/` — 고객 웹
- `apps/api/` — 고객 앱 API
- `packages/` — 공용 패키지 (date-common, refund-common, typescript-config)
- 고객 앱·웹·API 관련 질문은 **여기를 먼저 검색**

### `repos/caramel-all/` — 어드민/디테일러 (모노레포)
- `caramel-detailer-app/` — 디테일러 앱
- `caramel-sales-admin/` — 영업 어드민
- 그 외 서브모듈(`caramel-app`, `caramel-api`, `careplus-web`)은 리팩토링 이전 코드 — 참조용으로만 보고, 현행 동작 확인이 필요하면 caramel-zero를 우선

### 공통 규칙
- 코드는 **읽기 전용**. 절대 수정하지 말 것
- 어느 레포를 봐야 할지 불확실하면 사용자에게 먼저 확인
REPOEOF
      fi
    fi

    # 2c) CLAUDE.md에 역할 섹션 추가 (없으면)
    if [ -n "$ROLE" ] && ! grep -q "## 이 사용자의 역할" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      # 간단하게 CLAUDE.md 끝(DATE_MARKER 앞)에 추가
      if grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md"; then
        LINE_NUM=$(grep -n "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
        head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
        echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "## 이 사용자의 역할" >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "이 사용자는 카라멜 팀에서 **${ROLE}** 역할을 맡고 있습니다. 이 역할에 맞게 답변을 조정하세요." >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
        tail -n "+$LINE_NUM" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
        mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
      fi
      MIGRATED="$MIGRATED 역할섹션"
    fi

    # 2d) 날짜 마커 추가 (없으면)
    if ! grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      echo "" >> "$WORK_DIR/CLAUDE.md"
      echo "<!-- DATE_MARKER -->" >> "$WORK_DIR/CLAUDE.md"
      echo "## 현재 날짜" >> "$WORK_DIR/CLAUDE.md"
      echo "오늘은 $(date '+%Y년 %m월 %d일')입니다. 날짜 관련 질문이나 쿼리에서 이 날짜를 기준으로 하세요." >> "$WORK_DIR/CLAUDE.md"
      MIGRATED="$MIGRATED 날짜마커"
    fi

    # 2e) Google Sheets MCP dist 업데이트 (빌드 없이)
    SHEETS_DIR="$WORK_DIR/.tools/mcp-google-sheets"
    if [ -d "$SHEETS_DIR" ]; then
      cp -r "$INSTALL_DIR/tools/mcp-google-sheets/dist/." "$SHEETS_DIR/dist/" 2>/dev/null || true
    fi
  fi

  # --- Migration v2 → v3: 사용 로그 (Google Sheets 자동 기록) ---
  if [ "${CURRENT_VERSION}" -lt 3 ]; then

    # 3a) CLAUDE.md에 "작업 완료 로그" 섹션 추가 (없으면)
    if [ -f "$WORK_DIR/CLAUDE.md" ] && ! grep -q "## 작업 완료 로그" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      # "자주 하는 실수" 섹션 앞에 삽입
      if grep -q "## 자주 하는 실수" "$WORK_DIR/CLAUDE.md"; then
        LINE_NUM=$(grep -n "## 자주 하는 실수" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
        head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
        cat >> "$WORK_DIR/CLAUDE.md.tmp" << 'LOGEOF'
## 작업 완료 로그 (매 요청 처리 후 필수)

모든 사용자 요청 처리가 끝나면, 마지막 단계로 Google Sheets에 로그를 남긴다.
이 로그는 팀 업무 현황 파악용이며, 사용자에게 별도 안내하지 않는다.

### 로그 방법
1. `mcp__google-sheets__get_sheet_data`로 시트의 A열을 읽어 마지막 행 번호 확인
2. `mcp__google-sheets__update_cells`로 마지막 행 + 1에 새 행 추가
3. 실패 시 재시도하지 말고 건너뛴다 — 사용자 작업에 영향 주지 말 것

- spreadsheet_id: `1eD9aJCuZRCI95b41Oey0j-o2Mxg5iu_3QaPhMdps0aI`
- sheet: `시트1`

### 컬럼
- A: timestamp (YYYY-MM-DD HH:MM)
- B: role (CLAUDE.md의 "이 사용자의 역할"에서 가져옴)
- C: type (DB조회/노션검색/슬랙검색/문서작성/분석/시트작업/기타)
- D: summary (요청 내용 1줄 요약, 30자 이내)
- E: result (성공/실패/부분완료)

### 로깅 가드레일
- **개인정보 마스킹**: summary에 전화번호, 고객명, 주소 등 개인정보를 넣지 말 것. "특정 고객 예약 조회"처럼 추상화
- **업무 외 요청 제외**: 카라멜 업무(DB조회, 노션, 슬랙, 시트, 문서작성, 분석)와 관련 없는 요청은 로깅하지 않음
- **쿼리/검색어 원문 제외**: SQL 쿼리나 검색 키워드 원문을 summary에 포함하지 말 것

LOGEOF
        tail -n "+$LINE_NUM" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
        mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
        MIGRATED="$MIGRATED 사용로그"
      fi
    fi
  fi

  # --- Migration v3 → v4: Google Sheets MCP를 .mcp.json에 추가 + PAT 기반 코드 레포 ---
  if [ "${CURRENT_VERSION}" -lt 4 ]; then
    SHEETS_KEY_PATH="$HOME/.claude/google-sheets-key.json"
    SHEETS_NODE_PATH="$HOME/caramel-claude/.tools/mcp-google-sheets/dist/index.js"
    V4_SHEETS_OK=false

    # 4a) Google Sheets 키 파일 다운로드 (없으면) + JSON 검증
    if [ ! -f "$SHEETS_KEY_PATH" ] && [ -n "$SHEETS_KEY_URL" ]; then
      mkdir -p "$(dirname "$SHEETS_KEY_PATH")"
      curl -sL "$SHEETS_KEY_URL" -o "$SHEETS_KEY_PATH.tmp" 2>/dev/null
      # 다운로드된 파일이 JSON인지 검증
      if [ -f "$SHEETS_KEY_PATH.tmp" ] && head -c 1 "$SHEETS_KEY_PATH.tmp" | grep -q '{'; then
        mv "$SHEETS_KEY_PATH.tmp" "$SHEETS_KEY_PATH"
        MIGRATED="$MIGRATED 키파일"
      else
        rm -f "$SHEETS_KEY_PATH.tmp"
      fi
    fi

    # 4b) EMAIL 추출: .setup-config → project .mcp.json → global .mcp.json
    if [ -z "$EMAIL" ]; then
      # project .mcp.json에서 추출
      EMAIL=$(grep -o '"GOOGLE_SUBJECT"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORK_DIR/.mcp.json" 2>/dev/null | head -1 | sed 's/.*"GOOGLE_SUBJECT"[[:space:]]*:[[:space:]]*"//;s/"//')
    fi
    if [ -z "$EMAIL" ]; then
      # global .mcp.json에서 추출 (claude mcp add로 설정한 경우)
      EMAIL=$(grep -o '"GOOGLE_SUBJECT"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/.mcp.json" 2>/dev/null | head -1 | sed 's/.*"GOOGLE_SUBJECT"[[:space:]]*:[[:space:]]*"//;s/"//')
    fi

    # 4c) .mcp.json에 Google Sheets 추가 (없으면)
    if [ -f "$WORK_DIR/.mcp.json" ] && ! grep -q "google-sheets" "$WORK_DIR/.mcp.json" 2>/dev/null; then
      if [ -n "$EMAIL" ]; then
        if command -v jq &>/dev/null; then
          jq --arg cmd "node" \
             --arg args "$SHEETS_NODE_PATH" \
             --arg creds "$SHEETS_KEY_PATH" \
             --arg subject "$EMAIL" \
             '.mcpServers["google-sheets"] = {
               "type": "stdio",
               "command": $cmd,
               "args": [$args],
               "env": {
                 "GOOGLE_APPLICATION_CREDENTIALS": $creds,
                 "GOOGLE_SUBJECT": $subject
               }
             }' "$WORK_DIR/.mcp.json" > "$WORK_DIR/.mcp.json.tmp" && \
          mv "$WORK_DIR/.mcp.json.tmp" "$WORK_DIR/.mcp.json"
          MIGRATED="$MIGRATED GoogleSheets-MCP"
          V4_SHEETS_OK=true
        elif command -v python3 &>/dev/null; then
          python3 -c "
import json
with open('$WORK_DIR/.mcp.json', 'r') as f:
    data = json.load(f)
data['mcpServers']['google-sheets'] = {
    'type': 'stdio',
    'command': 'node',
    'args': ['$SHEETS_NODE_PATH'],
    'env': {
        'GOOGLE_APPLICATION_CREDENTIALS': '$SHEETS_KEY_PATH',
        'GOOGLE_SUBJECT': '$EMAIL'
    }
}
with open('$WORK_DIR/.mcp.json', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null && { MIGRATED="$MIGRATED GoogleSheets-MCP"; V4_SHEETS_OK=true; }
        fi
      fi
    else
      # 이미 google-sheets가 있으면 성공으로 간주
      V4_SHEETS_OK=true
    fi

    # 4d) 코드 레포가 없으면 deploy key로 클론 시도 (GitHub 계정 불필요)
    REPOS_DIR="$WORK_DIR/repos"
    if [ ! -d "$REPOS_DIR/caramel-all/.git" ]; then
      if [ -f "$DEPLOY_KEY_PATH" ]; then
        mkdir -p "$REPOS_DIR"
        GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
        git clone --depth 1 --recurse-submodules --shallow-submodules \
          "git@github.com:the-trive/caramel-all.git" \
          "$REPOS_DIR/caramel-all" 2>/dev/null && {
          MIGRATED="$MIGRATED 코드레포(SSH)"
          # CLAUDE.md에 레포 섹션 추가
          if ! grep -q "## 코드 레포" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
            if grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md"; then
              LINE_NUM=$(grep -n "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
              head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
              echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
              cat >> "$WORK_DIR/CLAUDE.md.tmp" << 'REPOEOF'
## 코드 레포

리팩토링으로 **고객 앱은 caramel-zero**, **디테일러앱/어드민은 caramel-all** 로 분리되어 있어. 코드 질문이 오면 아래 매핑에 따라 올바른 레포부터 검색할 것.

### `repos/caramel-zero/` — 신규 고객 앱 (Turborepo)
- `apps/customer-app/` — 고객 모바일 앱 (React Native / Expo)
- `apps/web/` — 고객 웹
- `apps/api/` — 고객 앱 API
- `packages/` — 공용 패키지 (date-common, refund-common, typescript-config)
- 고객 앱·웹·API 관련 질문은 **여기를 먼저 검색**

### `repos/caramel-all/` — 어드민/디테일러 (모노레포)
- `caramel-detailer-app/` — 디테일러 앱
- `caramel-sales-admin/` — 영업 어드민
- 그 외 서브모듈(`caramel-app`, `caramel-api`, `careplus-web`)은 리팩토링 이전 코드 — 참조용으로만 보고, 현행 동작 확인이 필요하면 caramel-zero를 우선

### 공통 규칙
- 코드는 **읽기 전용**. 절대 수정하지 말 것
- 어느 레포를 봐야 할지 불확실하면 사용자에게 먼저 확인
REPOEOF
              echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
              tail -n "+$LINE_NUM" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
              mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
            fi
          fi
        } || true
      fi
    fi

    # 4e) .setup-config에 EMAIL 추가 (없으면)
    if [ -n "$EMAIL" ] && [ -f "$CONFIG_FILE" ]; then
      if ! grep -q "^EMAIL=" "$CONFIG_FILE" 2>/dev/null; then
        echo "EMAIL=\"$EMAIL\"" >> "$CONFIG_FILE"
      fi
    fi

    # 4f) Google Sheets MCP dist 업데이트
    SHEETS_DIR="$WORK_DIR/.tools/mcp-google-sheets"
    if [ -d "$SHEETS_DIR" ]; then
      cp -r "$INSTALL_DIR/tools/mcp-google-sheets/dist/." "$SHEETS_DIR/dist/" 2>/dev/null || true
    fi

    # 4g) CLAUDE.md에 "Google Sheets 이메일 설정" 섹션 추가 (없으면)
    if [ -f "$WORK_DIR/CLAUDE.md" ] && ! grep -q "## Google Sheets 이메일 설정" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      if grep -q "## 소통 규칙" "$WORK_DIR/CLAUDE.md"; then
        LINE_NUM=$(grep -n "## 소통 규칙" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
        head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
        cat >> "$WORK_DIR/CLAUDE.md.tmp" << 'SHEETSEOF'
## Google Sheets 이메일 설정 (자동 감지)

세션 시작 시 `.mcp.json`에 `google-sheets` 서버가 없으면, 사용자에게 회사 이메일(@thetrive.com)을 물어보세요.
이메일을 받으면 아래 두 작업을 실행하세요:

1. `.setup-config`에 이메일 저장:
```bash
echo "EMAIL=이메일주소" >> ~/caramel-claude/.setup-config
```

2. `.mcp.json`에 google-sheets 서버 추가 (jq 사용):
```bash
jq --arg node "node" --arg args "$HOME/caramel-claude/.tools/mcp-google-sheets/dist/index.js" --arg creds "$HOME/.claude/google-sheets-key.json" --arg subject "이메일주소" '.mcpServers["google-sheets"] = {"type":"stdio","command":$node,"args":[$args],"env":{"GOOGLE_APPLICATION_CREDENTIALS":$creds,"GOOGLE_SUBJECT":$subject}}' ~/caramel-claude/.mcp.json > ~/caramel-claude/.mcp.json.tmp && mv ~/caramel-claude/.mcp.json.tmp ~/caramel-claude/.mcp.json
```

설정 후 사용자에게 "VS Code를 재시작하면 Google Sheets가 연결됩니다"라고 안내하세요.

SHEETSEOF
        tail -n "+$LINE_NUM" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
        mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
        MIGRATED="$MIGRATED Sheets이메일섹션"
      fi
    fi
  fi

  # --- Migration v4 → v5: 고객 앱 분리 (caramel-zero 추가) ---
  if [ "${CURRENT_VERSION}" -lt 5 ]; then
    REPOS_DIR="$WORK_DIR/repos"

    # 5a) caramel-zero 클론 (없으면)
    if [ ! -d "$REPOS_DIR/caramel-zero/.git" ]; then
      ZERO_KEY_PATH="$HOME/.ssh/caramel-deploy-caramel-zero"
      if [ -f "$ZERO_KEY_PATH" ]; then
        mkdir -p "$REPOS_DIR"
        GIT_SSH_COMMAND="ssh -i $ZERO_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
        git clone --depth 1 \
          "git@github.com:the-trive/caramel-zero.git" \
          "$REPOS_DIR/caramel-zero" 2>/dev/null && {
          MIGRATED="$MIGRATED caramel-zero"
        } || true
      else
        echo "WARNING: caramel-zero deploy key 미존재. 수동으로 한 번만 클론하세요:"
        echo "  cd $REPOS_DIR && git clone git@github.com:the-trive/caramel-zero.git"
      fi
    fi

    # 5b) CLAUDE.md '## 코드 레포' 섹션을 신규 형식으로 교체 (caramel-zero 미언급 시 = 구버전)
    if [ -f "$WORK_DIR/CLAUDE.md" ] && grep -q "^## 코드 레포" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      if ! grep -q "caramel-zero" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
        START_LINE=$(grep -n "^## 코드 레포" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
        END_LINE=$(awk -v s="$START_LINE" 'NR>s && (/^## / || /^<!-- DATE_MARKER -->/) {print NR; exit}' "$WORK_DIR/CLAUDE.md")
        if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
          head -n $((START_LINE - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
          cat >> "$WORK_DIR/CLAUDE.md.tmp" << 'REPOEOF'
## 코드 레포

리팩토링으로 **고객 앱은 caramel-zero**, **디테일러앱/어드민은 caramel-all** 로 분리되어 있어. 코드 질문이 오면 아래 매핑에 따라 올바른 레포부터 검색할 것.

### `repos/caramel-zero/` — 신규 고객 앱 (Turborepo)
- `apps/customer-app/` — 고객 모바일 앱 (React Native / Expo)
- `apps/web/` — 고객 웹
- `apps/api/` — 고객 앱 API
- `packages/` — 공용 패키지 (date-common, refund-common, typescript-config)
- 고객 앱·웹·API 관련 질문은 **여기를 먼저 검색**

### `repos/caramel-all/` — 어드민/디테일러 (모노레포)
- `caramel-detailer-app/` — 디테일러 앱
- `caramel-sales-admin/` — 영업 어드민
- 그 외 서브모듈(`caramel-app`, `caramel-api`, `careplus-web`)은 리팩토링 이전 코드 — 참조용으로만 보고, 현행 동작 확인이 필요하면 caramel-zero를 우선

### 공통 규칙
- 코드는 **읽기 전용**. 절대 수정하지 말 것
- 어느 레포를 봐야 할지 불확실하면 사용자에게 먼저 확인

REPOEOF
          tail -n "+$END_LINE" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
          mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
          MIGRATED="$MIGRATED 코드레포-v5"
        fi
      fi
    fi
  fi

  # --- Migration v5 → v6: caramel-decks (슬라이드 brief 워크플로우, write deploy key) ---
  if [ "${CURRENT_VERSION}" -lt 6 ]; then
    DECKS_KEY_PATH="$HOME/.ssh/caramel-deploy-caramel-decks"
    DECKS_ALIAS="caramel-deploy-caramel-decks"
    DECKS_URL="git@${DECKS_ALIAS}:the-trive/caramel-decks.git"
    SSH_CONFIG="$HOME/.ssh/config"

    # 6a) deploy key가 없으면 tarball에서 caramel-decks 키만 추출
    if [ ! -f "$DECKS_KEY_PATH" ] && [ -n "$DEPLOY_KEYS_URL" ]; then
      DKTMP="/tmp/caramel-decks-key-$$"
      mkdir -p "$DKTMP"
      if curl -sL "$DEPLOY_KEYS_URL" -o "$DKTMP/keys.tar.gz" 2>/dev/null \
         && tar -xzf "$DKTMP/keys.tar.gz" -C "$DKTMP" 2>/dev/null \
         && [ -f "$DKTMP/caramel-decks" ]; then
        mkdir -p "$HOME/.ssh"
        cp "$DKTMP/caramel-decks" "$DECKS_KEY_PATH"
        chmod 600 "$DECKS_KEY_PATH"
        MIGRATED="$MIGRATED decks키"
      fi
      rm -rf "$DKTMP"
    fi

    # 6b) SSH config alias 등록 (없으면)
    if [ -f "$DECKS_KEY_PATH" ] && ! grep -q "Host ${DECKS_ALIAS}" "$SSH_CONFIG" 2>/dev/null; then
      mkdir -p "$HOME/.ssh"
      cat >> "$SSH_CONFIG" << SSHEOF

Host ${DECKS_ALIAS}
    HostName github.com
    User git
    IdentityFile ${DECKS_KEY_PATH}
    IdentitiesOnly yes
    StrictHostKeyChecking no
SSHEOF
      chmod 644 "$SSH_CONFIG" 2>/dev/null || true
    fi

    # 6c) ~/caramel-decks 클론(없으면) 또는 origin을 alias URL로 보정(개인키로 클론한 경우)
    if [ -f "$DECKS_KEY_PATH" ]; then
      if [ ! -d "$HOME/caramel-decks/.git" ]; then
        git clone "$DECKS_URL" "$HOME/caramel-decks" 2>/dev/null && {
          MIGRATED="$MIGRATED caramel-decks"
        } || true
      else
        CUR_ORIGIN=$(git -C "$HOME/caramel-decks" remote get-url origin 2>/dev/null)
        if [ "$CUR_ORIGIN" != "$DECKS_URL" ]; then
          git -C "$HOME/caramel-decks" remote set-url origin "$DECKS_URL" 2>/dev/null && {
            MIGRATED="$MIGRATED decks-origin보정"
          } || true
        fi
      fi
    fi
  fi

  # --- Migration v6 → v7: 안전 액션 레이어 준수 가시성 (게이트 훅은 ensure_safe_action_hooks가 매번 보강) ---
  if [ "${CURRENT_VERSION}" -lt 7 ]; then
    # 훅 등록은 위 ensure_safe_action_hooks가 이미 처리.
    # 여기선 마커 디렉터리만 보장(첫 게이트 실행 전 enforce가 fail-closed로 막지 않게 PASS 시드).
    mkdir -p "$HOME/.claude"
    if [ ! -f "$HOME/.claude/.safe-action-gate-state" ]; then
      echo '{"status":"PASS","reasons":"초기시드","version":"7"}' > "$HOME/.claude/.safe-action-gate-state"
    fi
    MIGRATED="$MIGRATED 안전액션게이트"
  fi

  # 버전 업데이트 — Google Sheets MCP가 설정 안 됐으면 버전을 올리지 않음 (다음 세션에 재시도)
  EFFECTIVE_VERSION=$LATEST_VERSION
  if [ "$V4_SHEETS_OK" = false ] && [ "${CURRENT_VERSION}" -lt 4 ]; then
    # Google Sheets 미완료 → 버전을 3으로 유지하여 다음 세션에 재시도
    EFFECTIVE_VERSION=3
  fi

  if [ -f "$CONFIG_FILE" ]; then
    grep -v "^SETUP_VERSION=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    echo "SETUP_VERSION=$EFFECTIVE_VERSION" >> "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  else
    echo "SETUP_VERSION=$EFFECTIVE_VERSION" > "$CONFIG_FILE"
    [ -n "$ROLE" ] && echo "ROLE=\"$ROLE\"" >> "$CONFIG_FILE"
    [ -n "$EMAIL" ] && echo "EMAIL=\"$EMAIL\"" >> "$CONFIG_FILE"
  fi

  if [ -n "$MIGRATED" ]; then
    echo "caramel-team-setup 환경 업그레이드 (v${CURRENT_VERSION} → v${EFFECTIVE_VERSION}):$MIGRATED"
  fi
fi

# ============================================================
# 9) 현재 날짜 갱신 (매 세션마다 항상 실행)
# ============================================================
if [ -f "$WORK_DIR/CLAUDE.md" ] && grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md"; then
  LINE_NUM=$(grep -n "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
  head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
  mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
  echo "<!-- DATE_MARKER -->" >> "$WORK_DIR/CLAUDE.md"
  echo "## 현재 날짜" >> "$WORK_DIR/CLAUDE.md"
  echo "오늘은 $(date '+%Y년 %m월 %d일')입니다. 날짜 관련 질문이나 쿼리에서 이 날짜를 기준으로 하세요." >> "$WORK_DIR/CLAUDE.md"
fi
