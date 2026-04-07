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
# 줄바꿈/공백을 정리하여 쿼리 첫 키워드를 정확히 판별
QUERY_UPPER=$(echo "$1" | tr '\n\r' '  ' | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//')
ALLOWED=false

case "$QUERY_UPPER" in
    SELECT*|SHOW*|DESCRIBE*|DESC\ *|EXPLAIN*)
        ALLOWED=true
        ;;
esac

if [ "$ALLOWED" = false ]; then
    echo ""
    echo "⛔ 차단됨: 이 스크립트는 데이터 조회(SELECT)만 가능합니다."
    echo ""
    echo "  DELETE, UPDATE, INSERT, DROP, ALTER 등 데이터를 변경하는 쿼리는 실행할 수 없습니다."
    echo "  데이터 변경이 필요하면 CPO에게 요청하세요."
    echo ""
    exit 1
fi

# 쿼리 실행
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
" "$1"
