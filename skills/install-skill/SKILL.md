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
2. `~/.caramel-team-setup/skills/<name>/SKILL.md` 존재 여부 확인.
3. 있으면: `~/.claude/skills/<name>/SKILL.md`로 복사 (디렉토리 없으면 생성).
4. 완료 메시지 출력.

## 예시 명령어

```bash
# 목록 확인
ls ~/.caramel-team-setup/skills/

# 단일 스킬 설치
mkdir -p ~/.claude/skills/zone-change
cp ~/.caramel-team-setup/skills/zone-change/SKILL.md ~/.claude/skills/zone-change/SKILL.md
echo "✅ zone-change 설치 완료"

# 전체 팀 스킬 동기화 (주의: 로컬 수정 덮어씀)
cp -r ~/.caramel-team-setup/skills/. ~/.claude/skills/
echo "✅ 전체 팀 스킬 동기화 완료"
```
