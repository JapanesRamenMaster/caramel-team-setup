#!/bin/bash
# Caramel 팀원 Claude 환경 셋업 스크립트
# 사용법:
#   대화형:  bash setup.sh
#   자동:    bash setup.sh --role "CS" --db-password PASS

set -e

# --quiet 모드 (update.sh에서 호출 시 출력 억제)
QUIET=false
for arg in "$@"; do
    [ "$arg" = "--quiet" ] && QUIET=true
done

# 0. 레포를 ~/.caramel-team-setup/에 설치 (자동 업데이트를 위한 고정 위치)
INSTALL_DIR="$HOME/.caramel-team-setup"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    # 다른 위치에서 실행됨 → 고정 위치로 복사/클론
    if [ -d "$INSTALL_DIR/.git" ]; then
        # 이미 설치되어 있으면 pull
        git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
    elif [ -d "$SCRIPT_DIR/.git" ]; then
        # git 레포면 clone
        REMOTE_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")
        if [ -n "$REMOTE_URL" ]; then
            rm -rf "$INSTALL_DIR"
            git clone "$REMOTE_URL" "$INSTALL_DIR"
        else
            # remote 없으면 복사
            rm -rf "$INSTALL_DIR"
            cp -R "$SCRIPT_DIR" "$INSTALL_DIR"
        fi
    else
        # git 레포가 아니면 복사
        rm -rf "$INSTALL_DIR"
        cp -R "$SCRIPT_DIR" "$INSTALL_DIR"
    fi
    # 고정 위치에서 다시 실행 (인자 전달)
    exec "$INSTALL_DIR/setup.sh" "$@"
fi

# --quiet 모드: 심링크만 갱신하고 종료 (update.sh에서 호출)
if [ "$QUIET" = true ]; then
    SKILLS_DIR="$HOME/.claude/skills"
    mkdir -p "$SKILLS_DIR"
    for skill_dir in "$INSTALL_DIR/skills"/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        ln -sfn "$skill_dir" "$SKILLS_DIR/$skill_name"
    done
    # 참조 문서 업데이트
    WORK_DIR="$HOME/caramel-claude"
    if [ -d "$WORK_DIR" ]; then
        cp "$INSTALL_DIR/QUERY_REFERENCE.md" "$WORK_DIR/" 2>/dev/null || true
        cp "$INSTALL_DIR/DB_SCHEMA.md" "$WORK_DIR/" 2>/dev/null || true
    fi
    exit 0
fi

echo ""
echo "=== Caramel Claude 팀 환경 셋업 ==="
echo ""

# 인자 파싱
ROLE=""
ARG_DB_HOST=""
ARG_DB_PASSWORD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --db-host) ARG_DB_HOST="$2"; shift 2 ;;
        --db-password) ARG_DB_PASSWORD="$2"; shift 2 ;;
        --quiet) shift ;;  # 이미 위에서 처리됨
        *) echo "WARNING: 알 수 없는 인자 '$1'"; shift ;;
    esac
done

# 1. 역할 입력 (자유 형식)
if [ -z "$ROLE" ]; then
    echo "팀에서 어떤 역할을 맡고 있나요?"
    echo "  예: CS, 마케팅, 운영, 개발, 디자인, PM 등 자유롭게 입력"
    echo ""
    read -p "역할 입력: " ROLE
fi

if [ -z "$ROLE" ]; then
    echo "ERROR: 역할을 입력해주세요."
    exit 1
fi

echo ""
echo "역할: ${ROLE} (으)로 설정합니다."

# 2. 작업 디렉토리 설정
WORK_DIR="$HOME/caramel-claude"
echo ""
echo "작업 디렉토리: $WORK_DIR"

if [ -d "$WORK_DIR" ]; then
    echo "기존 디렉토리가 있습니다. 덮어씁니다."
fi
mkdir -p "$WORK_DIR"

# 3. CLAUDE.md 생성 (공통 + 역할 컨텍스트)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cat "$SCRIPT_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md"

# 역할 기록
echo "" >> "$WORK_DIR/CLAUDE.md"
echo "## 이 사용자의 역할" >> "$WORK_DIR/CLAUDE.md"
echo "이 사용자는 카라멜 팀에서 **${ROLE}** 역할을 맡고 있습니다. 이 역할에 맞게 답변을 조정하세요." >> "$WORK_DIR/CLAUDE.md"

# 역할별 추가 규칙 (매칭되는 파일이 있으면 추가)
ROLE_LOWER=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')
ROLE_FILE=""
case "$ROLE_LOWER" in
    cs) ROLE_FILE="$SCRIPT_DIR/roles/cs.md" ;;
    마케팅|marketing) ROLE_FILE="$SCRIPT_DIR/roles/marketing.md" ;;
    운영|operations) ROLE_FILE="$SCRIPT_DIR/roles/operations.md" ;;
esac

if [ -n "$ROLE_FILE" ] && [ -f "$ROLE_FILE" ]; then
    echo "" >> "$WORK_DIR/CLAUDE.md"
    cat "$ROLE_FILE" >> "$WORK_DIR/CLAUDE.md"
