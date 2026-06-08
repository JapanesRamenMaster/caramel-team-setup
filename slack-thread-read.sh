#!/usr/bin/env bash
# 슬랙 스레드 메시지 읽기 헬퍼
# 사용:
#   ./slack-thread-read.sh <channel_id> <thread_ts>
#   ./slack-thread-read.sh https://trydrive.slack.com/archives/CXXX/pYYYY
# 결과: 스레드 메시지 목록 (텍스트)

set -euo pipefail

INPUT="${1:-}"
INPUT2="${2:-}"

python3 - "$INPUT" "$INPUT2" <<'PYEOF'
import sys, json, os, re

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
env_path = os.path.join(SCRIPT_DIR, ".env")
if os.path.exists(env_path):
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

try:
    from slack_sdk import WebClient
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "slack_sdk", "-q"])
    from slack_sdk import WebClient

token = os.environ.get("SLACK_BOT_TOKEN") or os.environ.get("SLACK_USER_TOKEN")
if not token:
    print(json.dumps({"error": "SLACK_BOT_TOKEN 또는 SLACK_USER_TOKEN 환경변수가 필요합니다."}))
    sys.exit(1)

arg1 = sys.argv[1] if len(sys.argv) > 1 else ""
arg2 = sys.argv[2] if len(sys.argv) > 2 else ""

channel_id = ""
thread_ts = ""

# URL 파싱 (https://trydrive.slack.com/archives/CXXX/pYYYY?thread_ts=ZZZ)
url_match = re.search(r'/archives/([A-Z0-9]+)/p(\d+)', arg1)
if url_match:
    channel_id = url_match.group(1)
    raw_ts = url_match.group(2)
    thread_ts = raw_ts[:-6] + "." + raw_ts[-6:]
elif arg1 and arg2:
    channel_id = arg1
    thread_ts = arg2
else:
    print(json.dumps({"error": "사용법: slack-thread-read.sh <channel_id> <thread_ts>  또는  <slack_url>"}))
    sys.exit(1)

client = WebClient(token=token)
try:
    result = client.conversations_replies(channel=channel_id, ts=thread_ts, limit=50)
    msgs = result.get("messages", [])
    lines = []
    for m in msgs:
        user = m.get("user") or m.get("bot_id") or "?"
        text = m.get("text", "").strip()
        ts_float = float(m.get("ts", 0))
        import datetime
        dt = datetime.datetime.fromtimestamp(ts_float, tz=datetime.timezone(datetime.timedelta(hours=9)))
        time_str = dt.strftime("%H:%M")
        if text:
            lines.append(f"[{time_str} {user}] {text}")
    output = "\n".join(lines)
    print(output if output else "(메시지 없음)")
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(1)
PYEOF
