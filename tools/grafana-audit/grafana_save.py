#!/usr/bin/env python3
"""
Centralized Grafana dashboard save helper with folder enforcement.

WHY THIS EXISTS:
  `POST /api/dashboards/db` defaults `folderUid` to "" (General) when absent.
  Every ad-hoc script that forgets to pass `folderUid` silently moves the
  dashboard out of `🔥 팀 대시보드 🔥` (eefeyl9nunqiof). This module is the
  single chokepoint for saves so the rule cannot be forgotten.

POLICY:
  - ALL CBR dashboard saves must go through `save(...)` in this file.
  - CBR dashboards are pinned to TEAM_FOLDER_UID — `save` refuses to write
    them if they're already misplaced (would compound the bug).
  - Every save re-fetches and verifies the post-save folder.

CLI:
  python3 grafana_save.py verify   # check all CBR dashboards are in team folder
  python3 grafana_save.py touch <uid>  # no-op save (revision bump) to prove
                                       # round-trip preserves folder
"""
import json
import os
import sys
import urllib.error
import urllib.request

GRAFANA = "https://thetrive.grafana.net"
TOKEN = os.environ.get("GRAFANA_TOKEN", "")  # .env에서 주입 (토큰은 맹주성에게 슬랙 DM 문의)
TEAM_FOLDER_UID = "eefeyl9nunqiof"  # 🔥 팀 대시보드 🔥

CBR_DASHBOARDS = {
    "7039d06f-e206-4a06-99bc-b215451176b0": "CBR 톱레벨",
    "7a3999a7-7df7-4cc8-94f1-09a7885d9fc1": "마케팅 drill-down",
    "488a461e-1d76-4de1-b332-e1ae74337171": "제품 drill-down",
    "c0151105-1e38-40b6-a080-b58594bf2c02": "오토랩 drill-down",
    "ju46j5j": "Legacy (단일 대시보드)",
}

HEADERS_GET = {"Authorization": f"Bearer {TOKEN}"}
HEADERS_POST = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


class FolderPolicyViolation(RuntimeError):
    pass


def fetch(uid):
    req = urllib.request.Request(f"{GRAFANA}/api/dashboards/uid/{uid}", headers=HEADERS_GET)
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def _post(payload):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"{GRAFANA}/api/dashboards/db", data=body, headers=HEADERS_POST, method="POST"
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTPError {e.code}: {e.read().decode('utf-8')}\n")
        raise


def save(dash_obj, message, *, expect_folder=None):
    """
    Save an existing dashboard.

    `dash_obj` is the full GET response (has both 'dashboard' and 'meta').
    folderUid is taken from `meta.folderUid` so it cannot drift.

    For CBR-known UIDs (incl. legacy), refuses to save if currently outside
    TEAM_FOLDER_UID — fail loud rather than rubber-stamp a misplaced board.
    """
    dash = dash_obj["dashboard"]
    meta = dash_obj["meta"]
    current_folder = meta.get("folderUid") or ""
    uid = dash.get("uid")

    if uid in CBR_DASHBOARDS and current_folder != TEAM_FOLDER_UID:
        raise FolderPolicyViolation(
            f"CBR dashboard {uid} ({CBR_DASHBOARDS[uid]}) is in folder "
            f"{current_folder!r}, expected {TEAM_FOLDER_UID!r}. "
            "Move it back to the team folder before saving."
        )
    if expect_folder is not None and current_folder != expect_folder:
        raise FolderPolicyViolation(
            f"Dashboard {uid} is in folder {current_folder!r}, expected {expect_folder!r}"
        )

    payload = {
        "dashboard": dash,
        "folderUid": current_folder,  # REQUIRED — omitting it defaults to General
        "message": message,
        "overwrite": True,
    }
    result = _post(payload)

    after = fetch(uid)
    after_folder = after["meta"].get("folderUid") or ""
    if after_folder != current_folder:
        raise FolderPolicyViolation(
            f"Save round-trip moved dashboard {uid} from {current_folder!r} "
            f"to {after_folder!r}. Investigate immediately."
        )
    return result


def create(dashboard_json, folder_uid, message):
    """Create a new dashboard. folder_uid is REQUIRED."""
    if not folder_uid:
        raise ValueError(
            "folder_uid is required when creating a dashboard. "
            f"For CBR use TEAM_FOLDER_UID = {TEAM_FOLDER_UID!r}."
        )
    payload = {
        "dashboard": dashboard_json,
        "folderUid": folder_uid,
        "message": message,
        "overwrite": False,
    }
    return _post(payload)


def verify_all():
    bad = []
    for uid, name in CBR_DASHBOARDS.items():
        try:
            d = fetch(uid)
            folder = d["meta"].get("folderUid") or "(general)"
            title = d["dashboard"].get("title", "?")
            ok = folder == TEAM_FOLDER_UID
            mark = "OK " if ok else "BAD"
            print(f"{mark}  {uid}  folder={folder}  name={name}  title={title!r}")
            if not ok:
                bad.append(uid)
        except Exception as e:
            print(f"ERR  {uid}  {e}")
            bad.append(uid)
    return bad


def touch(uid):
    """No-op save (folder round-trip proof)."""
    d = fetch(uid)
    before = d["meta"].get("folderUid") or ""
    print(f"before: folderUid={before!r}")
    save(d, message="grafana_save.py: folder round-trip check")
    after = fetch(uid)["meta"].get("folderUid") or ""
    print(f"after : folderUid={after!r}")
    if before != after:
        raise FolderPolicyViolation(f"touch moved folder: {before!r} -> {after!r}")
    print("ok — folder preserved")


def main():
    args = sys.argv[1:]
    if not args or args[0] == "verify":
        bad = verify_all()
        sys.exit(1 if bad else 0)
    elif args[0] == "touch" and len(args) == 2:
        touch(args[1])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
