#!/usr/bin/env python3
"""PreToolUse(전체 툴) 차단 집행기 — fail-closed.

게이트 마커가 FAIL(또는 없음=게이트 미실행)이면 모든 도구 호출을 deny.
escape 파일이 있으면 통과(메인테이너 긴급 우회).
"""
import json
import os
import sys

HOME = os.path.expanduser("~")
STATE_FILE = os.path.join(HOME, ".claude", ".safe-action-gate-state")
DISABLE_FILE = os.path.join(HOME, ".claude", ".safe-action-gate-disable")

RECOVER = ("터미널에서  bash ~/.caramel-team-setup/update.sh  실행 후 새 세션을 여세요. "
           "그래도 안 되면  bash ~/.caramel-team-setup/team-diagnose.sh  결과를 맹주성님께 전달하세요.")


def allow():
    sys.exit(0)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    # stdin은 소비하되 내용은 불필요 (모든 툴 동일 차단)
    try:
        sys.stdin.read()
    except Exception:
        pass

    # escape hatch
    if os.path.exists(DISABLE_FILE):
        allow()

    # 마커 읽기
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except Exception:
        deny("[안전세팅] 세팅 게이트가 실행되지 않았습니다(마커 없음). "
             "안전 체인이 설치되지 않았거나 깨졌습니다. " + RECOVER)

    if state.get("status") == "PASS":
        allow()

    deny("[안전세팅] 세팅이 깨져 모든 작업이 차단됩니다. 사유: "
         + (state.get("reasons") or "(불명)") + ". " + RECOVER)


if __name__ == "__main__":
    main()
