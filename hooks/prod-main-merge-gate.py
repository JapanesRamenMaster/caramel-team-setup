#!/usr/bin/env python3
"""prod-main-merge-gate — 고객/디테일러 제품 레포의 main 머지는 사용자 명시 승인 후에만.

PreToolUse(Bash) 훅. `gh pr merge`(또는 gh api pulls/N/merge)가 prod 레포의
main/master 타겟 PR을 머지하려 하면 deny한다. 어드민(caramel-sales-admin)은 예외.
승인 절차: 사용자에게 해당 PR의 main 머지를 명시적으로 물어 승인받은 뒤,
같은 명령 앞에 `PROD_MERGE_APPROVED=1 `을 붙여 재실행 (승인 없이 마커 금지).
배경: 2026-07-13 디테일러앱 OTA가 main 머지로 자동 발행된 건 — 사용자 지시로 게이트化.
"""
import json
import re
import subprocess
import sys

PROD_REPOS = {
    "the-trive/caramel-zero",
    "the-trive/caramel-api",
    "the-trive/caramel-app",
    "the-trive/caramel-detailer-app",
}
PROD_NAMES = {r.split("/", 1)[1] for r in PROD_REPOS}
EXEMPT_NAMES = {"caramel-sales-admin"}
PROTECTED_BASES = {"main", "master"}
MARKER = "PROD_MERGE_APPROVED=1"


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))
    sys.exit(0)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""

    is_pr_merge = "gh pr merge" in cmd
    is_api_merge = re.search(r"gh api\b.*pulls/\d+/merge", cmd) is not None
    if not (is_pr_merge or is_api_merge):
        return

    # repo 결정: --repo/-R 플래그 → URL 형태 → api 경로 → cwd 추론
    repo = None
    m = re.search(r"(?:--repo|-R)[= ]([\w.-]+/[\w.-]+)", cmd)
    if m:
        repo = m.group(1)
    if not repo:
        m = re.search(r"github\.com/([\w.-]+/[\w.-]+)/pull", cmd)
        if m:
            repo = m.group(1)
    if not repo:
        m = re.search(r"repos/([\w.-]+/[\w.-]+)/pulls/\d+/merge", cmd)
        if m:
            repo = m.group(1)
    if not repo:
        cwd = data.get("cwd") or ""
        for name in PROD_NAMES | EXEMPT_NAMES:
            if re.search(rf"/{re.escape(name)}(/|$)", cwd):
                repo = f"the-trive/{name}"
                break

    if repo is None:
        # prod 레포 이름이 명령/경로 어디에도 없으면 관여하지 않음
        if not any(name in cmd for name in PROD_NAMES):
            return
        deny("[prod-main-merge-gate] gh pr merge의 대상 레포를 확정할 수 없다. "
             "--repo owner/repo를 명시해 재실행하라. (prod 레포 main 머지는 사용자 승인 필수)")

    name = repo.split("/", 1)[1]
    if name in EXEMPT_NAMES or repo not in PROD_REPOS:
        return

    if MARKER in cmd:
        return  # 사용자 승인 마커 — 대화에서 명시 승인 받은 뒤에만 붙일 것

    # PR 번호
    m = re.search(r"gh pr merge\s+(?:https://github\.com/[\w.-]+/[\w.-]+/pull/)?(\d+)", cmd)
    if not m:
        m = re.search(r"pulls/(\d+)/merge", cmd)
    if not m:
        deny(f"[prod-main-merge-gate] {repo}에서 PR 번호 없는 gh pr merge. "
             "PR 번호를 명시해 재실행하라 (base 확인 필요).")
    num = m.group(1)

    # base 브랜치 조회 (확인 불가 시 보수적으로 차단)
    try:
        r = subprocess.run(
            ["gh", "pr", "view", num, "--repo", repo, "--json", "baseRefName",
             "-q", ".baseRefName"],
            capture_output=True, text=True, timeout=8,
        )
        base = r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        base = ""

    if not base:
        deny(f"[prod-main-merge-gate] {repo}#{num}의 base 브랜치를 확인할 수 없어 차단. "
             "PR 번호/레포를 확인하라.")

    if base in PROTECTED_BASES:
        deny(f"[prod-main-merge-gate] 🔒 {repo}#{num}의 base가 '{base}' — prod 자동배포 대상이다. "
             "고객/디테일러 제품의 main 머지는 사용자 명시 승인 필수. "
             "① 사용자에게 이 PR의 main 머지(=prod 배포/OTA)를 물어 승인받고 "
             f"② 승인 후 같은 명령 앞에 `{MARKER} `를 붙여 재실행하라. "
             "승인 없이 마커를 붙이는 것은 금지. (어드민 sales-admin은 이 게이트 비대상)")

    return  # base가 develop 등 → 통과


if __name__ == "__main__":
    main()
