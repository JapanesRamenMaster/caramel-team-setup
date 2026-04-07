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
LATEST_VERSION=2

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
# 7) 버전 기반 마이그레이션
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

  # --- 여기에 향후 마이그레이션 추가 ---
  # if [ "${CURRENT_VERSION}" -lt 3 ]; then
  #   ...
  #   MIGRATED="$MIGRATED 새기능"
  # fi

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
