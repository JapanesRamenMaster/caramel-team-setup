#!/bin/bash
# install-slop-gate.sh — 한국어 AI 문체 게이트 단독 설치
#
# 팀 셋업(setup.sh/update.sh)을 쓰지 않는 사람용. 레포 클론도 필요없다.
#
#   curl -fsSL https://raw.githubusercontent.com/JapanesRamenMaster/caramel-team-setup/main/install-slop-gate.sh | bash
#
# 하는 일:
#   1. 훅 스크립트 2개 → ~/.claude/scripts/
#   2. 스킬 3개(deslop·slop-audit·slop-gate) → ~/.claude/skills/
#   3. ~/.claude/settings.json 에 훅 등록 (기존 훅 보존, 멱등)
#
# 안전 원칙:
#   - 기존 settings.json 을 덮어쓰지 않는다. 같은 스크립트가 이미 있으면 건너뛴다.
#   - 심링크로 관리되는 스킬(팀 셋업 사용자)은 건드리지 않는다.
#   - 원자적 교체(tmp → replace)라 중간에 끊겨도 settings.json 이 깨지지 않는다.

set -eu

BASE="${SLOP_BASE:-https://raw.githubusercontent.com/JapanesRamenMaster/caramel-team-setup/main}"
DEST="$HOME/.claude"
SCRIPTS="$DEST/scripts"
SKILLS="$DEST/skills"
SETTINGS="$DEST/settings.json"

command -v python3 >/dev/null 2>&1 || { echo "python3 가 필요하다. 설치 후 다시 실행할 것." >&2; exit 1; }

fetch() {  # fetch <레포 상대경로> <저장 경로>
  mkdir -p "$(dirname "$2")"
  if [ "${BASE#file://}" != "$BASE" ]; then
    cp "${BASE#file://}/$1" "$2"
  else
    curl -fsSL "$BASE/$1" -o "$2"
  fi
}

echo "== 1. 훅 스크립트 =="
for f in slop-gate.py slop-gate-outbound.py; do
  fetch "hooks/$f" "$SCRIPTS/$f"
  chmod +x "$SCRIPTS/$f"
  echo "  + scripts/$f"
done

echo "== 2. 스킬 =="
SKIPPED=""
for f in deslop/SKILL.md \
         deslop/references/claude-tells.md deslop/references/examples.md \
         deslop/references/phrases.md deslop/references/structures.md \
         slop-audit/SKILL.md slop-gate/SKILL.md; do
  top="${f%%/*}"
  if [ -L "$SKILLS/$top" ]; then
    case " $SKIPPED " in
      *" $top "*) : ;;
      *) SKIPPED="$SKIPPED $top"; echo "  = skills/$top (심링크 — 팀 셋업이 관리 중, 건너뜀)" ;;
    esac
    continue
  fi
  fetch "skills/$f" "$SKILLS/$f"
  echo "  + skills/$f"
done

echo "== 3. 훅 등록 =="
mkdir -p "$DEST"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
SETTINGS="$SETTINGS" SCRIPTS="$SCRIPTS" PY="$(command -v python3)" python3 - <<'PYEOF'
import json, os, shlex

settings, scripts, py = os.environ["SETTINGS"], os.environ["SCRIPTS"], os.environ["PY"]

OUTBOUND = "|".join([
    "Artifact",
    "mcp__claude_ai_Slack__slack_send_message",
    "mcp__claude_ai_Slack__slack_send_message_draft",
    "mcp__claude_ai_Slack__slack_schedule_message",
    "mcp__notion__notion-create-pages",
    "mcp__notion__notion-update-page",
    "mcp__notion__notion-create-comment",
])
SPEC = [("Stop", "", "slop-gate.py"), ("PreToolUse", OUTBOUND, "slop-gate-outbound.py")]

try:
    with open(settings) as f:
        data = json.load(f)
except Exception as e:
    raise SystemExit(f"  {settings} 를 읽지 못했다({e}) — 등록 생략. 수동 등록법은 /slop-gate 스킬에 있다")

hooks = data.setdefault("hooks", {})
added = []
for event, matcher, script in SPEC:
    # 홈 경로에 공백이 있으면 훅 커맨드가 word-split 돼 조용히 안 돈다
    cmd = f"{shlex.quote(py)} {shlex.quote(os.path.join(scripts, script))}"
    groups = hooks.setdefault(event, [])
    if any(script in str(h.get("command", "")) for g in groups for h in g.get("hooks", [])):
        continue
    for g in groups:
        if g.get("matcher") == matcher:
            g.setdefault("hooks", []).append({"type": "command", "command": cmd})
            break
    else:
        groups.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]})
    added.append(f"{event}:{script}")

if added:
    tmp = settings + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, settings)
    print("  + " + ", ".join(added))
else:
    print("  = 이미 등록됨")
PYEOF

cat <<'MSG'

설치 끝. 훅은 세션 시작 때 읽으니 /hooks 를 한 번 열거나 새 세션에서 돈다.

  검사만 해보기 : python3 ~/.claude/scripts/slop-gate.py --check 초안.md
  규칙 보기     : 클로드에 /deslop
  끄기·문제해결 : 클로드에 /slop-gate
MSG
