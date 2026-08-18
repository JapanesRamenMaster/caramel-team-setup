#!/usr/bin/env python3
"""PreToolUse 가드 — migration.sql은 반드시 Prisma가 생성해야 한다.

노진우(팀 개발자) 리뷰 지적(2026-07-27, caramel-zero PR #1119):
  "migration.sql 파일은 항상 prisma가 생성해야 합니다. 에이전트가 임의 생성하면 안 돼요."

에이전트가 손으로 SQL을 적어 넣으면 스키마와 DDL이 어긋나도 아무도 모른다.
Prisma가 스키마에서 뽑아낸 결과만 파일에 들어가야 한다.

차단 규칙:
- Write / Edit / NotebookEdit 로 prisma/migrations/**/migration.sql 을 만들거나 고치는 것 → deny
- Bash 로 그 경로에 쓰는 것(> >> tee cp mv sed -i) → 명령에 prisma 가 없으면 deny
  (`prisma migrate diff ... --script > migration.sql` 처럼 Prisma 출력을 그대로
   흘려넣는 것은 통과. 사람·에이전트가 옮겨 적는 것만 막는다.)
- 삭제(rm)는 막지 않는다. 잘못 만든 파일을 지우는 것이 정상 복구 경로다.
"""
import json
import re
import subprocess
import sys


def allow():
    sys.exit(0)


def deny(reason: str):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


MIGRATION_PATH = re.compile(
    r"prisma/migrations/[^/\s\"']+/migration\.sql", re.IGNORECASE
)

# Bash에서 "그 경로에 쓴다"고 볼 신호
# ⚠️ 경로가 따옴표로 감싸인 경우(`cp x "…/migration.sql"`)도 잡아야 하므로
#    이 검사는 따옴표를 걷어내지 않은 원문에 돌린다.
BASH_WRITE = re.compile(
    r"(?:>>?\s*\S*migration\.sql"          # > migration.sql, >> migration.sql
    r"|tee\s+\S*migration\.sql"            # tee migration.sql
    r"|\b(?:cp|mv|install)\s+[^|;&]*migration\.sql"
    r"|sed\s+-i[^|;&]*migration\.sql"
    r"|(?:cat|echo|printf)\s[^|;&]*>\s*\S*migration\.sql)",
    re.IGNORECASE,
)

# 인터프리터로 migration.sql을 건드리는 경로(python3 -c "open(...,'w')" 등).
# 🔴 예전엔 이 절이 BASH_WRITE 안에 있어 **읽기만 하는 명령까지 막았다**
#    (2026-08-18: `python3 -c "print(open('…/migration.sql').read())"`,
#     PR 조회 파이프에서 migration.sql을 grep 바늘로 쓴 명령이 차단됨).
#    쓰기 흔적이 같이 있을 때만 막는다.
INTERPRETER_TOUCH = re.compile(
    r"(?:python3?|node|perl|ruby|deno|bun)\b[^|;&]*migration\.sql",
    re.IGNORECASE,
)
WRITE_HINT = re.compile(
    r"""['"]w[b+]?['"]|\.write\(|writeFile|open\([^)]*,\s*['"]a""",
    re.IGNORECASE,
)

# 따옴표 안 문자열은 "실행되는 명령"이 아니라 데이터다 — 안내문·grep 바늘·JSON 본문 등.
# 단 아래 두 경우엔 데이터가 곧 명령이므로 원문을 그대로 판정한다.
#   ① 셸이 문자열을 실행한다: sh -c '…' · bash -c "…" · eval
#   ② 인터프리터가 프로세스를 띄운다: os.system · subprocess · child_process · 백틱
QUOTED_SPAN = re.compile(r"'[^']*'|\"[^\"]*\"", re.DOTALL)
SHELL_EXEC = re.compile(
    r"\b(?:sh|bash|zsh|dash|ksh)\b[^|;&]*\s-c\b|\beval\b", re.IGNORECASE
)
SPAWN_HINT = re.compile(
    r"os\.system|subprocess|child_process|execSync|spawnSync|popen|`", re.IGNORECASE
)


def executable_text(command):
    """판정 대상 텍스트. 따옴표 안은 데이터로 보고 걷어낸다(위 ①② 예외)."""
    if SHELL_EXEC.search(command) or SPAWN_HINT.search(command):
        return command
    return QUOTED_SPAN.sub(" ", command)

