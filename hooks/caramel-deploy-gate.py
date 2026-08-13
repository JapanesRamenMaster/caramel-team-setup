#!/usr/bin/env python3
"""
caramel-deploy 게이트
gh pr create 가 caramel 레포에서 호출될 때 /caramel-deploy 스킬 실행 여부를 확인한다.
세션 내 스킬 실행 여부는 /tmp/caramel-deploy-ran-<session_id> 파일로 추적한다.
"""
import json
import os
import sys
import re

def is_caramel_repo():
    cwd = os.getcwd()
    caramel_repos = ["caramel-api", "caramel-zero", "caramel-sales-admin",
                     "caramel-app", "caramel-detailer-app"]
    return any(repo in cwd for repo in caramel_repos)

def is_pr_create(tool_input: dict) -> bool:
    command = tool_input.get("command", "")
    # 첫 번째 실제 명령어가 gh pr create인 경우만 (heredoc/string 안은 제외)
    first_line = command.strip().split("\n")[0].strip()
    return bool(re.match(r"gh\s+pr\s+create\b", first_line))

FLAG_PATH = "/tmp/caramel-deploy-ran"
SESSION_WINDOW_HOURS = 4

# 이 레포들은 PR base가 반드시 develop 이어야 한다. main 직행 금지.
# (main=prod 자동배포라 main 머지=dev 검증 스킵 + 프로덕션 직행. 2026-07-10 PR #783 사고)
# develop 은 항상 main 의 superset 이어야 하며, feature→main 은 이 불변식을 깬다.
DEVELOP_BASE_REPOS = ("caramel-zero", "caramel-api")


def base_branch_violation(tool_input: dict):
    """caramel-zero/caramel-api 에서 feature→main PR 이면 차단 메시지 반환, 아니면 None."""
    command = tool_input.get("command", "")
    first_line = command.strip().split("\n")[0].strip()
    if not re.match(r"gh\s+pr\s+create\b", first_line):
        return None
    cwd = os.getcwd()
    repo = next((r for r in DEVELOP_BASE_REPOS if r in cwd), None)
    if not repo:
        return None
    base_m = re.search(r"(?:--base|-B)[=\s]+(\S+)", first_line)
    base = base_m.group(1).strip("'\"") if base_m else None
    head_m = re.search(r"(?:--head|-H)[=\s]+(\S+)", first_line)
    head = head_m.group(1).strip("'\"") if head_m else None

    if base is None:
        return (
            f"[base 가드] {repo} PR은 base를 명시해야 합니다 → `--base develop`.\n"
            "  main=prod 자동배포라 base 미지정(기본값 main 가능)은 위험합니다.\n"
            "  main 승격이 목적이면 `--head develop --base main` 으로 명시하세요."
        )
    if base == "main" and head != "develop":
        return (
            f"[base 가드] {repo} feature→main PR 차단.\n"
            "  이 레포는 base=develop 필수입니다 (main=prod 자동배포 → dev 검증 스킵됨).\n"
            "  → `gh pr create --base develop ...` 로 다시 실행하세요.\n"
            "  main 승격은 develop→main PR(`--head develop --base main`)로만 합니다."
        )
    return None

def deploy_skill_ran() -> bool:
    if not os.path.exists(FLAG_PATH):
        return False
    import time
    age_seconds = time.time() - os.path.getmtime(FLAG_PATH)
    return age_seconds < SESSION_WINDOW_HOURS * 3600

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool_input = data.get("tool_input", {})

    # base 브랜치 가드: caramel-zero/caramel-api feature→main PR 하드 차단
    violation = base_branch_violation(tool_input)
    if violation:
        print(violation, file=sys.stderr)
        sys.exit(2)

    if not is_pr_create(tool_input):
        sys.exit(0)

    if not is_caramel_repo():
        sys.exit(0)

    if deploy_skill_ran():
        sys.exit(0)

    # 차단: /caramel-deploy 안 했으면 경고
    print(
        "[caramel-deploy 게이트] PR 생성 전 /caramel-deploy 스킬을 실행하세요.\n"
        "  - 레포별 배포 체크리스트 확인 (Prisma, DB, conflict 패턴 등)\n"
        "  - 실행 후 이 PR 명령을 다시 시도하세요.\n"
        "  - 이미 확인했다면: touch " + FLAG_PATH + " 후 재시도",
        file=sys.stderr
    )
    # exit 2 = block (Claude Code hook convention)
    sys.exit(2)

if __name__ == "__main__":
    main()
