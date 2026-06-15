#!/bin/bash
# caramel-team-setup 자가진단 스크립트 (read-only)
# 팀 셋업 전파 체인이 어디서 끊겼는지 짚어줍니다.
# 사용: bash ~/.caramel-team-setup/team-diagnose.sh
#       (또는 Claude Code에 "셋업 자가진단 스크립트 실행해줘"라고 요청)
# 마지막에 출력되는 [진단 요약]을 통째로 복사해서 맹주성님께 보내주세요.

INSTALL_DIR="$HOME/.caramel-team-setup"
WORK_DIR="$HOME/caramel-claude"
CONFIG_FILE="$WORK_DIR/.setup-config"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"
LATEST_VERSION=6   # update.sh의 LATEST_VERSION과 일치해야 함

PASS="✅"; FAIL="❌"; WARN="⚠️ "
problems=()

line() { printf '%s\n' "------------------------------------------------------------"; }
hdr()  { echo; echo "### $1"; }

echo "============================================================"
echo " caramel-team-setup 자가진단  ($(date '+%Y-%m-%d %H:%M'))"
echo " host: $(hostname 2>/dev/null)  user: $USER"
echo "============================================================"

# ── 1) 셋업 repo 존재 / git 상태 ─────────────────────────────
hdr "1. 셋업 repo (~/.caramel-team-setup)"
if [ ! -d "$INSTALL_DIR/.git" ]; then
  echo "$FAIL repo가 없습니다 ($INSTALL_DIR). 셋업 자체가 안 된 상태."
  problems+=("셋업 repo 미존재 → setup.sh를 처음부터 다시 실행해야 함")
else
  echo "$PASS repo 존재: $INSTALL_DIR"
  cur_branch=$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
  local_head=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)
  echo "   현재 브랜치: $cur_branch / HEAD: $local_head"
  [ "$cur_branch" != "main" ] && { echo "$WARN main이 아닌 브랜치 → pull 대상이 어긋날 수 있음"; problems+=("repo가 main 아닌 '$cur_branch'에 체크아웃됨"); }

  # 더티 트리 (tracked 파일 수정만 — untracked는 ff-only pull 안 막음)
  tracked_changes=$(git -C "$INSTALL_DIR" status --porcelain --untracked-files=no 2>/dev/null)
  if [ -n "$tracked_changes" ]; then
    echo "$WARN 추적 파일에 미커밋 변경 있음 → ff-only pull이 막힐 수 있음"
    printf '%s\n' "$tracked_changes" | head -5 | sed 's/^/      /'
    problems+=("repo에 추적 파일 미커밋 변경 → pull 차단 가능")
  else
    echo "$PASS 워킹트리 깨끗 (추적 파일 기준)"
  fi

  # origin/main 대비 얼마나 뒤처졌나 (네트워크 필요)
  echo "   origin/main fetch 중..."
  if git -C "$INSTALL_DIR" fetch origin main --quiet 2>/dev/null; then
    behind=$(git -C "$INSTALL_DIR" rev-list --count HEAD..origin/main 2>/dev/null)
    ahead=$(git -C "$INSTALL_DIR" rev-list --count origin/main..HEAD 2>/dev/null)
    remote_head=$(git -C "$INSTALL_DIR" rev-parse --short origin/main 2>/dev/null)
    echo "   origin/main HEAD: $remote_head  (behind=$behind, ahead=$ahead)"
    if [ "${behind:-0}" -gt 0 ]; then
      echo "$FAIL 로컬이 origin/main보다 $behind 커밋 뒤처짐 → update.sh가 전파를 못 받고 있음"
      problems+=("repo가 $behind 커밋 stale → pull이 실패하거나 안 돌고 있음")
      git -C "$INSTALL_DIR" log --oneline HEAD..origin/main 2>/dev/null | head -5 | sed 's/^/      놓친 커밋: /'
    else
      echo "$PASS 최신 (origin/main과 동일)"
    fi
    [ "${ahead:-0}" -gt 0 ] && echo "$WARN 로컬이 origin보다 $ahead 커밋 앞섬 (직접 커밋했을 수 있음)"
  else
    echo "$FAIL origin fetch 실패 → 네트워크/SSH 키/권한 문제로 pull이 막혀 있을 수 있음"
    problems+=("git fetch 실패 (네트워크 또는 deploy key 문제)")
  fi
fi

# ── 2) SessionStart 훅 등록 ──────────────────────────────────
hdr "2. SessionStart 훅 (~/.claude/settings.json)"
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "$FAIL settings.json이 없습니다 → 훅 등록 불가, update.sh가 세션마다 안 돕니다"
  problems+=("~/.claude/settings.json 부재")
elif grep -q "caramel-team-setup/update.sh" "$SETTINGS_FILE" 2>/dev/null; then
  echo "$PASS 글로벌 settings.json에 update.sh 훅 등록됨"
else
  echo "$FAIL 글로벌 settings.json에 update.sh 훅이 없음 → 세션 시작 시 전파가 안 돎 (이게 핵심 원인일 가능성 높음)"
  problems+=("SessionStart 훅 미등록 → update.sh가 세션마다 실행 안 됨")
fi
# 프로젝트 레벨도 확인
PROJECT_SETTINGS="$WORK_DIR/.claude/settings.json"
if [ -f "$PROJECT_SETTINGS" ]; then
  grep -q "caramel-team-setup/update.sh" "$PROJECT_SETTINGS" 2>/dev/null \
    && echo "$PASS 프로젝트 settings.json에도 등록됨" \
    || echo "$WARN 프로젝트 settings.json에는 훅 없음 (글로벌만 있으면 동작은 함)"
