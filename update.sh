#!/bin/bash
# caramel-team-setup 자동 업데이트 스크립트
# Claude Code SessionStart 훅에서 호출됨
# 변경 없으면 무음, 변경 있으면 커밋 메시지 기반 알림

INSTALL_DIR="$HOME/.caramel-team-setup"
WORK_DIR="$HOME/caramel-claude"

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

  # 5) 참조 문서 업데이트 (작업 디렉토리에 복사)
  if [ -d "$WORK_DIR" ]; then
    cp "$INSTALL_DIR/QUERY_REFERENCE.md" "$WORK_DIR/" 2>/dev/null || true
    cp "$INSTALL_DIR/DB_SCHEMA.md" "$WORK_DIR/" 2>/dev/null || true
  fi

  # 6) 변경사항 요약 출력 (Claude Code에 표시됨)
  echo "caramel-team-setup 업데이트:"
  git log --oneline "$OLD_HEAD".."$NEW_HEAD" | while read line; do
    echo "  $line"
  done
fi

# 7) 현재 날짜 갱신 (매 세션마다 항상 실행 — 모델이 날짜를 정확히 인식하도록)
if [ -f "$WORK_DIR/CLAUDE.md" ] && grep -q "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md"; then
  LINE_NUM=$(grep -n "<!-- DATE_MARKER -->" "$WORK_DIR/CLAUDE.md" | head -1 | cut -d: -f1)
  head -n $((LINE_NUM - 1)) "$WORK_DIR/CLAUDE.md" > "$WORK_DIR/CLAUDE.md.tmp"
  mv "$WORK_DIR/CLAUDE.md.tmp" "$WORK_DIR/CLAUDE.md"
  echo "<!-- DATE_MARKER -->" >> "$WORK_DIR/CLAUDE.md"
  echo "## 현재 날짜" >> "$WORK_DIR/CLAUDE.md"
  echo "오늘은 $(date '+%Y년 %m월 %d일')입니다. 날짜 관련 질문이나 쿼리에서 이 날짜를 기준으로 하세요." >> "$WORK_DIR/CLAUDE.md"
fi
