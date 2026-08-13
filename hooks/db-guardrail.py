#!/usr/bin/env python3
"""PreToolUse(Bash) DB 파괴 방어 가드레일.

DROP TABLE / DROP DATABASE / TRUNCATE / prisma --accept-data-loss 등
되돌릴 수 없는 DB 파괴 패턴을 bypassPermissions · autoMode 무관하게 차단한다.

설계 원칙:
- CREATE TABLE, ALTER TABLE ADD/MODIFY (추가성 DDL)는 통과.
- DROP TABLE, DROP DATABASE, TRUNCATE, DROP COLUMN 은 무조건 deny.
- prisma --accept-data-loss / migrate reset / --force-reset 은 무조건 deny.
- 파일에 SQL을 쓰는 행위(echo "DROP..." > file.sql)는 실행이 아니므로 통과.
  → mysql/prisma 실행 컨텍스트가 있을 때만 차단.
- 오탐보다 과차단을 선택한다. 막혔으면 직접 터미널에서 실행.
"""
import json
import re
import sys


def allow():
    sys.exit(0)


def deny(reason: str):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


# ── 패턴 ────────────────────────────────────────────────────────────────────

# 1. Prisma 위험 플래그 (따옴표 여부 무관, 명령 어디에 있어도 위험)
PRISMA_DANGER = re.compile(
    r"(?:npx\s+)?(?:dotenv\s+-e\s+\S+\s+--\s+)?(?:npx\s+)?prisma\b"
    r".*?(?:--accept-data-loss|--force-reset|migrate\s+reset)",
    re.IGNORECASE | re.DOTALL,
)

# 2. MySQL 실행 컨텍스트
#    mysql-query.sh, mysql-write.sh, ~/claude/mysql-query.sh,
#    mysql -h ... -e "SQL", mysql -u ... <<EOF
MYSQL_EXEC = re.compile(
    r"(?:mysql(?:-query|-write)?(?:\.sh)?|mysql\b(?:\s+-\w+)*\s+-e\b)",
    re.IGNORECASE,
)

# 3. SQL 파괴 패턴
SQL_DESTRUCTIVE = re.compile(
    r"\b(?:DROP\s+(?:TABLE|DATABASE|SCHEMA|COLUMN)|TRUNCATE(?:\s+TABLE)?)\b",
    re.IGNORECASE,
)

# 4. SSH + mysql 조합 (원격 DROP)
SSH_MYSQL = re.compile(r"\bssh\b.*?\bmysql\b", re.DOTALL | re.IGNORECASE)

# 5. 잘못된 레포(caramel-api)에 prisma 스키마 작업 → DB 형상 SOT는 caramel-zero
#    db push / migrate 를 outdated caramel-api 스키마 대상으로 돌리면 테이블 삭제 사고남
#    (2026-06-08 dev DB 테이블 4개 삭제, 2026-06-15 노진우 정정)
PRISMA_PUSH_MIGRATE = re.compile(
    r"prisma\b.*?(?:db\s+push|migrate\s+(?:dev|deploy|diff|resolve))",
    re.IGNORECASE | re.DOTALL,
)
WRONG_REPO_PRISMA = re.compile(
    r"libs/caramel-prisma|caramel-api\b",
    re.IGNORECASE,
)


def strip_quotes(text: str) -> str:
    """따옴표로 둘러싼 문자열 내용을 제거한다 (echo '...' 오탐 방지)."""
    text = re.sub(r"'[^']*'", " ", text)
    text = re.sub(r'"[^"]*"', " ", text)
    return text


def strip_heredocs(text: str) -> str:
    """heredoc 본문을 제거한다."""
    return re.sub(
        r"<<-?\s*[\"']?(\w+)[\"']?.*?\n\s*\1\b",
        " ",
        text,
        flags=re.DOTALL,
    )


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()

    raw_cmd = (data.get("tool_input", {}) or {}).get("command", "") or ""
    # 따옴표·heredoc 제거한 버전 (echo/cat 등 오탐 방지용)
    stripped_cmd = strip_quotes(strip_heredocs(raw_cmd))

    # ── 검사 1: Prisma 위험 플래그 ─────────────────────────────────────────
    # raw에서 먼저 확인 (직접 실행), strip에서도 확인 (bash -c "npx prisma ..." 등)
    if PRISMA_DANGER.search(stripped_cmd):
        deny(
            "[db-guardrail] 차단: prisma --accept-data-loss / migrate reset / "
            "--force-reset 는 테이블을 영구 삭제합니다.\n"
            "정말 필요하면 직접 터미널에서 실행하세요. "
            "(Claude는 이 명령을 자동 실행할 수 없습니다.)"
        )

    # ── 검사 1b: 잘못된 레포(caramel-api) prisma db push / migrate ──────────
    if PRISMA_PUSH_MIGRATE.search(stripped_cmd) and WRONG_REPO_PRISMA.search(raw_cmd):
        deny(
            "[db-guardrail] 차단: caramel-api(레거시) 스키마 대상 prisma db push / "
            "migrate 가 감지됐습니다. 이 스키마는 outdated이며, 그걸 기준으로 DB "
            "형상을 바꾸면 테이블이 삭제됩니다 (2026-06-08 사고 원인).\n"
            "DB 스키마 변경의 진짜 SOT는 caramel-zero 입니다:\n"
            "  1) caramel-zero/apps/api/prisma/schema.prisma 수정\n"
            "  2) cd apps/api && pnpm db:migrate (--name <설명>) → migration.sql 생성\n"
            "메모리 reference_prisma_schema_sot_caramel_zero 참조."
        )

    # ── 검사 2: MySQL 실행 컨텍스트 + SQL 파괴 패턴 ─────────────────────────
    if MYSQL_EXEC.search(raw_cmd) and SQL_DESTRUCTIVE.search(raw_cmd):
        deny(
            "[db-guardrail] 차단: mysql 명령 안에서 DROP TABLE / TRUNCATE 가 "
            "감지됐습니다. 되돌릴 수 없는 작업입니다.\n"
            "정말 필요하면 직접 터미널에서 실행하세요."
        )

    # ── 검사 3: SSH + mysql + DROP/TRUNCATE ─────────────────────────────────
    if SSH_MYSQL.search(raw_cmd) and SQL_DESTRUCTIVE.search(raw_cmd):
        deny(
            "[db-guardrail] 차단: SSH 원격 mysql DROP / TRUNCATE 가 감지됐습니다. "
            "직접 터미널에서 실행하세요."
        )

    allow()


if __name__ == "__main__":
    main()
