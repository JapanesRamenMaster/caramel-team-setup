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
BASH_WRITE = re.compile(
    r"(?:>>?\s*\S*migration\.sql"          # > migration.sql, >> migration.sql
    r"|tee\s+\S*migration\.sql"            # tee migration.sql
    r"|\b(?:cp|mv|install)\s+[^|;&]*migration\.sql"
    r"|sed\s+-i[^|;&]*migration\.sql"
    r"|(?:cat|echo|printf)\s[^|;&]*>\s*\S*migration\.sql"
    # 인터프리터로 파일을 쓰는 경로(python3 -c "open(...,'w')" 등).
    # 읽기만 하는 스크립트도 걸리지만, 과차단이 누락보다 싸다 —
    # 막히면 prisma migrate diff 로 만들면 된다.
    r"|(?:python3?|node|perl|ruby|deno|bun)\b[^|;&]*migration\.sql)",
    re.IGNORECASE,
)

# Prisma가 실제로 SQL을 만들어내는 호출. 경로 문자열(prisma/migrations/…)과 구분해야 한다.
PRISMA_INVOCATION = re.compile(
    r"prisma\s+migrate\s+(?:diff|dev)\b", re.IGNORECASE
)

HOWTO = (
    "올바른 경로:\n"
    "  1) prisma/schema.prisma 를 먼저 고친다\n"
    "  2) 정상: cd apps/api && pnpm db:migrate   (= prisma migrate dev, 폴더+SQL을 Prisma가 만든다)\n"
    "  3) 공유 dev DB가 divergent해서 2)가 리셋을 제안하면 — DB에 접속하지 않는 경로:\n"
    "     git show origin/develop:apps/api/prisma/schema.prisma > /tmp/base.prisma\n"
    "     pnpm exec prisma migrate diff \\\n"
    "       --from-schema-datamodel /tmp/base.prisma \\\n"
    "       --to-schema-datamodel prisma/schema.prisma \\\n"
    "       --script > prisma/migrations/<타임스탬프>_<이름>/migration.sql\n"
    "     ↑ Prisma 출력을 그대로 리다이렉트하는 것이라 이 훅을 통과한다\n"
    "  4) 생성된 SQL에서 DROP·TRUNCATE·RENAME·MODIFY 를 grep해 additive인지 확인\n"
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
        # ⚠️ `\bprisma\b`로 검사하면 안 된다 — 경로(prisma/migrations/...)에 항상
        #    그 단어가 있어서 면제가 늘 켜진다. Prisma "호출"만 면제한다.
        if BASH_WRITE.search(normalized) and not PRISMA_INVOCATION.search(normalized):
            deny(
                "[prisma-migration-guard] 차단: migration.sql 에 쓰는 명령에 prisma 가 없습니다.\n"
                "이 파일 내용은 Prisma가 스키마에서 뽑아낸 것이어야 합니다(팀 규칙).\n\n"
                + HOWTO
            )
        allow()

    allow()


if __name__ == "__main__":
    main()