fi

# ── 3) 작업 폴더 ~/caramel-claude ────────────────────────────
hdr "3. 작업 폴더 (~/caramel-claude)"
if [ ! -d "$WORK_DIR" ]; then
  echo "$FAIL ~/caramel-claude 폴더가 없음 → 참조 문서/CLAUDE.md가 적재될 곳이 없음"
  problems+=("WORK_DIR(~/caramel-claude) 부재")
else
  echo "$PASS 폴더 존재: $WORK_DIR"
  echo "$WARN  ※ Claude Code/VSCode에서 반드시 이 폴더(~/caramel-claude)를 열어야"
  echo "       CLAUDE.md와 QUERY_REFERENCE가 컨텍스트에 자동 로드됩니다."
  echo "       다른 폴더를 열고 작업하면 셋업이 멀쩡해도 규칙이 안 먹습니다."
  if [ -f "$CONFIG_FILE" ]; then
    cur_ver=$(grep "^SETUP_VERSION=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
    role=$(grep "^ROLE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    echo "   SETUP_VERSION=$cur_ver (최신=$LATEST_VERSION) / ROLE=${role:-(없음)}"
    if [ "${cur_ver:-0}" -lt "$LATEST_VERSION" ] 2>/dev/null; then
      echo "$FAIL 버전이 뒤처짐 → 마이그레이션 미적용 (update.sh가 안 돌고 있다는 신호)"
      problems+=("SETUP_VERSION=$cur_ver < $LATEST_VERSION → 마이그레이션 미적용")
    else
      echo "$PASS 버전 최신"
    fi
  else
    echo "$FAIL .setup-config가 없음 → 셋업이 완료되지 않았거나 폴더가 다름"
    problems+=(".setup-config 부재")
  fi
fi

# ── 4) 전파된 참조 파일 (repo본과 일치하나) ──────────────────
hdr "4. 참조 문서 전파 상태 (repo본 대비)"
if [ -d "$INSTALL_DIR/.git" ] && [ -d "$WORK_DIR" ]; then
  for f in QUERY_REFERENCE.md DB_SCHEMA.md mysql-query.sh mysql-cols.sh; do
    if [ ! -f "$WORK_DIR/$f" ]; then
      echo "$FAIL $f 없음 (전파 안 됨)"; problems+=("$f 미전파")
    elif diff -q "$INSTALL_DIR/$f" "$WORK_DIR/$f" >/dev/null 2>&1; then
      echo "$PASS $f — repo본과 동일"
    else
      echo "$WARN $f — repo본과 다름 (구버전이 남아있을 수 있음)"
      problems+=("$f 가 repo 최신본과 불일치")
    fi
  done
else
  echo "(repo 또는 WORK_DIR이 없어 비교 생략)"
fi

# ── 5) CLAUDE.md 관리 블록 ───────────────────────────────────
hdr "5. CLAUDE.md (~/caramel-claude/CLAUDE.md)"
if [ -f "$WORK_DIR/CLAUDE.md" ]; then
  if grep -qF "TEAM-SETUP:BEGIN" "$WORK_DIR/CLAUDE.md" 2>/dev/null; then
    echo "$PASS TEAM-SETUP 마커 존재 (팀 베이스 규칙 적용 중)"
  else
    echo "$FAIL TEAM-SETUP 마커 없음 → legacy/수동본, 베이스 규칙 전파 안 됨"
    problems+=("CLAUDE.md에 TEAM-SETUP 마커 없음")
  fi
else
  echo "$FAIL CLAUDE.md 없음"; problems+=("WORK_DIR/CLAUDE.md 부재")
fi

# ── 6) 스킬 심링크 ───────────────────────────────────────────
hdr "6. 스킬 심링크 (~/.claude/skills)"
if [ -d "$INSTALL_DIR/skills" ]; then
  total=0; ok=0; missing=()
  for d in "$INSTALL_DIR/skills"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d"); total=$((total+1))
    if [ -e "$SKILLS_DIR/$name/SKILL.md" ]; then ok=$((ok+1)); else missing+=("$name"); fi
  done
  echo "   repo 스킬 $total개 중 링크 정상 $ok개"
  if [ ${#missing[@]} -gt 0 ]; then
    echo "$WARN 누락/깨진 링크: ${missing[*]}"
    problems+=("스킬 심링크 ${#missing[@]}개 누락 (${missing[*]})")
  else
    echo "$PASS 모든 스킬 링크 정상"
  fi
fi

# ── 진단 요약 ────────────────────────────────────────────────
echo; line
echo " [진단 요약]  ← 이 박스를 통째로 복사해서 맹주성님께 보내세요"
line
if [ ${#problems[@]} -eq 0 ]; then
  echo " 🎉 전파 체인 정상. 셋업 문제는 아닙니다."
  echo "    (그래도 규칙이 안 먹으면 → Claude Code에서 ~/caramel-claude 폴더를 열고 있는지 확인)"
else
  echo " 발견된 문제 ${#problems[@]}건:"
  i=1; for p in "${problems[@]}"; do echo "   $i) $p"; i=$((i+1)); done
  echo
  echo " 즉시 시도: 아래 한 줄을 실행하면 대부분 자동 복구됩니다."
  echo "   bash ~/.caramel-team-setup/update.sh; echo '---done---'"
  echo " 그래도 안 되면 위 문제 목록 그대로 맹주성님께 전달."
fi
line