fi

echo "CLAUDE.md 생성 완료"

# 4. 코드 레포 클론 (팀 코드베이스 접근용)
echo ""
echo "=== 코드 레포 설정 ==="
REPOS_DIR="$WORK_DIR/repos"
mkdir -p "$REPOS_DIR"

if command -v gh &> /dev/null; then
    if gh auth status &>/dev/null; then
        if [ ! -d "$REPOS_DIR/caramel-all/.git" ]; then
            echo "caramel-all 레포를 클론합니다... (시간이 좀 걸릴 수 있습니다)"
            gh repo clone the-trive/caramel-all "$REPOS_DIR/caramel-all" -- --depth 1 --recurse-submodules --shallow-submodules 2>&1 || {
                echo "WARNING: 레포 클론 실패. GitHub 접근 권한을 확인하세요."
                echo "  the-trive 조직에 초대되어 있는지 확인 후 다시 시도: gh repo clone the-trive/caramel-all $REPOS_DIR/caramel-all"
            }
        else
            echo "caramel-all 레포 이미 존재 — pull 합니다."
            git -C "$REPOS_DIR/caramel-all" pull --ff-only 2>/dev/null || true
        fi
        echo "코드 레포 설정 완료"
    else
        echo "WARNING: gh CLI 로그인이 필요합니다. 'gh auth login' 실행 후 다시 셋업하세요."
    fi
else
    echo "WARNING: gh CLI가 설치되어 있지 않습니다."
    echo "  코드 레포 접근을 위해 설치하세요: https://cli.github.com/"
    echo "  설치 후 'gh auth login' → 다시 셋업 실행"
fi

# CLAUDE.md에 레포 경로 추가
if [ -d "$REPOS_DIR/caramel-all/.git" ]; then
    echo "" >> "$WORK_DIR/CLAUDE.md"
    echo "## 코드 레포" >> "$WORK_DIR/CLAUDE.md"
    echo "- \`repos/caramel-all/\` — 카라멜 전체 코드베이스 (모노레포, 5개 서브모듈)" >> "$WORK_DIR/CLAUDE.md"
    echo "- 코드에 대한 질문이 오면 이 디렉토리에서 검색하여 답변" >> "$WORK_DIR/CLAUDE.md"
    echo "- 코드를 수정하지 말 것 — 읽기 전용으로만 사용" >> "$WORK_DIR/CLAUDE.md"
fi

# 5. DB 접속 정보 (읽기 전용 유저 — 조회만 가능)
DB_PORT=3306
DB_USER="caramel_reader"
DB_NAME="caramel-prod"
DB_HOST="34.64.113.107"

# --db-password 인자가 있으면 사용, 없으면 프롬프트
if [ -n "$ARG_DB_PASSWORD" ]; then
    DB_PASSWORD="$ARG_DB_PASSWORD"
else
    read -sp "DB Password (슬랙 #claude-setup 채널에서 확인): " DB_PASSWORD
    echo ""
fi

if [ -z "$DB_PASSWORD" ]; then
    echo "ERROR: DB Password가 필요합니다. 슬랙 #claude-setup 채널을 확인하세요."
    exit 1
fi

cat > "$WORK_DIR/.env" << EOF
# Caramel DB 접속 정보 (자동 생성)
# 이 파일은 절대 공유하지 마세요
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
EOF
echo ".env 파일 생성 완료"

# 5. mysql-query.sh 복사
cp "$SCRIPT_DIR/mysql-query.sh" "$WORK_DIR/mysql-query.sh"
chmod +x "$WORK_DIR/mysql-query.sh"
echo "mysql-query.sh 복사 완료 (읽기 전용 가드레일 포함)"

# 6. .mcp.json 생성 (템플릿에서 변수 치환)
cat > "$WORK_DIR/.mcp.json" << EOF
{
  "mcpServers": {
    "mysql": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@benborla29/mcp-server-mysql"],
      "env": {
        "MYSQL_CONNECTION_STRING": "mysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}",
        "MULTI_DB": "false"
      }
    }
  }
}
EOF
echo ".mcp.json 생성 완료"

# 7. 참조 문서 복사
cp "$SCRIPT_DIR/QUERY_REFERENCE.md" "$WORK_DIR/" 2>/dev/null || echo "QUERY_REFERENCE.md 없음 (나중에 복사)"
cp "$SCRIPT_DIR/DB_SCHEMA.md" "$WORK_DIR/" 2>/dev/null || echo "DB_SCHEMA.md 없음 (나중에 복사)"

# 8. Skills 설치 (심링크 방식 — 자동 업데이트 지원)
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"

INSTALLED_SKILLS=""
for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    ln -sfn "$skill_dir" "$SKILLS_DIR/$skill_name"
    INSTALLED_SKILLS="$INSTALLED_SKILLS /$skill_name"
done
echo "스킬 설치 완료 (심링크):$INSTALLED_SKILLS"

# 8-1. Claude Code 세션 훅 등록 (자동 업데이트)
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_CMD="$HOME/.caramel-team-setup/update.sh 2>/dev/null || true"