# Prisma가 실제로 SQL을 만들어내는 호출. 경로 문자열(prisma/migrations/…)과 구분해야 한다.
# 🔴 `migrate dev`만 면제한다. `migrate diff` 리다이렉트는 막는다 —
# 폴더명·타임스탬프·base 스키마를 사람이 골라 만든 것이라 결국 "내가 만든 파일"이고,
# 2026-08-14 사용자 재확인: "migration.sql은 migrate dev하며 자동으로 만들어진 것을
# 커밋해야 한다". 전례: #1567(diff로 뽑아 넣음) → #1568(되돌림).
PRISMA_INVOCATION = re.compile(
    r"prisma\s+migrate\s+dev\b", re.IGNORECASE
)

# `migrate dev` 실행 자체는 **이제 정규 경로다**(2026-08-18 팀 컨벤션, 최재웅).
#   "schema.prisma 변경을 포함한 모든 PR은 migrate dev로부터 생성된 migration.sql을
#    포함해야만 머지 시 dev DB에 반영된다. PR 올리기 전 로컬에서 돌려라.
#    AI한테 돌려달라고 하면 된다. 로컬 migrate dev는 dev DB에 영향을 주지 않는다."
#
# 실측 확인(2026-08-18): 루트 스크립트가 `auto`를 'local'로 풀고 루트 `.env.local`의
# `DATABASE_URL = mysql://root@127.0.0.1:3306/caramel-dev`(로컬 MySQL)을 태운다.
#
# 🔴 그래서 막아야 하는 건 "누가 돌리나"가 아니라 **"무엇을 가리킨 채 돌리나"**다.
# 아래 둘 중 하나면 팀 공용 DB에 적용된다:
#   ① APP_ENV=dev|prod 로 공용 env 레이어를 강제하는 것
#   ② kubectl port-forward 가 살아 있어 127.0.0.1:3306 이 공용 dev를 가리키는 것
MIGRATE_DEV_RUN = re.compile(
    r"(?:prisma\s+migrate\s+dev\b"
    r"|pnpm[^|;&]*\bdb:migrate\b"
    r"|\bdb:migrate\b)",
    re.IGNORECASE,
)

# ① 공용 env 강제.
# ⚠️ `run-app-with-env` 쪽은 **세 번째 위치 인자(env 이름)만** 본다.
#    느슨하게 `\sdev\s`로 잡으면 `... auto sh -c 'prisma migrate dev'`의 `dev`가
#    걸려서 정규 경로가 막힌다(2026-08-18 오탐 실측).
#    인자 순서: run-app-with-env.mjs <app> <dir> <envName>
SHARED_ENV_FORCED = re.compile(
    r"\bAPP_ENV\s*=\s*[\"']?(?:dev|prod|production)\b"
    r"|\bNODE_ENV\s*=\s*[\"']?production\b"
    r"|run-app-with-env\S*\s+\S+\s+\S+\s+(?:dev|prod)\b",
    re.IGNORECASE,
)

# `migrate deploy`는 CI·prod 경로다. 로컬에서 돌릴 일이 없다.
MIGRATE_DEPLOY_RUN = re.compile(
    r"prisma\s+migrate\s+deploy\b|\bdb:migrate:deploy\b", re.IGNORECASE
)


