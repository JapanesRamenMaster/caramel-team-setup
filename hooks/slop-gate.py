#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
slop-gate.py — 한국어 AI 문체 게이트 (Stop 훅)

[목적]
최종 응답 직전에 내 한국어 텍스트를 훑어 고신뢰 slop 마커를 잡는다.
deslop·slop-audit 스킬은 자율 발동이라 흘릴 수 있어서, 마커 수준만 훅으로 강제한다.

[모드]
MODE="log"   — 탐지만 하고 로그에 적는다(기본). 오탐 목록을 모으는 단계.
MODE="block" — 탐지되면 block 반환해 다시 쓰게 만든다.
전환은 이 파일 상단 MODE 한 줄만 바꾼다.

[동작 흐름]
1. stdin JSON 파싱 (실패 시 fail-open)
2. stop_hook_active면 종료 (무한루프 방지)
3. cz-bot-* 슬롯이면 종료 (답할 사람이 없는 자율 세션)
4. transcript 마지막 assistant 텍스트만 추출
5. 코드펜스·백틱 인용·인용줄(>) 제거 후 마커 검색
6. MODE에 따라 로그 또는 block

[가드레일]
- 모든 예외 fail-open. 세션을 절대 깨지 않는다.
- 백틱 안은 검사하지 않는다. 금지 패턴을 인용하는 글이 자기 자신에 걸리면 안 된다.
"""

import sys, json, os, re, traceback
from datetime import datetime

MODE = "block"  # 2026-08-24 전환. 로그 20건 검토 후 오탐 원인(맨 대조 표현)을 제거하고 켰다
LOG = os.path.expanduser("~/.claude/logs/slop-gate.log")

# 고신뢰 마커만. 정상 문장을 잡기 시작하면 여기서 줄인다.
MARKERS = [
    "이를 통해", "라고 할 수 있", "것으로 볼 수 있", "할 수 있을 것입니다",
    "좋은 질문", "정확히 짚", "도움이 되었으면", "언제든 말씀",
    "시사하는 바", "귀추가 주목", "패러다임", "의의가 있",
    "살펴보도록", "알아보도록", "앞으로도 지속", "기대됩니다",
    "놀라운", "혁신적인", "무엇보다도", "본질적으로", "유의미한",
    "앞서 언급", "정리하자면", "아래 표에 정리", "전문가들은",
    "보여지", "되어지", "여겨지", "에 있어서",
]
RANGE_TILDE = re.compile(r"\d\s*~\s*\d")          # 노션에서 취소선이 되는 범위 표기
# 맨 `X가 아니라 Y`는 정상 한국어라 블록 근거가 못 된다(로그 20건 중 12건이 오탐).
# 판정 가능한 것은 한정어가 붙은 형태뿐 — deslop references/structures.md 예외 목록과 같은 선.
CONTRAST = re.compile(r"(?:단순히|단지|그저|비단)[^.\n]{0,40}?아니라")


def last_assistant_text(path):
    """transcript JSONL에서 마지막 assistant 메시지의 text 블록만 이어붙인다."""
    out = ""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            msg = rec.get("message") or {}
            if msg.get("role") != "assistant":
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            buf = [b.get("text", "") for b in content
                   if isinstance(b, dict) and b.get("type") == "text"]
            if buf:
                out = "\n".join(buf)   # 마지막 것만 남긴다
    return out


def strip_quoted(text):
    """검사 대상에서 뺄 것 — 코드펜스, 백틱 인용, 인용줄."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", " ", text)
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith(">"))


def find_hits(body):
    hits = [m for m in MARKERS if m in body]
    if RANGE_TILDE.search(body):
        hits.append("숫자~숫자 범위표기")
    if CONTRAST.search(body):
        hits.append("단순히 X가 아니라 Y")
    if "첫째" in body and "둘째" in body:
        hits.append("첫째/둘째 번호 열거")
    return hits


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)
    if data.get("stop_hook_active", False):
        sys.exit(0)
    cwd = data.get("cwd") or ""
    if os.path.basename(cwd).startswith("cz-bot-") or "/cz-bot-" in cwd:
        sys.exit(0)
    path = data.get("transcript_path", "")
    if not path or not os.path.exists(path):
        sys.exit(0)

    try:
        body = strip_quoted(last_assistant_text(path))
    except Exception as e:
        print(f"[slop-gate] transcript read failed: {e}", file=sys.stderr)
        sys.exit(0)
    if not body.strip():
        sys.exit(0)

    hits = find_hits(body)
    if not hits:
        sys.exit(0)

    if MODE == "log":
        try:
            os.makedirs(os.path.dirname(LOG), exist_ok=True)
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "at": datetime.now().isoformat(timespec="seconds"),
                    "session": data.get("session_id", ""),
                    "hits": hits,
                    "sample": body[:300],
                }, ensure_ascii=False) + "\n")
        except Exception as e:
            print(f"[slop-gate] log write failed: {e}", file=sys.stderr)
        sys.exit(0)

    print(json.dumps({"decision": "block", "reason":
        f"[slop 게이트] 최종 응답에 slop 마커가 남았다: {', '.join(hits)}. "
        "deslop 규칙으로 해당 표현을 고친 뒤 다시 응답하라. "
        "백틱 안 인용이나 Before 예시라서 정상이면 그렇다고 한 줄 남기고 넘어가라."
    }, ensure_ascii=False))
    sys.exit(0)


def check_cli(argv):
    """`slop-gate.py --check [파일]` — 훅 없이 초안을 검사한다. 파일 없으면 stdin."""
    if len(argv) > 1 and argv[1] not in ("-", "--"):
        text = open(argv[1], encoding="utf-8", errors="replace").read()
    else:
        text = sys.stdin.read()
    hits = find_hits(strip_quoted(text))
    if not hits:
        print("clean — 고신뢰 마커 없음. 존재·구조 축은 deslop 스킬로 직접 볼 것")
        return 0
    print("slop 마커 " + str(len(hits)) + "건: " + ", ".join(hits))
    print("deslop 스킬 규칙으로 고칠 것. 인용·Before 예시면 백틱으로 감쌀 것")
    return 1


if __name__ == "__main__":
    try:
        if "--check" in sys.argv[1:2]:
            sys.exit(check_cli(sys.argv[1:]))
        main()
    except Exception:
        traceback.print_exc(file=sys.stderr)
        sys.exit(0)
