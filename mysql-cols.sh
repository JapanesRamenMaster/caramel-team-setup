#!/bin/bash
# CBR 패널 SQL의 컬럼 메타데이터만 빠르게 조회 (WHERE 1=0 + fields).
# /cbr-query 와 validate_one_metric.py 가 사용.
# Read-only — SELECT만 가능.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi
# Try caramel-claude workspace .env too
if [ -f "$HOME/caramel-claude/.env" ]; then
    export $(grep -v '^#' "$HOME/caramel-claude/.env" | xargs)
fi

if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ]; then
    echo "ERROR: .env 파일에 DB 접속 정보가 없습니다." >&2
    exit 1
fi

NODE="$(command -v node 2>/dev/null)"
if [ -z "$NODE" ]; then
    NODE="$(ls -td "$HOME/.nvm/versions/node"/v*/bin/node 2>/dev/null | head -1)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "Error: node not found. Install Node.js or check ~/.nvm" >&2
    exit 1
fi

MYSQL2_PATH=""
for candidate in \
    "$HOME/caramel-claude/.tools/node_modules/mysql2/promise" \
    "$SCRIPT_DIR/.tools/node_modules/mysql2/promise" \
    "/Users/trive/claude/.tools/node_modules/mysql2/promise"; do
    if [ -e "${candidate}.js" ] || [ -d "${candidate}" ]; then
        MYSQL2_PATH="$candidate"
        break
    fi
done
if [ -z "$MYSQL2_PATH" ]; then
    echo "Error: mysql2/promise not installed. Run npm install in ~/caramel-claude/.tools/" >&2
    exit 1
fi

"$NODE" -e "
const mysql = require('${MYSQL2_PATH}');
(async () => {
  const conn = await mysql.createConnection({
    host: process.env.DB_HOST,
    port: parseInt(process.env.DB_PORT || '3306'),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
    connectTimeout: 10000
  });
  const sql = process.argv[1];
  // WHERE 1=0 ensures inner work is skipped by optimizer; fields meta still populated.
  const wrapped = 'SELECT * FROM (' + sql + ') v WHERE 1=0';
  const [rows, fields] = await conn.execute(wrapped);
  console.log(JSON.stringify(fields.map(f => f.name)));
  await conn.end();
})().catch(e => { console.error(e.message); process.exit(1); });
" "$1"
