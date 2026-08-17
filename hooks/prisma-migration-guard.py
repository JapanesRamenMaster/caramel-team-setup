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
# 🔴 `migrate dev`만 면제한다. `migrate diff` 리다이렉트는 막는다 —
# 폴더명·타임스탬프·base 스키마를 사람이 골라 만든 것이라 결국 "내가 만든 파일"이고,
# 2026-08-14 사용자 재확인: "migration.sql은 migrate dev하며 자동으로 만들어진 것을
# 커밋해야 한다". 전례: #1567(diff로 뽑아 넣음) → #1568(되돌림).
PRISMA_INVOCATION = re.compile(
    r"prisma\s+migrate\s+dev\b", re.IGNORECASE
)

# 🔴 에이전트는 `migrate dev`를 직접 돌리지 않는다. 공유 dev DB에 적용되고
# 폴더·SQL까지 만들어지는데, 팀 방식은 "우리(에이전트)가 마이그레이션을 만들지
# 않는다"이다 — schema.prisma만 고치고 사람이 돌린다.
# 2026-08-14 실측: 내가 돌려서 만든 배지 마이그레이션이 리뷰 없이 develop에 들어갔고
# 되돌리는 데 dev DB 정리까지 필요해졌다.
MIGRATE_DEV_RUN = re.compile(
    r"(?:prisma\s+migrate\s+dev\b"
    r"|pnpm[^|;&]*\bdb:migrate\b"
    r"|\bdb:migrate\b)",
    re.IGNORECASE,
)

HOWTO = (
    "팀 방식: **마이그레이션 SQL은 우리가 만들지 않는다.**\n"
    "  1) 에이전트가 하는 것 = prisma/schema.prisma 수정, 거기까지다\n"
    "  2) 머지하지 말고 PR 상태에서 **개발팀 노진우(@yesjinu)님 리뷰**를 받는다\n"
    "     — PR에 스키마 검토 코멘트를 달 것: 컬럼별 목적 · nullable 이유 ·\n"
    "       기존 행 영향 · additive 확인 · 인덱스 영향 · 기각한 대안\n"
    "  3) `migrate dev`(폴더·SQL 생성 + 공유 dev DB 적용)는 **리뷰 후 진우님이 돌린다** —\n"
    "     🔴 사용자에게 실행을 요청하지 말 것. 사용자도 이걸 돌리지 않는다.\n"
    "     사용자에게 할 말은 '진우님께 리뷰 요청을 전달해달라'뿐이다\n"
    "  4) prod는 `_prisma_migrations`를 쓰지 않는다. DDL을 사람이 직접 친다\n"
    "     (PR 본문에 실행할 DDL을 적어 남길 것)\n"
    "\n"
    "🔴 `prisma migrate diff --script > migration.sql` 은 더 이상 우회로가 아니다.\n"
    "   폴더명·타임스탬프·base 스키마를 사람이 골라 만든 것이라 같은 지적에 걸린다\n"
    "   (#1567로 넣었다가 #1568로 되돌린 전례).\n"
    "🔴 공유 dev DB가 divergent해서 migrate dev가 리셋을 제안하면 **절대 승인하지 말고**\n"
    "   멈춰서 사용자에게 알린다. 승인하면 팀 공용 dev DB가 날아간다.\n"
    "🔴 DB에 직접 DDL(CREATE TABLE 등)을 치는 것도 금지다. dev 적용도 migrate dev로만.\n"
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

        # 에이전트가 migrate dev를 직접 돌리는 것 자체를 막는다.
        # 이걸 돌리면 ①공유 dev DB가 바뀌고 ②마이그레이션 폴더·SQL이 생긴다 —
        # 둘 다 사람이 할 일이다.
        if MIGRATE_DEV_RUN.search(normalized):
            deny(
                "[prisma-migration-guard] 차단: `migrate dev`는 에이전트가 돌리지 않습니다.\n"
                "이 명령은 공유 dev DB를 바꾸고 마이그레이션 폴더·SQL까지 만듭니다 —\n"
                "팀 방식은 '마이그레이션은 우리가 만들지 않는다'입니다.\n"
                "스키마를 dev에 적용해야 하면 **개발팀 노진우(@yesjinu)님이 리뷰 후 돌립니다.**\n"
                "🔴 사용자에게 `pnpm db:migrate` 실행을 요청하지 마세요 — 사용자도 안 돌립니다.\n"
                "지금 할 일: PR에 스키마 검토 코멘트를 달고 @yesjinu 를 리뷰어로 지정한 뒤,\n"
                "사용자에게는 **'진우님께 리뷰 요청을 전달해달라'**고만 하세요.\n"
                "  gh pr edit <번호> --add-reviewer yesjinu\n\n"
                + HOWTO
            )
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