def port_forward_active() -> bool:
    """port-forward 가 3306 을 열어두면 127.0.0.1 이 공용 DB를 가리킨다."""
    try:
        result = subprocess.run(
            ["pgrep", "-fl", "port-forward"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        # 판정 불가면 막지 않는다 — 이 훅의 다른 규칙은 여전히 살아 있다.
        return False

    return bool(re.search(r"3306|mysql", result.stdout, re.IGNORECASE))

HOWTO = (
    "팀 컨벤션(2026-08-18, 최재웅): "
    "**schema.prisma를 바꾼 PR은 migration.sql을 포함해야 한다.**\n"
    "  1) prisma/schema.prisma 를 고친다\n"
    "  2) apps/api 에서 마이그레이션 스크립트를 돌린다 — 로컬 MySQL에 적용되고\n"
    "     prisma/migrations/<타임스탬프>_<이름>/ 폴더와 SQL이 생긴다\n"
    "  3) 그 폴더를 커밋한다\n"
    "  4) PR에 스키마 검토 코멘트를 달고 @yesjinu 리뷰를 받는다(머지 전 승인 필수)\n"
    "  5) prod는 `_prisma_migrations`를 쓰지 않는다 — 그 SQL을 사람이 직접 친다\n"
    "     (PR 본문에 실행할 DDL을 적어 남길 것)\n"
    "\n"
    "migration.sql 이 없으면 머지해도 **dev DB에 스키마가 반영되지 않는다.**\n"
    "trive_development 채널의 `Prisma diff: failure` 가 그 신호다.\n"
    "\n"
    "🔴 `prisma migrate diff --script >` 로 파일을 만드는 것은 우회로가 아니다.\n"
    "   폴더명·타임스탬프·base 스키마를 사람이 골라 만든 것이라 같은 지적에 걸린다\n"
    "   (#1567로 넣었다가 #1568로 되돌린 전례). 파일은 migrate 산물만 쓴다.\n"
    "🔴 리셋 제안이 뜨면 **절대 승인하지 말고** 멈춰서 사용자에게 알린다.\n"
    "   로컬이어도 데이터가 날아가고, 공용을 가리킨 상태였다면 팀 dev가 날아간다.\n"
    "🔴 DB에 직접 DDL(CREATE TABLE 등)을 치는 것은 여전히 금지다(db-guardrail).\n"
    "\n"
    "잘못 만든 파일이 이미 있으면 rm 으로 지우고 위 절차로 다시 만든다(rm은 막지 않는다)."
)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        allow()

    tool = payload.get("tool_name") or payload.get("toolName") or ""
    params = payload.get("tool_input") or payload.get("toolInput") or {}

    if tool in ("Write", "Edit", "NotebookEdit"):
        target = str(params.get("file_path") or params.get("notebook_path") or "")
        if MIGRATION_PATH.search(target.replace("\\", "/")):
            deny(
                "[prisma-migration-guard] 차단: migration.sql 을 손으로 쓰거나 고칠 수 없습니다.\n"
                "이 파일은 반드시 Prisma가 생성해야 합니다(팀 규칙, 노진우 2026-07-27).\n"
                "에이전트가 SQL을 옮겨 적으면 schema.prisma와 DDL이 어긋나도 아무도 못 잡습니다.\n\n"
                + HOWTO
            )
        allow()

    if tool == "Bash":
        command = str(params.get("command") or "")
        normalized = command.replace("\\", "/")

        # ⚠️ 따옴표 안 인용문에는 반응하지 않는다 — PR 코멘트·안내문에 절차를 적는 것은
        #    실행이 아니다(2026-08-18 오발동 수정).
        executable = executable_text(normalized)

        if MIGRATE_DEPLOY_RUN.search(executable):
            deny(
                "[prisma-migration-guard] 차단: `migrate deploy`는 CI·prod 경로입니다.\n"
                "로컬에 스키마를 적용할 때는 apps/api 의 마이그레이션 스크립트를 쓰세요.\n"
                "prod는 `_prisma_migrations`를 쓰지 않고 사람이 DDL을 직접 칩니다.\n\n"
                + HOWTO
            )

        # 🔴 실행 자체는 정규 경로다. **공용 DB를 가리킨 채 돌리는 것만** 막는다.
        if MIGRATE_DEV_RUN.search(executable):
            if SHARED_ENV_FORCED.search(executable):
                deny(
                    "[prisma-migration-guard] 차단: 공용 env(dev/prod)를 강제한 채 "
                    "마이그레이션을 돌리려 합니다.\n"
                    "이러면 **팀 공용 DB**에 적용되고 리셋 제안까지 뜰 수 있습니다.\n"
                    "`APP_ENV` 지정을 빼고 그냥 돌리세요 — auto가 'local'로 풀려\n"
                    "로컬 MySQL(127.0.0.1)을 가리킵니다.\n\n"
                    + HOWTO
                )
            if port_forward_active():
                deny(
                    "[prisma-migration-guard] 차단: `port-forward` 가 살아 있습니다.\n"
                    "그 상태로는 `.env.local` 의 127.0.0.1:3306 이 **공용 dev DB**를 가리켜서\n"
                    "로컬에 적용하려던 마이그레이션이 팀 DB에 들어갑니다.\n"
                    "포트포워드를 끄고 다시 돌리세요.\n\n"
                    + HOWTO
                )
        # ⚠️ `\bprisma\b`로 검사하면 안 된다 — 경로(prisma/migrations/...)에 항상
        #    그 단어가 있어서 면제가 늘 켜진다. Prisma "호출"만 면제한다.
        writes_migration_sql = BASH_WRITE.search(normalized) or (
            INTERPRETER_TOUCH.search(normalized) and WRITE_HINT.search(normalized)
        )
        if writes_migration_sql and not PRISMA_INVOCATION.search(normalized):
            deny(
                "[prisma-migration-guard] 차단: migration.sql 에 쓰는 명령에 prisma 가 없습니다.\n"
                "이 파일 내용은 Prisma가 스키마에서 뽑아낸 것이어야 합니다(팀 규칙).\n\n"
                + HOWTO
            )
        allow()

    allow()


if __name__ == "__main__":
    main()