if [ -f "$SETTINGS_FILE" ]; then
    # settings.json이 이미 있으면 hooks 추가 (jq 사용)
    if command -v jq &> /dev/null; then
        if ! jq -e '.hooks.SessionStart' "$SETTINGS_FILE" &>/dev/null; then
            # SessionStart 훅이 없으면 추가
            jq --arg cmd "$HOOK_CMD" '.hooks.SessionStart = [{"type": "command", "command": $cmd}]' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
            echo "Claude Code 세션 훅 등록 완료 (자동 업데이트)"
        elif ! jq -e --arg cmd "$HOOK_CMD" '.hooks.SessionStart[] | select(.command == $cmd)' "$SETTINGS_FILE" &>/dev/null; then
            # SessionStart 훅은 있지만 우리 훅이 없으면 추가
            jq --arg cmd "$HOOK_CMD" '.hooks.SessionStart += [{"type": "command", "command": $cmd}]' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
            echo "Claude Code 세션 훅 추가 완료 (자동 업데이트)"
        else
            echo "Claude Code 세션 훅 이미 등록됨"
        fi
    else
        echo "WARNING: jq가 없어서 세션 훅을 자동 등록할 수 없습니다."
        echo "  수동으로 ~/.claude/settings.json에 추가하세요:"
        echo "  \"hooks\": { \"SessionStart\": [{ \"type\": \"command\", \"command\": \"$HOOK_CMD\" }] }"
    fi
else
    # settings.json이 없으면 새로 생성
    mkdir -p "$HOME/.claude"
    cat > "$SETTINGS_FILE" << HOOKEOF
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "$HOOK_CMD"
      }
    ]
  }
}
HOOKEOF
    echo "Claude Code 세션 훅 등록 완료 (자동 업데이트)"
fi

# 9. Node.js 확인 및 mysql2 설치
echo ""
echo "=== 의존성 확인 ==="

if ! command -v node &> /dev/null; then
    echo "ERROR: Node.js가 설치되어 있지 않습니다."
    echo "https://nodejs.org 에서 LTS 버전을 설치하세요."
    exit 1
fi
echo "Node.js $(node -v) 확인됨"

cd "$WORK_DIR"
npm init -y --silent 2>/dev/null
npm install mysql2 --silent
echo "mysql2 설치 완료"

# Google Sheets MCP (패치 버전) 설치
SHEETS_DIR="$WORK_DIR/.tools/mcp-google-sheets"
mkdir -p "$SHEETS_DIR"
cp -r "$SCRIPT_DIR/tools/mcp-google-sheets/." "$SHEETS_DIR/"
cd "$SHEETS_DIR"
npm install --ignore-scripts --silent
cd "$WORK_DIR"
echo "Google Sheets MCP 설치 완료"

# 10. 설정 저장 (update.sh 마이그레이션용)
cat > "$WORK_DIR/.setup-config" << CONFIGEOF
SETUP_VERSION=2
ROLE=$ROLE
CONFIGEOF
echo "설정 저장 완료 (.setup-config)"

# 11. 현재 날짜를 CLAUDE.md에 추가 (모델이 날짜를 정확히 인식하도록)
echo "" >> "$WORK_DIR/CLAUDE.md"
echo "<!-- DATE_MARKER -->" >> "$WORK_DIR/CLAUDE.md"
echo "## 현재 날짜" >> "$WORK_DIR/CLAUDE.md"
echo "오늘은 $(date '+%Y년 %m월 %d일')입니다. 날짜 관련 질문이나 쿼리에서 이 날짜를 기준으로 하세요." >> "$WORK_DIR/CLAUDE.md"

# 12. DB 연결 테스트
echo ""
echo "=== DB 연결 테스트 ==="
RESULT=$(./mysql-query.sh "SELECT 1 AS test" 2>&1)
if echo "$RESULT" | grep -q '"test": 1'; then
    echo "DB 연결 성공!"
else
    echo "DB 연결 실패: $RESULT"
    echo "맹주성에게 문의하세요."
    exit 1
fi

# 13. 가드레일 테스트
echo ""
echo "=== 가드레일 테스트 ==="
GUARD_RESULT=$(./mysql-query.sh "DELETE FROM app_user WHERE 1=0" 2>&1)
if echo "$GUARD_RESULT" | grep -q "차단됨"; then
    echo "가드레일 정상 작동! (DELETE 차단 확인)"
else
    echo "WARNING: 가드레일이 작동하지 않습니다. mysql-query.sh를 확인하세요."
fi

echo ""
echo "=== 셋업 완료 ==="
echo ""
echo "  작업 폴더: $WORK_DIR"
echo "  역할: ${ROLE}"
echo "  스킬:$INSTALLED_SKILLS"
echo "  자동 업데이트: 매 세션 시작 시 최신 버전 반영"
echo ""

# VSCode에서 자동으로 폴더 열기
if command -v code &> /dev/null; then
    echo "VSCode에서 $WORK_DIR 폴더를 엽니다..."
    code "$WORK_DIR"
else
    echo "  VSCode에서 $WORK_DIR 폴더를 열어주세요."
fi
echo ""
