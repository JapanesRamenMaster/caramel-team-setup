#!/usr/bin/env python3
"""
caramel-api commit guard
caramel-api에서 git commit 시 Prisma createMany 관련 파일이 staged 됐으면
lint-staged 제거 위험 경고를 출력한다.
"""

import sys
import json
import subprocess
import os

def main():
    try:
        input_data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input", {})

    if tool_name != "Bash":
        sys.exit(0)

    command = tool_input.get("command", "")

    # git commit 명령인지 확인
    if "git commit" not in command:
        sys.exit(0)

    # caramel-api 레포인지 확인
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, cwd=os.getcwd()
        )
        repo_root = result.stdout.strip()
        if "caramel-api" not in repo_root:
            sys.exit(0)
    except Exception:
        sys.exit(0)

    # Prisma createMany 관련 파일이 staged 됐는지 확인
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            capture_output=True, text=True, cwd=repo_root
        )
        staged_files = result.stdout.strip().split("\n")
    except Exception:
        sys.exit(0)

    prisma_service_files = [
        f for f in staged_files
        if "service.ts" in f and any(
            keyword in f for keyword in ["crm", "quote", "reservation", "subscription"]
        )
    ]

    if not prisma_service_files:
        sys.exit(0)

    # 경고 출력
    print(f"""⚠️  [caramel-api commit guard]
Prisma 서비스 파일이 staged 됨: {', '.join(prisma_service_files)}

lint-staged(ultracite)가 createMany data에 추가한 필드를 자동 제거할 수 있습니다.
커밋 후 반드시 확인:
  git show HEAD:파일경로 | grep 추가한_필드명

결과 없으면 → 맹주성님 터미널에서 직접 커밋 필요.
배포 후 → DB SELECT로 신규 컬럼 값 저장 여부 확인 필수.""", file=sys.stderr)

    # 커밋은 진행 (차단 아님, 경고만)
    sys.exit(0)

if __name__ == "__main__":
    main()
