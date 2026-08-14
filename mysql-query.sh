#!/bin/bash
# MySQL 쿼리 헬퍼 (팀원용 - 읽기 전용)
# Usage: ./mysql-query.sh "SELECT * FROM app_user LIMIT 5"

# .env 파일에서 환경변수 로드
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

# 필수 환경변수 확인
if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ]; then
    echo "ERROR: .env 파일에 DB 접속 정보가 없습니다. CPO에게 문의하세요."
    exit 1
fi

# === 가드레일: SELECT/SHOW/DESCRIBE/EXPLAIN만 허용 ===
# 예외: --allow-zone-change 플래그 사용 시 detailer_work_schedule_rule 테이블 UPDATE/INSERT 허용
ALLOW_ZONE_CHANGE=false
QUERY="$1"

if [ "$1" = "--allow-zone-change" ]; then
    ALLOW_ZONE_CHANGE=true
    QUERY="$2"
fi

# 줄바꿈/공백을 정리하여 쿼리 첫 키워드를 정확히 판별
QUERY_UPPER=$(echo "$QUERY" | tr '\n\r' '  ' | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//')
ALLOWED=false

case "$QUERY_UPPER" in
    SELECT*|SHOW*|DESCRIBE*|DESC\ *|EXPLAIN*)
        ALLOWED=true
        ;;
    WITH*)
        # CTE(WITH)는 읽기 전용일 때만 허용. WITH ... DELETE/UPDATE 등 쓰기 CTE(MySQL 8)는 차단.
        # 단어경계(grep -w)로 'updated_at' 같은 컬럼명 오탐 방지.
        if echo "$QUERY_UPPER" | grep -qiwE "(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|GRANT|REPLACE|MERGE|CREATE|RENAME)"; then
            ALLOWED=false
        else
            ALLOWED=true
        fi
        ;;
    UPDATE\ DETAILER_WORK_SCHEDULE_RULE\ SET\ DELETED_AT*|INSERT\ INTO\ DETAILER_WORK_SCHEDULE_RULE*)
        if [ "$ALLOW_ZONE_CHANGE" = true ]; then
            ALLOWED=true
        fi
        ;;
esac

if [ "$ALLOWED" = false ]; then
    echo ""
    echo "⛔ 차단됨: 이 스크립트는 데이터 조회(SELECT)만 가능합니다."
    echo ""
    echo "  DELETE, UPDATE, INSERT, DROP, ALTER 등 데이터를 변경하는 쿼리는 실행할 수 없습니다."
    echo "  데이터 변경이 필요하면 CPO에게 요청하세요."
    echo ""
    echo "  테이블 구조 변경이라면 DDL을 직접 치지 마세요."
    echo "  raw DDL은 _prisma_migrations 에 이력이 안 남아 공유 dev DB가 drift 상태가 되고,"
    echo "  다음 사람이 마이그레이션을 돌릴 때 DB 리셋을 제안받습니다. 정규 경로는 이렇습니다:"
    echo "    1) caramel-zero/apps/api/prisma/schema.prisma 수정"
    echo "    2) cd apps/api && pnpm db:migrate   (Prisma가 폴더+SQL 생성·dev 적용)"
    echo "    3) 생성된 migrations 폴더 커밋"
    echo "    4) prod 는 그 SQL 을 사람이 수동 실행"
    echo ""
    exit 1
fi

# 쿼리 실행 — Python 우선(빠름), 없으면 Node.js 폴백
PYTHON_CANDIDATES=(
    "/opt/caramel-analysis-bot/.venv/bin/python3"   # Droplet 봇 venv (가장 빠름)
    "python3"                                         # 로컬/팀원 환경 시스템 Python
)
PYTHON_BIN=""
for candidate in "${PYTHON_CANDIDATES[@]}"; do
    if command -v "$candidate" &>/dev/null 2>&1 || [ -x "$candidate" ]; then
        if "$candidate" -c "import mysql.connector" 2>/dev/null; then
            PYTHON_BIN="$candidate"
            break
        fi
    fi
done

if [ -n "$PYTHON_BIN" ]; then
    "$PYTHON_BIN" "$SCRIPT_DIR/mysql-query.py" "$QUERY"
else
    # Node.js 폴백 (팀원 로컬 등 mysql.connector 미설치 환경)
    node -e "
const mysql = require('mysql2/promise');
(async () => {
  const conn = await mysql.createConnection({
    host: process.env.DB_HOST, port: process.env.DB_PORT || 3306,
    user: process.env.DB_USER, password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME
  });
  const [rows] = await conn.execute(process.argv[1]);
  console.log(JSON.stringify(rows, null, 2));
  await conn.end();
})().catch(e => { console.error('DB 오류: ' + e.message); process.exit(1); });
" "$QUERY"
fi
