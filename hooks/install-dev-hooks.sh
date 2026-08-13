#!/bin/bash
# install-dev-hooks.sh — 개발(dev) 역할 팀원의 ~/.claude/settings.json 에
# PreToolUse 가드레일 훅을 **추가로** 등록한다.
#
# 왜 있나: dev 역할은 코드를 고치고 PR을 만든다. 보호 브랜치 직접 push,
#   prod main 머지, raw DDL, DB 파괴 명령을 훅 레벨에서 막아야 한다.
#   (스킬·CLAUDE.md 규칙은 무시될 수 있지만 훅은 무시할 수 없다)
#
# 안전 원칙:
#   - **기존 훅을 덮어쓰지 않는다.** 같은 command 가 이미 있으면 건너뛴다.
#   - matcher 그룹이 없으면 만들고, 있으면 append 한다.
#   - setup.sh(최초) / update.sh(매 세션) 양쪽에서 호출해도 안전(멱등).
#
# 사용: bash hooks/install-dev-hooks.sh [INSTALL_DIR]

set -u
INSTALL_DIR="${1:-$HOME/.caramel-team-setup}"
HOOKS_DIR="$INSTALL_DIR/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

command -v python3 >/dev/null 2>&1 || { echo "WARNING: python3 없음 — dev 훅 등록 생략" >&2; exit 0; }
[ -d "$HOOKS_DIR" ] || { echo "WARNING: $HOOKS_DIR 없음 — dev 훅 등록 생략" >&2; exit 0; }

mkdir -p "$HOME/.claude"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

PY_BIN="$(command -v python3)"

HOOKS_DIR="$HOOKS_DIR" SETTINGS_FILE="$SETTINGS_FILE" PY_BIN="$PY_BIN" python3 - <<'PYEOF'
import json, os, shlex, sys

hooks_dir = os.environ["HOOKS_DIR"]
settings_file = os.environ["SETTINGS_FILE"]
py = os.environ["PY_BIN"]

# (event, matcher, script) — 내 로컬 하니스와 동일 구성
SPEC = [
    ("PreToolUse", "Edit|Write", "caramel-zero-agents-gate.py"),
    ("PreToolUse", "Edit|Write", "prisma-migration-guard.py"),
    ("PreToolUse", "Bash", "db-guardrail.py"),
    ("PreToolUse", "Bash", "git-guardrail.py"),
    ("PreToolUse", "Bash", "caramel-deploy-gate.py"),
    ("PreToolUse", "Bash", "caramel-api-commit-guard.py"),
    ("PreToolUse", "Bash", "prod-main-merge-gate.py"),
    ("PreToolUse", "Bash", "prisma-migration-guard.py"),
]

try:
    with open(settings_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"WARNING: {settings_file} 읽기 실패({e}) — dev 훅 등록 생략", file=sys.stderr)
    sys.exit(0)

data.setdefault("hooks", {})
added = []

for event, matcher, script in SPEC:
    path = os.path.join(hooks_dir, script)
    if not os.path.exists(path):
        continue
    # 홈 경로에 공백이 있으면 훅 커맨드가 word-split 돼 훅이 조용히 안 돈다
    cmd = f"{shlex.quote(py)} {shlex.quote(path)}"
    groups = data["hooks"].setdefault(event, [])

    # 이미 등록돼 있으면(경로 무관, 스크립트명 기준) 건너뛴다.
    # matcher 단위로 본다 — prisma-migration-guard 처럼 Edit|Write 와 Bash 양쪽에
    # 걸려야 하는 훅이 있어서, event 전체로 보면 한쪽이 누락된다.
    if any(script in str(h.get("command", ""))
           for g in groups if g.get("matcher") == matcher
           for h in g.get("hooks", [])):
        continue

    for g in groups:
        if g.get("matcher") == matcher:
            g.setdefault("hooks", []).append({"type": "command", "command": cmd})
            break
    else:
        groups.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]})
    added.append(script)

if added:
    tmp = settings_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, settings_file)
    print("dev 가드레일 훅 등록: " + ", ".join(added))
else:
    print("dev 가드레일 훅 이미 등록됨")
PYEOF
