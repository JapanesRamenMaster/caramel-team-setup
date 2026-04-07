#!/bin/bash
# caramel-team-setup 자동 업데이트 스크립트
# Claude Code SessionStart 훅에서 호출됨
# - git pull로 최신 코드 반영
# - 버전 기반 마이그레이션으로 구조적 변경 자동 적용
# - 매 세션 날짜 갱신

INSTALL_DIR="$HOME/.caramel-team-setup"
WORK_DIR="$HOME/caramel-claude"
CONFIG_FILE="$WORK_DIR/.setup-config"

# === 최신 버전 (새 마이그레이션 추가 시 이 숫자를 올리고 아래에 로직 추가) ===
LATEST_VERSION=3

cd "$INSTALL_DIR" || exit 0

# 1) Pull 전 상태 저장
OLD_HEAD=$(git rev-parse HEAD 2>/dev/null)

# 2) Pull (fast-forward only, 충돌 방지)
git pull --ff-only 2>/dev/null || true

# 3) Pull 후 상태 비교
NEW_HEAD=$(git rev-parse HEAD 2>/dev/null)

if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
  # 4) 스킬 심링크 재생성 (새 스킬 포함)
  SKILLS_DIR="$HOME/.claude/skills"
  mkdir -p "$SKILLS_DIR"
  for skill_dir in "$INSTALL_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    ln -sfn "$skill_dir" "$SKILLS_DIR/$skill_name"
  done

  # 5) 참조 문서 + mysql-query.sh 업데이트
  if [ -d "$WORK_DIR" ]; then
    cp "$INSTALL_DIR/QUERY_REFERENCE.md" "$WORK_DIR/" 2>/dev/null || true
    cp "$INSTALL_DIR/DB_SCHEMA.md" "$WORK_DIR/" 2>/dev/null || true
    cp "$INSTALL_DIR/mysql-query.sh" "$WORK_DIR/mysql-query.sh" 2>/dev/null || true
    chmod +x "$WORK_DIR/mysql-query.sh" 2>/dev/null || true
  fi

  # 6) 변경사항 요약 출력 (Claude Code에 표시됨)
  echo "caramel-team-setup 업데이트:"
  git log --oneline "$OLD_HEAD".."$NEW_HEAD" | while read line; do
    echo "  $line"
  done
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

# 글로벌 settings.json 검증
ensure_hook "$SETTINGS_FILE"

# 프로젝트 레벨 settings.json 검증
PROJECT_SETTINGS="$WORK_DIR/.claude/settings.json"
if [ -d "$WORK_DIR" ]; then
  if [ ! -f "$PROJECT_SETTINGS" ]; then
    mkdir -p "$WORK_DIR/.claude"
    echo '{}' > "$PROJECT_SETTINGS"
  fi
  ensure_hook "$PROJECT_SETTINGS"
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
  if [ -f "$CONFIG_FILE" ]; then
    ROLE=$(grep "^ROLE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
  fi

  MIGRATED=""

  # --- Migration v1 → v2: 코드 레포, 날짜 마커, CLAUDE.md 역할 섹션 ---
  if [ "${CURRENT_VERSION}" -lt 2 ]; then

    # 2a) 코드 레포 클론 (없으면)
    REPOS_DIR="$WORK_DIR/repos"
    if [ ! -d "$REPOS_DIR/caramel-all/.git" ]; then
      if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        mkdir -p "$REPOS_DIR"
        gh repo clone the-trive/caramel-all "$REPOS_DIR/caramel-all" -- --depth 1 --recurse-submodules --shallow-submodules 2>/dev/null && {
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
        echo "## 코드 레포" >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "- \`repos/caramel-all/\` — 카라멜 전체 코드베이스 (모노레포, 5개 서브모듈)" >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "- 코드에 대한 질문이 오면 이 디렉토리에서 검색하여 답변" >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "- 코드를 수정하지 말 것 — 읽기 전용으로만 사용" >> "$WORK_DIR/CLAUDE.md.tmp"
        echo "" >> "$WORK_DIR/CLAUDE.md.tmp"
        tail -n "+$LINE_NUM" "$WORK_DIR/CLAUDE.md" >> "$WORK_DIR/CLAUDE.md.tmp"
        mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
      else
        echo "" >> "$WORK_DIR/CLAUDE.md"
        echo "## 코드 레포" >> "$WORK_DIR/CLAUDE.md"
        echo "- \`repos/caramel-all/\` — 카라멜 전체 코드베이스 (모노레포, 5개 서브모듈)" >> "$WORK_DIR/CLAUDE.md"
        echo "- 코드에 대한 질문이 오면 이 디렉토리에서 검색하여 답변" >> "$WORK_DIR/CLAUDE.md"
        echo "- 코드를 수정하지 말 것 — 읽기 전용으로만 사용" >> "$WORK_DIR/CLAUDE.md"
      fi
    fi

    # 2c) CLAUDE.md에 역할 섹션 추가 (없으면)
    if [ -n "$ROLE" ] && ! grep -q "## 이 사용자의 역할" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
      # 안전 규칙 섹션 뒤에 추가 (파일 앞부분에)
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

  # 버전 업데이트
  if [ -f "$CONFIG_FILE" ]; then
    # 기존 파일에서 버전만 교체
    grep -v "^SETUP_VERSION=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    echo "SETUP_VERSION=$LATEST_VERSION" >> "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  else
    # config 파일이 없으면 생성 (v1 이전 설치)
    echo "SETUP_VERSION=$LATEST_VERSION" > "$CONFIG_FILE"
    [ -n "$ROLE" ] && echo "ROLE=$ROLE" >> "$CONFIG_FILE"
  fi

  if [ -n "$MIGRATED" ]; then
    echo "caramel-team-setup 환경 업그레이드 (v${CURRENT_VERSION} → v${LATEST_VERSION}):$MIGRATED"
  fi
fi

# ============================================================
# 8) 현재 날짜 갱신 (매 세션마다 항상 실행)
# ============================================================
if [ -f "$WORK_DIR/CLAUDE.md" ] && grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md"; then
  LINE_NUM=$(grep -n "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
  head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
  mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
  echo "<!-- DATE_MARKER -->" >> "$WORK_DIR/CLAUDE.md"
  echo "## 현재 날짜" >> "$WORK_DIR/CLAUDE.md"
  echo "오늘은 $(date '+%Y년 %m월 %d일')입니다. 날짜 관련 질문이나 쿼리에서 이 날짜를 기준으로 하세요." >> "$WORK_DIR/CLAUDE.md"
fi
