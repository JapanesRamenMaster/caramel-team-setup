---
name: slop-gate
description: 한국어 AI 문체 게이트를 내 컴퓨터에 붙이거나, 훅 없이 초안 하나를 검사한다. update.sh를 안 쓰는 사람도 이 레포만 있으면 된다. 트리거 - "slop 게이트 깔아줘", "AI 문체 검사 붙여줘", "이 글 slop 있나 봐줘", "게이트 설치", "훅 등록", 또는 deslop 규칙이 실제로 적용되게 만들고 싶을 때. 규칙 정본은 deslop 스킬, 채점은 slop-audit 스킬.
triggers:
  - slop 게이트 설치
  - AI 문체 훅 등록
  - 초안 slop 검사
scope: team
owner: juseong
side-effects: [settings.json 수정]
---

# slop 게이트

`deslop` 스킬은 규칙이고 이건 그 규칙이 실제로 걸리게 만드는 장치다.
스킬은 부를지 말지가 매번 판단에 달렸다. 훅은 판단을 안 거친다.

## 1. 뭘 잡나

`hooks/slop-gate.py`의 마커만 잡는다 — `이를 통해`·`좋은 질문`·`기대됩니다` 같은 고신뢰 표현,
노션에서 취소선이 되는 `3~5명` 범위 표기, `단순히 X가 아니라 Y` 대조.

**존재 축(이 줄이 필요한가)·이해 축(처음 받은 사람이 읽히나)·구조 축은 훅이 못 본다.** 그건 `deslop`을 직접 읽고 판단할 몫이다.
게이트를 통과했다는 것은 표현 축에 걸릴 것이 없다는 뜻이고, 글이 짧고 필요하다는 뜻이 아니다.

## 2. 두 자리 중 어디에 걸 것인가

| | Stop 훅 (`slop-gate.py`) | 발송 훅 (`slop-gate-outbound.py`) |
|---|---|---|
| 언제 | 답을 다 쓰고 턴을 끝내려는 순간 | 슬랙 전송·노션 쓰기·Artifact 게시 직전 |
| 발동 조건 | 최근 사용자 메시지 3개에 글쓰기 요청 신호가 있을 때만 | 없음. 내보내는 행위 자체가 요청이다 |
| 걸리면 | 턴이 안 끝나고 고친 버전을 이어 쓴다 | 그 도구 호출이 취소된다 |
| 화면 | 원본이 남고 아래에 수정본이 붙는다 | 원본이 남지 않는다 |
| 놓치는 것 | 도구를 타고 나가는 글 전부 | 화면에서 읽고 끝나는 글 전부 |

**둘 다 걸어야 한다.** 겹치지 않고 서로의 사각지대를 덮는다.

Stop 훅은 업무 대화까지 검사하면 방해가 되므로 조건을 뒀다. `슬랙`·`노션`·`공지`·`메일`·`문구`·`초안`·`윤문`
같은 산출물 신호가 최근 대화에 있을 때만 돈다. `문서`·`작성`처럼 코드 작업 대화에 흔한 말은 신호에서 뺐다.
조건을 고치려면 `hooks/slop-gate.py`의 `WRITE_INTENT`를 본다.
글이 회사 밖으로 나가는 자리라면 발송 훅이 낫다 — 나간 글은 회수가 안 되고, 화면에 원본이 남지 않아 어느 쪽을 쓸지 헷갈릴 일도 없다.
터미널에서 읽고 끝나는 보고는 Stop 훅만 닿는다. 수정본이 아래에 붙는 형태이고, **뒤쪽이 채택할 버전이다.**

## 3. 설치

### 팀 셋업을 안 쓰는 사람 (레포 클론도 필요없음)

```bash
curl -fsSL https://raw.githubusercontent.com/the-trive/caramel-team-setup/main/install-slop-gate.sh | bash
```

훅 스크립트 2개와 스킬 3개를 `~/.claude/` 에 내려받고 `settings.json` 에 등록한다.
기존 훅과 설정은 보존하고, 여러 번 돌려도 중복되지 않는다.
팀 셋업으로 심링크된 스킬은 건드리지 않는다. 업데이트는 같은 줄을 다시 돌리면 된다.

### 팀 셋업을 쓰는 사람

`update.sh`가 세션마다 자동으로 붙인다. 수동으로 붙이려면 클로드에게 이렇게 시킨다.

```
~/.caramel-team-setup/hooks/install-dev-hooks.sh 를 내 역할로 실행해서 slop 게이트 훅 등록해줘
```

직접 치려면:

```bash
ROLE=$(grep '^ROLE=' ~/caramel-claude/.setup-config 2>/dev/null | cut -d= -f2- | tr -d '"')
bash ~/.caramel-team-setup/hooks/install-dev-hooks.sh ~/.caramel-team-setup "$ROLE"
```

두 번째 인자는 역할이다. 비워두면 slop 게이트만 붙는다. `dev` 계열이면 코드 가드레일 훅까지 같이 붙고, 아니면 slop 게이트 두 개만 붙는다.
기존 훅을 덮어쓰지 않고, 여러 번 돌려도 중복 등록되지 않는다.

등록 확인:

```bash
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude/settings.json')));print([h['command'] for e in d.get('hooks',{}).values() for g in e for h in g['hooks'] if 'slop' in h['command']])"
```

⚠️ 훅은 세션 시작 때 읽는다. 등록 직후에는 `/hooks`를 한 번 열거나 새 세션에서 돌아간다.

## 4. 훅 없이 초안 하나만 검사

```bash
python3 ~/.caramel-team-setup/hooks/slop-gate.py --check 초안.md
cat 초안.md | python3 ~/.caramel-team-setup/hooks/slop-gate.py --check
```

마커가 있으면 목록과 함께 종료코드 1, 없으면 `clean`과 0을 준다.

## 5. 세다고 느껴지면

`hooks/slop-gate.py` 맨 위 `MODE`를 `"log"`로 바꾼다. 탐지만 하고 통과시키며
`~/.claude/logs/slop-gate.log`에 남긴다. 오탐이 뭔지 그 로그를 들고 오면 마커를 깎는다.
**마커를 각자 지우지 말 것** — 로그 없이 깎으면 왜 뺐는지가 남지 않는다.

## 관련
`deslop`(규칙 정본) · `slop-audit`(초안 채점) · `writing`(문서 골격)
