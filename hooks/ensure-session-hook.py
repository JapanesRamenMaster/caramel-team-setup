#!/usr/bin/env python3
"""settings.json의 SessionStart에 훅 하나를 '추가'한다. 절대 대입하지 않는다.

왜 있나: setup.sh가 `.hooks.SessionStart = [...]` 로 대입해서, 자기 훅을 쓰던
사람이 팀 셋업을 돌리면 기존 SessionStart 훅이 전부 사라졌다. 같은 로직이
setup.sh(글로벌/프로젝트)와 update.sh 세 군데에 복사돼 있었고 형식도 서로
달라져 있었다(update.sh는 matcher 그룹이 아니라 훅 객체를 바로 넣었다).

사용: ensure-session-hook.py <settings.json> <command> [timeout]
멱등: command 문자열이 이미 SessionStart에 있으면 아무것도 안 한다.
"""
import json
import os
import sys


def main():
    if len(sys.argv) < 3:
        return 0
    target, command = sys.argv[1], sys.argv[2]
    timeout = sys.argv[3] if len(sys.argv) > 3 else None

    if os.path.exists(target):
        try:
            with open(target) as f:
                data = json.load(f)
        except Exception:
            # 남의 설정 파일이 깨져 있으면 건드리지 않는다.
            return 0
    else:
        os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
        data = {}

    if not isinstance(data, dict):
        return 0
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        return 0
    groups = hooks.setdefault("SessionStart", [])
    if not isinstance(groups, list):
        return 0

    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []):
            if isinstance(hook, dict) and command in hook.get("command", ""):
                return 0  # 이미 있음

    entry = {"type": "command", "command": command}
    if timeout:
        entry["timeout"] = int(timeout)
    groups.append({"matcher": "", "hooks": [entry]})

    tmp = target + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, target)
    print("SessionStart 훅 등록: %s" % target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
