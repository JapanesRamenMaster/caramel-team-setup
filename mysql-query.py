#!/usr/bin/env python3
"""MySQL 읽기 전용 쿼리 실행기 (mysql-query.sh에서 호출)
Node.js/mysql2 대비 프로세스 기동 오버헤드 ~2-3s 제거.
Usage: python3 mysql-query.py "SELECT ..." (환경변수로 DB 접속)
"""
import json
import os
import sys

import mysql.connector

query = sys.argv[1] if len(sys.argv) > 1 else ""
if not query:
    print("ERROR: 쿼리가 없습니다.", file=sys.stderr)
    sys.exit(1)

try:
    conn = mysql.connector.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", 3306)),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        connect_timeout=30,
        charset="utf8mb4",
    )
    cursor = conn.cursor(dictionary=True)
    cursor.execute(query)
    rows = cursor.fetchall()
    cursor.close()
    conn.close()
    # datetime 등 JSON 비직렬화 타입 처리
    print(json.dumps(rows, ensure_ascii=False, default=str, indent=2))
except mysql.connector.Error as e:
    print(f"DB 오류: {e}", file=sys.stderr)
    sys.exit(1)
