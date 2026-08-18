---
name: install-skill
description: |
  caramel-team-setup에서 팀 스킬을 로컬 ~/.claude/skills/에 설치.
  Use when: "/install-skill <name>", "스킬 설치", "팀 스킬 가져오기".
scope: team
owner: juseong
side-effects:
  - file-write
disable-model-invocation: false
tags:
  - 스킬
  - 설치
---

# /install-skill — 팀 스킬 로컬 설치

`caramel-team-setup`의 `skills/` 폴더에서 스킬을 로컬 `~/.claude/skills/`에 설치한다.

## 사용법

- `/install-skill zone-change` — zone-change 스킬 설치
- `/install-skill` — 설치 가능한 팀 스킬 목록 표시 후 선택

## 실행 절차

1. 스킬 이름이 주어지면 바로 설치. 없으면 목록 표시.
2. `~/.caramel-team-setup/skills/<name>/` 존재 여부 확인.
3. 있으면: **디렉토리를 통째로** `~/.claude/skills/<name>/`로 복사.
   SKILL.md만 복사하면 옆에 있는 실행 스크립트(`lms-send.js`,
   `grant-wash-voucher.js`, `caramel-admin-api.sh`)가 안 따라와 스킬이 깨진다.
4. 완료 메시지 출력.

## 예시 명령어

```bash
# 목록 확인
ls ~/.caramel-team-setup/skills/

# 단일 스킬 설치 (SKILL 이름만 바꿔서)
NAME=zone-change
if [ -L ~/.claude/skills/$NAME ]; then
  echo "이미 심링크로 설치됨 (팀 셋업 사용 중) — 그대로 두면 자동 최신화됨"
else
  rm -rf ~/.claude/skills/$NAME
  cp -R ~/.caramel-team-setup/skills/$NAME ~/.claude/skills/$NAME
  echo "$NAME 설치 완료"
fi

# 최신화는 레포만 당기면 됨
git -C ~/.caramel-team-setup pull --ff-only
```

## 팀 셋업(setup.sh)을 안 돌린 사람도 이걸로 충분하다

`setup.sh`는 `~/.claude/settings.json`의 `SessionStart` 훅을 **대입으로 덮어쓴다**
(기존 훅이 있으면 사라진다). 자기 클로드 세팅이 있는 개발자는 `setup.sh`를 돌리지 말고
레포만 클론한 뒤 이 스킬로 필요한 스킬만 가져가면 된다.

```bash
git clone https://github.com/JapanesRamenMaster/caramel-team-setup ~/.caramel-team-setup
```

DB 조회가 필요한 스킬은 `~/.caramel-team-setup/mysql-query.sh`를 쓰는데,
같은 디렉토리에 `.env`가 있어야 한다(별도 전달).
