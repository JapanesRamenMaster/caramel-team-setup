#!/usr/bin/env python3
"""
Apply CBR 6w cutoff to all 4 dashboards:
- Bump 'INTERVAL 5 WEEK' to 'INTERVAL 6 WEEK' (so cutoff still leaves 6 rows)
- Wrap each 6w SQL with outer cutoff '< 이번 주 월요일'
- Skip already-transformed queries (idempotent)

Time column auto-detection: looks for 'AS time' / 'AS week_start_monday' / 'AS wk' / 'AS month_start'
"""
import json
import os
import re
import sys
import urllib.request
import urllib.error

GRAFANA = "https://thetrive.grafana.net"
TOKEN = os.environ.get("GRAFANA_TOKEN")
if not TOKEN:
    env_path = os.path.join(os.path.expanduser("~/caramel-claude"), ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for ln in f:
                if ln.startswith("GRAFANA_TOKEN="):
                    TOKEN = ln.split("=", 1)[1].strip().strip('"').strip("'")
                    break
if not TOKEN:
    print("ERROR: GRAFANA_TOKEN missing. Add to ~/caramel-claude/.env", file=sys.stderr)
    sys.exit(2)
HEADERS_GET = {"Authorization": f"Bearer {TOKEN}"}
HEADERS_POST = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

DASHBOARDS = {
    "topline": "7039d06f-e206-4a06-99bc-b215451176b0",
    "marketing": "7a3999a7-7df7-4cc8-94f1-09a7885d9fc1",
    "product": "488a461e-1d76-4de1-b332-e1ae74337171",
    "autolab": "c0151105-1e38-40b6-a080-b58594bf2c02",
}

CUTOFF_EXPR = (
    "DATE_SUB(\n"
    "    DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR)),\n"
    "    INTERVAL WEEKDAY(DATE(DATE_ADD(UTC_TIMESTAMP(), INTERVAL 9 HOUR))) DAY\n"
    "  )"
)

WRAP_MARKER = "cbr_cutoff_wrap"  # idempotency marker
TIME_COL_CANDIDATES = ["time", "week_start_monday", "week_start", "wk", "month_start", "bucket", "week_bucket"]


def fetch(uid):
    req = urllib.request.Request(f"{GRAFANA}/api/dashboards/uid/{uid}", headers=HEADERS_GET)
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def save(dash_obj, message):
    payload = {
        "dashboard": dash_obj["dashboard"],
        "folderUid": dash_obj["meta"].get("folderUid"),
        "message": message,
        "overwrite": True,
    }
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"{GRAFANA}/api/dashboards/db", data=body, headers=HEADERS_POST, method="POST"
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print("HTTPError:", e.code, e.read().decode("utf-8"))
        raise


def detect_time_column(sql):
    for c in TIME_COL_CANDIDATES:
        if re.search(rf"\bAS\s+`?{c}`?\b", sql, re.IGNORECASE):
            return c
    return None


def transform(sql):
    """Returns transformed SQL or None if cannot transform."""
    if WRAP_MARKER in sql:
        return None  # already transformed
    s = sql.rstrip()
    s = s.rstrip(";").rstrip()
    # Bump 5 WEEK to 6 WEEK so cutoff leaves 6 rows
    s = re.sub(r"\bINTERVAL\s+5\s+WEEK\b", "INTERVAL 6 WEEK", s, flags=re.IGNORECASE)
    time_col = detect_time_column(s)
    if time_col is None:
        return None
    return (
        f"-- CBR cutoff: 이번 주 월요일 미만 (진행중 주 제외)\n"
        f"SELECT * FROM (\n{s}\n) {WRAP_MARKER}\n"
        f"WHERE {WRAP_MARKER}.`{time_col}` < {CUTOFF_EXPR}\n"
        f"ORDER BY {WRAP_MARKER}.`{time_col}`"
    )


def is_6w_panel(panel):
    if panel.get("type") != "barchart":
        return False
    title = panel.get("title", "")
    return "(주간)" in title or title.startswith("(주간)") or "주간" in title


def main(mode="dry"):
    """mode: 'dry' = report only; 'apply' = save dashboards."""
    overall = []
    for name, uid in DASHBOARDS.items():
        d = fetch(uid)
        panels = d["dashboard"]["panels"]
        changed = 0
        skipped = 0
        unparseable = []
        for p in panels:
            if not is_6w_panel(p):
                continue
            for t in p.get("targets", []):
                sql = t.get("rawSql", "")
                if not sql:
                    continue
                new_sql = transform(sql)
                if new_sql is None:
                    if WRAP_MARKER in sql:
                        skipped += 1
                    else:
                        unparseable.append((p["id"], p["title"]))
                    continue
                if mode == "apply":
                    t["rawSql"] = new_sql
                changed += 1
        overall.append((name, uid, changed, skipped, unparseable))

        if mode == "apply" and changed > 0:
            print(f"[{name}] saving {changed} panels...")
            res = save(d, "CBR 6w cutoff: 진행중 주 제외 (이번 주 월요일 미만)")
            print(f"[{name}] saved version={res.get('version')}")

    # Report
    print("\n=== SUMMARY ===")
    for name, uid, changed, skipped, unparseable in overall:
        print(f"{name:10} changed={changed:3}  skipped(already)={skipped:3}  unparseable={len(unparseable)}")
        for pid, title in unparseable:
            print(f"  ! {name}#{pid}: {title}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "dry"
    main(mode)
