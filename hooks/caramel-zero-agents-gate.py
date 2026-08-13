#!/usr/bin/env python3
"""caramel-zero 작업 시 AGENTS.md 읽기 알림 (세션당 1회).

PreToolUse(Edit|Write)에서 파일 경로가 caramel-zero를 포함하면
세션 첫 진입 시 1회 알림. PPID 기반 플래그 파일로 중복 방지.
"""
import sys
import json
import os

data = json.load(sys.stdin)

file_path = (
    data.get("tool_input", {}).get("file_path")
    or data.get("tool_input", {}).get("old_string", "")[:100]
    or ""
)

if "caramel-zero" not in file_path:
    sys.exit(0)

flag = f"/tmp/czero-agents-{os.getppid()}"
if os.path.exists(flag):
    sys.exit(0)

open(flag, "w").close()

print(json.dumps(
    {
        "systemMessage": "📋 [caramel-zero 진입] AGENTS.md → START_HERE → STRUCTURE_BLUEPRINT → DEVELOPMENT_WORKFLOW 순서로 먼저 읽으세요!",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": (
                "⚠️ caramel-zero 작업 감지 — 이 세션에서 AGENTS.md를 아직 읽지 않았습니다.\n"
                "작업 전 반드시 아래 순서로 읽으세요:\n"
                "  1. ~/Desktop/Github/caramel-zero/AGENTS.md\n"
                "  2. ~/Desktop/Github/caramel-zero/.docs/START_HERE.md\n"
                "  3. ~/Desktop/Github/caramel-zero/.docs/STRUCTURE_BLUEPRINT.md\n"
                "  4. ~/Desktop/Github/caramel-zero/.docs/DEVELOPMENT_WORKFLOW.md\n"
                "  5. ~/Desktop/Github/caramel-zero/.docs/CODE_QUALITY_CHECKLIST.md\n"
                "  6. 활성 .tasks/in-progress/*/task.md\n"
                "주의: 커밋 전 'source ~/.nvm/nvm.sh && nvm use 22' 필수."
            ),
        },
    }
))
