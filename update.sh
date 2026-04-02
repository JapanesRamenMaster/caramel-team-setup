#!/bin/bash
# caramel-team-setup 자동 업데이트 스크립트
# Claude Code SessionStart 훅에서 호출됨
# 변경 없으면 무음, 변경 있으면 커밋 메시지 기반 알림

INSTALL_DIR="$HOME/.caramel-team-setup"
cd "$INSTALL_DIR" || exit 0

# 1) Pull 전 상태 저장
OLD_HEAD=$(git rev-parse HEAD 2>/dev/null)

# 2) Pull (fast-forward only, 충돌 방지)
git pull --ff-only 2>/dev/null || exit 0

# 3) Pull 후 상태 비교
NEW_HEAD=$(git rev-parse HEAD 2>/dev/null)
[ "$OLD_HEAD" = "$NEW_HEAD" ] && exit 0

# 4) 스킬 심링크 재생성 (새 스킬 포함)
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"
for skill_dir in "$INSTALL_DIR/skills"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  ln -sfn "$skill_dir" "$SKILLS_DIR/$skill_name"
done

# 5) 참조 문서 업데이트 (작업 디렉토리에 복사)
WORK_DIR="$HOME/caramel-claude"
if [ -d "$WORK_DIR" ]; then
  cp "$INSTALL_DIR/QUERY_REFERENCE.md" "$WORK_DIR/" 2>/dev/null || true
  cp "$INSTALL_DIR/DB_SCHEMA.md" "$WORK_DIR/" 2>/dev/null || true
fi

# 6) 변경사항 요약 출력 (Claude Code에 표시됨)
echo "caramel-team-setup 업데이트:"
git log --oneline "$OLD_HEAD".."$NEW_HEAD" | while read line; do
  echo "  $line"
done
