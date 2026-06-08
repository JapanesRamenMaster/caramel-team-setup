#!/usr/bin/env bash
# 슬랙 메시지 검색 헬퍼
# 사용: ./slack-search.sh "<검색어>"
# 환경변수 SLACK_USER_TOKEN (xoxp-...)가 설정되어 있어야 합니다.
# 결과: JSON (총_건수, 결과 배열)

set -euo pipefail

QUERY="${1:-}"
if [[ -z "$QUERY" ]]; then
    echo '{"error": "검색어가 없습니다. ./slack-search.sh \"<검색어>\" 형태로 사용하세요."}' >&2
    exit 1
fi

python3 - "$QUERY" <<'PYEOF'
import sys
import json
import os

query = sys.argv[1]
token = os.environ.get("SLACK_USER_TOKEN", "")
if not token:
    print(json.dumps({"error": "SLACK_USER_TOKEN 환경변수가 설정되지 않았습니다."}))
    sys.exit(1)

try:
    from slack_sdk import WebClient
    client = WebClient(token=token)
    resp = client.search_messages(
        query=query,
        sort="timestamp",
        sort_dir="desc",
        count=20,
        highlight=False,
    )
    matches = resp.get("messages", {}).get("matches", [])
    results = []
    for m in matches:
        channel = m.get("channel", {})
        # thread_ts와 ts가 다르면 스레드 댓글
        ts = m.get("ts", "")
        thread_ts = m.get("thread_ts", "")
        is_thread_reply = bool(thread_ts) and thread_ts != ts
        results.append({
            "날짜": ts[:10] if ts else "",
            "채널": "#" + channel.get("name", ""),
            "작성자": m.get("username") or m.get("user", ""),
            "내용": (m.get("text") or "")[:300],
            "링크": m.get("permalink", ""),
            "스레드_댓글": is_thread_reply,
            "thread_ts": thread_ts,
        })
    print(json.dumps({"총_건수": len(results), "결과": results}, ensure_ascii=False, indent=2))
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(1)
PYEOF
