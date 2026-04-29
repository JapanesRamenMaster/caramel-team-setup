#!/usr/bin/env python3
"""
CBR 1쿼리=1메트릭 원칙 자동 검증.

모든 4개 대시보드 (톱레벨, 마케팅, 제품, 오토랩)의 모든 barchart/timeseries 패널 SQL을
mysql-cols.sh (WHERE 1=0 + fields metadata)로 빠르게 검사하여 결과 컬럼이 정확히 2개인지 확인.
- 1번째: time 컬럼 (Grafana 컨벤션)
- 2번째: metric 컬럼 (오직 1개)

위반 = 컬럼이 2개가 아닌 SQL. exit code 1.
빠름 (LIMIT 0 동치), 정확함 (실제 schema 기반).

Usage:
    python3 grafana-audit/validate_one_metric.py
"""
import json, os, subprocess, sys, urllib.request

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
    print("ERROR: GRAFANA_TOKEN missing. Add to ~/caramel-claude/.env (#claude-setup 채널에서 토큰 확인)", file=sys.stderr)
    sys.exit(2)
HEADERS = {"Authorization": f"Bearer {TOKEN}"}

DASHBOARDS = {
    "topline": "7039d06f-e206-4a06-99bc-b215451176b0",
    "marketing": "7a3999a7-7df7-4cc8-94f1-09a7885d9fc1",
    "product": "488a461e-1d76-4de1-b332-e1ae74337171",
    "autolab": "c0151105-1e38-40b6-a080-b58594bf2c02",
}

EXPECTED_COLS = 2
ALLOW_MARKER = "[multi-series ok]"  # description에 이 마커가 있으면 multi-metric 허용 (의도된 것)


def fetch(uid):
    req = urllib.request.Request(f"{GRAFANA}/api/dashboards/uid/{uid}", headers=HEADERS)
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def get_columns(sql):
    """Returns list of column names or None on error."""
    sql_clean = "\n".join(
        [ln for ln in sql.splitlines() if not ln.lstrip().startswith("--")]
    ).rstrip().rstrip(";").rstrip()
    res = subprocess.run(
        ["/Users/trive/claude/.tools/mysql-cols.sh", sql_clean],
        capture_output=True, text=True, timeout=30,
    )
    if res.returncode != 0:
        return None, res.stderr.strip()[:200]
    try:
        return json.loads(res.stdout.strip()), None
    except Exception as e:
        return None, f"PARSE: {e}"


def main():
    violations = []
    errors = []
    total = 0
    print("Validating 1 query = 1 metric (using mysql-cols.sh)...")
    for name, uid in DASHBOARDS.items():
        d = fetch(uid)
        for p in d["dashboard"]["panels"]:
            if p.get("type") not in ("barchart", "timeseries"):
                continue
            # Allow intentional multi-series via description marker
            if ALLOW_MARKER in (p.get("description") or ""):
                continue
            for t in p.get("targets", []):
                sql = t.get("rawSql", "")
                if not sql.strip():
                    continue
                cols, err = get_columns(sql)
                total += 1
                if cols is None:
                    errors.append((name, p["id"], p["title"], err))
                    continue
                if len(cols) != EXPECTED_COLS:
                    violations.append((name, p["id"], p["title"], cols))

    print(f"\n=== {total} panels checked ===")
    if errors:
        print(f"\n⚠ Errors: {len(errors)}")
        for n, pid, t, e in errors:
            print(f"  {n:10} #{pid:3} {t}")
            print(f"    {e}")
    print(f"\n{'❌' if violations else '✅'} Violations (≠ {EXPECTED_COLS} cols): {len(violations)}")
    for n, pid, t, cols in violations:
        print(f"  {n:10} #{pid:3} {t}")
        print(f"    columns: {cols}")
    sys.exit(1 if violations else 0)


if __name__ == "__main__":
    main()
