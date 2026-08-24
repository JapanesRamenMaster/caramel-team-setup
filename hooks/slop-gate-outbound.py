#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
slop-gate-outbound.py — 발송·게시 직전 한국어 slop 마커 검사 (PreToolUse 훅)

Stop 훅(slop-gate)은 최종 응답만 본다. 슬랙 전송·노션 쓰기·Artifact 게시처럼
도구를 타고 나가는 글은 거기에 안 잡히고, 나간 뒤에는 회수가 안 된다.
그래서 나가기 전에 막는다 — deny면 화면에 원본이 남지 않는다.
마커 목록·판정은 slop-gate.py를 그대로 import해서 쓴다(정본 하나).

가드레일: 모든 예외 fail-open. 게시를 절대 못 막는 쪽으로 죽는다.
"""
import sys, json, os, re, importlib.util, traceback

# 같은 디렉터리의 slop-gate.py를 정본으로 쓴다 — 로컬(~/.claude/scripts)과
# 팀 레포(hooks/) 양쪽에서 경로 패치 없이 그대로 돈다.
GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "slop-gate.py")


def load_gate():
    spec = importlib.util.spec_from_file_location("slop_gate", GATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def visible_text(raw):
    """HTML에서 사람이 읽는 텍스트만. style·script·주석·태그·엔티티 제거."""
    t = re.sub(r"<(script|style)\b.*?</\1>", " ", raw, flags=re.S | re.I)
    t = re.sub(r"<!--.*?-->", " ", t, flags=re.S)
    t = re.sub(r"<[^>]+>", " ", t)
    return re.sub(r"&[a-z]+;|&#\d+;", " ", t)


SKIP_KEYS = ("url", "id", "path", "href", "channel", "ts", "token", "type")
HANGUL = re.compile(r"[가-힣]")


def payload_text(obj, out):
    """tool_input에서 사람이 읽는 한국어 문자열만 모은다. 식별자·URL은 뺀다."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if any(s in str(k).lower() for s in SKIP_KEYS):
                continue
            payload_text(v, out)
    elif isinstance(obj, list):
        for v in obj:
            payload_text(v, out)
    elif isinstance(obj, str) and len(obj) >= 20 and HANGUL.search(obj):
        out.append(obj)
    return out


def main():
    data = json.loads(sys.stdin.read())
    ti = data.get("tool_input") or {}
    path = ti.get("file_path") or ""
    raw = ""
    if path and os.path.exists(path):
        if os.path.splitext(path)[1].lower() not in (".html", ".htm", ".md"):
            sys.exit(0)
        raw = open(path, encoding="utf-8", errors="replace").read()
        label = os.path.basename(path)
    else:
        raw = "\n".join(payload_text(ti, []))
        label = data.get("tool_name") or "발송 내용"
    if not raw.strip():
        sys.exit(0)

    gate = load_gate()
    body = gate.strip_quoted(visible_text(raw))
    hits = gate.find_hits(body)
    if not hits:
        sys.exit(0)

    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason":
            f"[발송 slop 게이트] {label}에 slop 마커가 남았다: {', '.join(hits)}. "
            "deslop 스킬 규칙(존재→이해→구조→표현)으로 그 부분을 고쳐 다시 보내라. "
            "Before 예시로 일부러 인용한 것이면 백틱으로 감싸거나 그렇다고 한 줄 남기고 넘어가라.",
    }}, ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(0)
