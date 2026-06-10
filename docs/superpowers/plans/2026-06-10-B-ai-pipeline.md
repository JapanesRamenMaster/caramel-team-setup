# 스킬 카탈로그 — Plan B: AI 파이프라인

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 팀원이 Slack 또는 GitHub에 스킬을 제출하면 Claude Opus가 자동으로 프론트매터를 보강하고 PR을 생성한다.

**Architecture:** 공용 Python 보강 모듈(`tools/enrich_skill.py`)을 두 채널이 공유. GitHub Action은 `incoming/` 폴더 push를 감지해 실행. 차비스는 `#caramel_스킬공유` 채널 파일 업로드를 감지해 동일 모듈 호출. 둘 다 `caramel-team-setup/skills/` 대상으로 GitHub PR 생성.

**Tech Stack:** Python 3.12, Anthropic SDK (`anthropic`), PyGithub (`PyGithub`), GitHub Actions, Slack Bolt (차비스 기존 코드베이스)

**선행 조건:** Plan A 완료 (프론트매터 표준 정의, `incoming/` 폴더 존재)

---

## 파일 구조

```
caramel-team-setup/
  tools/
    enrich_skill.py          → 신규: 핵심 보강 로직 (Claude API 호출)
    requirements-pipeline.txt → 신규: 파이프라인 의존성
  .github/
    workflows/
      skill-review.yml       → 신규: GitHub Action

~/Desktop/caramel-slack-bot/
  caramel_bot/
    skill_submission.py      → 신규: Slack 파일 업로드 핸들러
  app.py                     → 수정: 새 이벤트 핸들러 등록
  requirements.txt           → 수정: PyGithub 추가
```

---

### Task 1: 보강 모듈 작성 (enrich_skill.py)

**Files:**
- Create: `tools/enrich_skill.py`
- Create: `tools/requirements-pipeline.txt`

- [ ] **Step 1: 의존성 파일 작성**

`tools/requirements-pipeline.txt`:
```
anthropic>=0.52.0
PyGithub>=2.3.0
python-frontmatter>=1.1.0
```

- [ ] **Step 2: 보강 모듈 작성**

`tools/enrich_skill.py`:
```python
#!/usr/bin/env python3
"""
스킬 보강 파이프라인 — Claude Opus가 프론트매터를 자동 생성한다.
GitHub Action과 차비스 Slack 핸들러 양쪽에서 호출.
"""
import os
import re
import sys
import textwrap
import anthropic
import frontmatter
from github import Github, GithubException

CARAMEL_CONTEXT = """
카라멜은 자동차 세차·정비 구독 서비스다.
주요 시스템: 예약(reservation), 구독(subscription), 디테일러(detailer), 알림톡(kakao notification).
DB: MySQL(caramel-prod). 언어: TypeScript(NestJS), React Native, Next.js.
레포: caramel-zero(모노레포 메인), caramel-team-setup(팀 설정·스킬).
팀원: 맹주성(juseong), 성지원(sungjiwon), 강희준(heejun), 이현복(hyunbok).
비가역 액션: 알림톡 발송, DB 쓰기, 슬랙 전송, 배포.
"""

SIDE_EFFECT_VALUES = [
    "db-write", "db-read", "notification", "slack-send",
    "file-write", "deploy", "api-call", "api-call-write"
]

SYSTEM_PROMPT = f"""
너는 카라멜 팀의 Claude Code 스킬 파일을 분석해 거버넌스 프론트매터를 생성하는 전문가다.

{CARAMEL_CONTEXT}

## 네가 해야 할 일

스킬 본문을 읽고 YAML 프론트매터를 생성한다. 반드시 아래 규칙을 따른다:

1. side-effects: 허용값만 사용 — {SIDE_EFFECT_VALUES}
2. side-effects에 db-write, notification, slack-send, deploy가 있으면 disable-model-invocation: true 필수
3. 부작용이 없으면 side-effects: [] (누락이 아님을 명시)
4. owner: 스킬 내용과 카라멜 팀 맥락으로 추론. 모르면 "juseong"
5. tags: 한국어로 2-4개. 예: ["예약", "고객관리"]
6. requires: 환경변수명·도구명만. 없으면 생략

## 출력 형식

프론트매터만 출력한다. --- 구분선 포함. 본문은 포함하지 않는다.

예시 출력:
---
name: clean-multi-reservations
description: |
  동일차량 다중예약 정리. 슬랙 알림 확인 → 취소 대상 분석 → 사용자 승인 후 취소 실행.
  Use when: "다중 예약 정리", "중복 예약 정리", "clean multi".
scope: team
owner: sungjiwon
side-effects:
  - db-write
  - notification
disable-model-invocation: true
tags:
  - 예약
  - 고객관리
---
"""


def enrich_skill(skill_content: str, filename: str) -> str:
    """
    스킬 본문을 받아 프론트매터가 보강된 전체 SKILL.md 내용을 반환한다.
    """
    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

    # 기존 프론트매터 분리
    post = frontmatter.loads(skill_content)
    body = post.content
    existing_meta = dict(post.metadata)

    user_message = f"""파일명: {filename}

스킬 본문:
{body}

기존 프론트매터 (있으면 참고, 없어도 됨):
{existing_meta if existing_meta else "없음"}

위 스킬의 프론트매터를 생성해줘."""

    message = client.messages.create(
        model="claude-opus-4-8",
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_message}],
    )

    new_frontmatter = message.content[0].text.strip()

    # 프론트매터 + 원본 본문 합치기
    return f"{new_frontmatter}\n\n{body.strip()}\n"


def create_pr(
    enriched_content: str,
    skill_name: str,
    submitter: str,
    source: str,  # "slack" 또는 "github"
    github_token: str,
    repo_name: str = "JapanesRamenMaster/caramel-team-setup",
) -> str:
    """
    enriched_content를 skills/{skill_name}/SKILL.md로 PR 생성.
    생성된 PR URL 반환.
    """
    g = Github(github_token)
    repo = g.get_repo(repo_name)

    branch_name = f"skill-submit/{skill_name}-{submitter}"
    default_branch = repo.default_branch
    base_sha = repo.get_branch(default_branch).commit.sha

    # 브랜치 생성
    try:
        repo.create_git_ref(f"refs/heads/{branch_name}", base_sha)
    except GithubException as e:
        if e.status == 422:  # 이미 존재
            branch_name = f"{branch_name}-2"
            repo.create_git_ref(f"refs/heads/{branch_name}", base_sha)
        else:
            raise

    file_path = f"skills/{skill_name}/SKILL.md"

    # side-effects 감지해서 PR 본문에 경고 추가
    has_dangerous = any(
        tag in enriched_content
        for tag in ["notification", "db-write", "slack-send", "deploy"]
    )
    warning = (
        "\n⚠️ **`disable-model-invocation: true` 자동 설정됨** (비가역 액션 감지)\n"
        if has_dangerous
        else ""
    )

    # 파일 생성 or 업데이트
    try:
        existing = repo.get_contents(file_path, ref=default_branch)
        repo.update_file(
            file_path,
            f"feat: {skill_name} 스킬 보강 (by {submitter})",
            enriched_content,
            existing.sha,
            branch=branch_name,
        )
    except GithubException:
        repo.create_file(
            file_path,
            f"feat: {skill_name} 스킬 추가 (by {submitter})",
            enriched_content,
            branch=branch_name,
        )

    pr = repo.create_pull(
        title=f"[스킬 제출] {skill_name} — by @{submitter}",
        body=textwrap.dedent(f"""
            ## 스킬 자동 제출

            - **제출 경로**: {source}
            - **제출자**: @{submitter}
            {warning}
            ---
            Claude Opus가 프론트매터를 자동 생성했습니다.
            검토 후 승인해주세요.

            🤖 Generated with Claude Code
        """).strip(),
        head=branch_name,
        base=default_branch,
    )

    return pr.html_url


if __name__ == "__main__":
    # 직접 실행: python enrich_skill.py <skill_file> <submitter>
    if len(sys.argv) < 3:
        print("Usage: enrich_skill.py <skill_file> <submitter>")
        sys.exit(1)

    skill_file = sys.argv[1]
    submitter = sys.argv[2]

    with open(skill_file) as f:
        content = f.read()

    skill_name = os.path.basename(os.path.dirname(skill_file)) or os.path.splitext(os.path.basename(skill_file))[0]
    enriched = enrich_skill(content, os.path.basename(skill_file))

    print("=== 보강된 프론트매터 ===")
    print(enriched[:500])

    if os.environ.get("GITHUB_TOKEN"):
        url = create_pr(
            enriched, skill_name, submitter, "CLI",
            os.environ["GITHUB_TOKEN"]
        )
        print(f"\nPR 생성됨: {url}")
```

- [ ] **Step 3: 로컬 테스트 (dry-run — PR 없이 보강만)**

```bash
cd ~/.caramel-team-setup
pip install anthropic python-frontmatter PyGithub

# 테스트용 스킬 파일 (incoming/ 에 있다고 가정)
cat > /tmp/test-skill.md << 'EOF'
# /test-skill

테스트 스킬이다. DB에서 예약을 조회하고 카카오 알림톡을 발송한다.

## 사용법
/test-skill
EOF

ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY python tools/enrich_skill.py /tmp/test-skill.md testuser
```

예상 출력:
```
=== 보강된 프론트매터 ===
---
name: test-skill
...
side-effects:
  - db-read
  - notification
disable-model-invocation: true
...
---
```

- [ ] **Step 4: 커밋**

```bash
cd ~/.caramel-team-setup
git add tools/enrich_skill.py tools/requirements-pipeline.txt
git commit -m "feat: 스킬 보강 파이프라인 모듈 추가 (enrich_skill.py)"
```

---

### Task 2: GitHub Action 작성

**Files:**
- Create: `.github/workflows/skill-review.yml`

- [ ] **Step 1: GitHub Action 작성**

```yaml
name: Skill Auto-Review

on:
  push:
    branches: [main]
    paths:
      - 'incoming/**'

jobs:
  enrich:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Python 셋업
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: 의존성 설치
        run: pip install -r tools/requirements-pipeline.txt

      - name: 변경된 incoming/ 파일 찾기
        id: files
        run: |
          FILES=$(git diff --name-only HEAD~1 HEAD -- 'incoming/*.md' | tr '\n' ' ')
          echo "files=$FILES" >> $GITHUB_OUTPUT

      - name: 스킬 보강 + PR 생성
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          for FILE in ${{ steps.files.outputs.files }}; do
            if [ -f "$FILE" ]; then
              SKILL_NAME=$(basename "$FILE" .md)
              echo "처리 중: $FILE → skills/$SKILL_NAME/SKILL.md"
              python tools/enrich_skill.py "$FILE" "github-action"
            fi
          done
```

- [ ] **Step 2: GitHub Secrets 설정 확인**

```bash
# caramel-team-setup 레포에 ANTHROPIC_API_KEY Secret 필요
gh secret set ANTHROPIC_API_KEY --repo JapanesRamenMaster/caramel-team-setup
# 프롬프트에서 키 입력 (팀 공용 키 또는 전용 키)
```

- [ ] **Step 3: 커밋**

```bash
cd ~/.caramel-team-setup
git add .github/workflows/skill-review.yml
git commit -m "feat: incoming/ 스킬 자동 리뷰 GitHub Action 추가"
```

---

### Task 3: GitHub Action 통합 테스트

**Files:**
- Modify: `incoming/` (테스트용 파일 추가 후 삭제)

- [ ] **Step 1: 테스트 스킬 파일 incoming/에 push**

```bash
cd ~/.caramel-team-setup

cat > incoming/test-reservation-clean.md << 'EOF'
# /test-reservation-clean

특정 조건의 예약을 일괄 취소하고 고객에게 카카오 알림톡을 발송한다.

## 사용 조건
취소 대상 예약 ID 목록을 받아 처리.

## 주의
- 취소 후 알림톡이 자동 발송됨
- DB에서 삭제되므로 되돌릴 수 없음
EOF

git add incoming/test-reservation-clean.md
git commit -m "test: 스킬 자동 리뷰 Action 테스트"
git push origin docs/skill-catalog-spec
```

- [ ] **Step 2: GitHub Action 실행 확인**

```bash
gh run list --repo JapanesRamenMaster/caramel-team-setup --limit 3
# 가장 최근 run ID 확인 후:
gh run watch <run-id> --repo JapanesRamenMaster/caramel-team-setup
```

예상: Action 성공 + `[스킬 제출] test-reservation-clean` PR 생성

- [ ] **Step 3: PR 확인**

```bash
gh pr list --repo JapanesRamenMaster/caramel-team-setup
```

PR 본문에 `disable-model-invocation: true 자동 설정됨` 경고 있어야 함.

- [ ] **Step 4: 테스트 파일 정리**

```bash
cd ~/.caramel-team-setup
rm incoming/test-reservation-clean.md
git add incoming/test-reservation-clean.md
git commit -m "test: 테스트 스킬 파일 제거"
git push origin docs/skill-catalog-spec

# 테스트 PR 닫기
gh pr close <pr-number> --repo JapanesRamenMaster/caramel-team-setup
```

---

### Task 4: 차비스 Slack 파일 업로드 핸들러 작성

**Files:**
- Create: `~/Desktop/caramel-slack-bot/caramel_bot/skill_submission.py`

> 차비스 아키텍처: Slack Bolt + Python 3.12. 배포 경로: `git push origin HEAD:deploy` → SSH restart.

- [ ] **Step 1: skill_submission.py 작성**

```python
"""
#caramel_스킬공유 채널 파일 업로드 → 스킬 보강 파이프라인 트리거
"""
import os
import sys
import logging
import tempfile
import requests
import subprocess

logger = logging.getLogger(__name__)

SKILL_SHARE_CHANNEL = os.environ.get("SKILL_SHARE_CHANNEL", "")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

# 차비스 워크스페이스 내 enrich_skill.py 경로
WORKSPACE_DIR = os.environ.get("WORKSPACE_DIR", "/opt/caramel-bot-workspace")
ENRICH_SCRIPT = os.path.join(WORKSPACE_DIR, "tools", "enrich_skill.py")


def is_skill_submission(event: dict) -> bool:
    """#caramel_스킬공유 채널의 .md 파일 업로드인지 확인"""
    if not SKILL_SHARE_CHANNEL:
        return False
    if event.get("channel") != SKILL_SHARE_CHANNEL:
        return False
    files = event.get("files", [])
    return any(f.get("name", "").endswith(".md") for f in files)


def handle_skill_submission(event: dict, client, say) -> None:
    """
    파일을 다운로드하고 보강 파이프라인을 실행한 뒤
    PR URL을 채널에 알린다.
    """
    files = [f for f in event.get("files", []) if f.get("name", "").endswith(".md")]
    if not files:
        return

    submitter_id = event.get("user", "unknown")
    # Slack user ID → username 변환
    try:
        user_info = client.users_info(user=submitter_id)
        submitter = user_info["user"]["name"]
    except Exception:
        submitter = submitter_id

    say(f"📥 스킬 제출 받았습니다! Claude Opus가 분석 중이에요... (제출자: @{submitter})")

    for file_info in files:
        skill_name = os.path.splitext(file_info["name"])[0]
        download_url = file_info.get("url_private_download") or file_info.get("url_private")

        # Slack 파일 다운로드
        headers = {"Authorization": f"Bearer {client.token}"}
        resp = requests.get(download_url, headers=headers)
        if resp.status_code != 200:
            say(f"❌ 파일 다운로드 실패: {file_info['name']}")
            continue

        with tempfile.NamedTemporaryFile(
            suffix=".md", delete=False, mode="wb"
        ) as tmp:
            tmp.write(resp.content)
            tmp_path = tmp.name

        try:
            # enrich_skill.py 실행 (PR 생성 포함)
            result = subprocess.run(
                [
                    sys.executable, ENRICH_SCRIPT,
                    tmp_path, submitter
                ],
                capture_output=True, text=True,
                env={**os.environ, "GITHUB_TOKEN": GITHUB_TOKEN},
                timeout=120,
            )

            if result.returncode != 0:
                logger.error("enrich_skill.py 실패: %s", result.stderr)
                say(f"❌ 보강 실패 (`{skill_name}`): {result.stderr[:200]}")
                continue

            # PR URL 파싱
            pr_url = None
            for line in result.stdout.splitlines():
                if line.startswith("PR 생성됨:"):
                    pr_url = line.split(": ", 1)[1].strip()

            if pr_url:
                say(
                    f"✅ *{skill_name}* 스킬 PR 생성됐어요!\n"
                    f"프론트매터 자동 보강 완료 → 맹주성님 승인 대기 중\n"
                    f"👉 {pr_url}"
                )
            else:
                say(f"✅ *{skill_name}* 처리 완료 (PR URL 파싱 실패)")

        except subprocess.TimeoutExpired:
            say(f"⏱️ 처리 시간 초과 (`{skill_name}`). 나중에 다시 시도해주세요.")
        finally:
            os.unlink(tmp_path)
```

- [ ] **Step 2: app.py에 이벤트 핸들러 등록**

`~/Desktop/caramel-slack-bot/app.py`에서 기존 이벤트 핸들러 등록 부분을 찾아 추가:

```python
from caramel_bot.skill_submission import is_skill_submission, handle_skill_submission

# 기존 message 이벤트 핸들러 안에, 또는 별도 핸들러로:
@app.event("message")
def handle_message_events(event, client, say, logger):
    # ... 기존 로직 ...
    
    # 스킬 제출 감지 (기존 로직 앞에 추가)
    if is_skill_submission(event):
        handle_skill_submission(event, client, say)
        return  # 스킬 제출이면 다른 처리 스킵
    
    # ... 이후 기존 로직 ...
```

> **주의**: 기존 app.py의 message 이벤트 핸들러 구조를 먼저 Read해서 정확한 위치 확인 후 삽입.

- [ ] **Step 3: requirements.txt에 PyGithub 추가**

```bash
cd ~/Desktop/caramel-slack-bot
echo "PyGithub>=2.3.0" >> requirements.txt
source .venv/bin/activate && pip install PyGithub
```

- [ ] **Step 4: 커밋**

```bash
cd ~/Desktop/caramel-slack-bot
git add caramel_bot/skill_submission.py app.py requirements.txt
git commit -m "feat: #caramel_스킬공유 채널 스킬 제출 핸들러 추가"
```

---

### Task 5: 차비스 환경변수 및 배포

- [ ] **Step 1: .env에 환경변수 추가**

로컬 `.env` 수정:
```bash
# ~/.caramel-team-setup/.env 또는 caramel-slack-bot/.env 참고
SKILL_SHARE_CHANNEL=<#caramel_스킬공유 채널 ID>
GITHUB_TOKEN=<GitHub PAT (caramel-team-setup write 권한)>
```

채널 ID 확인:
```bash
# Slack 채널 URL에서 확인: https://app.slack.com/client/T.../C???
# 또는:
curl -s "https://slack.com/api/conversations.list" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  | python3 -c "import sys,json; [print(c['id'],c['name']) for c in json.load(sys.stdin)['channels'] if '스킬' in c.get('name','')]"
```

- [ ] **Step 2: Droplet .env 업데이트**

```python
# paramiko SSH로 Droplet .env에 추가
import paramiko
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
# 4~5회 재시도 루프 (차비스 메모리 참고)
ssh.connect("139.59.121.39", username="root", password="VmSpjhn2tNHHBY")
stdin, stdout, stderr = ssh.exec_command(
    "echo 'SKILL_SHARE_CHANNEL=C채널ID' >> /opt/caramel-analysis-bot/.env && "
    "echo 'GITHUB_TOKEN=ghp_토큰' >> /opt/caramel-analysis-bot/.env"
)
```

- [ ] **Step 3: 배포**

```bash
cd ~/Desktop/caramel-slack-bot
git push origin HEAD:deploy
```

SSH로 재시작:
```bash
# paramiko로:
ssh.exec_command(
    "cd /opt/caramel-analysis-bot && git pull --ff-only && "
    "source .venv/bin/activate && pip install -r requirements.txt && "
    "systemctl restart caramel-analysis-bot"
)
```

- [ ] **Step 4: 배포 확인**

```bash
# 서비스 상태
ssh.exec_command("systemctl status caramel-analysis-bot | head -10")
# 예상: active (running)

# 로그 확인
ssh.exec_command("tail -20 /opt/caramel-analysis-bot/logs/bot.out")
```

---

### Task 6: 차비스 Slack 통합 테스트

- [ ] **Step 1: #caramel_스킬공유 채널에 봇 초대**

Slack에서: `/invite @brother_1` (채널에서 직접)

- [ ] **Step 2: 테스트 md 파일 업로드**

Slack `#caramel_스킬공유`에 아래 내용의 `test-skill-submission.md` 첨부:

```markdown
# /test-skill-submission

테스트용 스킬. 예약 목록을 조회한다.

## 사용법
/test-skill-submission [날짜]
```

- [ ] **Step 3: 결과 확인**

예상 응답 (30초 내):
```
📥 스킬 제출 받았습니다! Claude Opus가 분석 중이에요... (제출자: @{your-name})
✅ test-skill-submission 스킬 PR 생성됐어요!
프론트매터 자동 보강 완료 → 맹주성님 승인 대기 중
👉 https://github.com/JapanesRamenMaster/caramel-team-setup/pull/...
```

- [ ] **Step 4: PR 내용 검증**

```bash
gh pr view --repo JapanesRamenMaster/caramel-team-setup --web
```

프론트매터 확인:
- `scope: team` 있음
- `side-effects` 있음 (db-read 예상)
- `owner` 있음

- [ ] **Step 5: 테스트 PR 닫기**

```bash
gh pr close <pr-number> --repo JapanesRamenMaster/caramel-team-setup
```

---

### Task 7: Plan A 브랜치와 합쳐서 PR 생성

- [ ] **Step 1: 전체 커밋 확인**

```bash
cd ~/.caramel-team-setup
git log --oneline origin/main..HEAD
```

- [ ] **Step 2: PR 생성**

```bash
gh pr create \
  --title "feat: 스킬 카탈로그 AI 파이프라인 — GitHub Action + 차비스 연동" \
  --body "$(cat <<'EOF'
## 변경 내용

- `tools/enrich_skill.py`: Claude Opus 기반 스킬 보강 모듈
- `.github/workflows/skill-review.yml`: incoming/ 자동 처리 Action
- 차비스 `#caramel_스킬공유` 채널 파일 업로드 핸들러

## 테스트

- GitHub Action: test-reservation-clean.md 제출 → PR 자동 생성 확인
- 차비스: Slack 파일 업로드 → PR 생성 확인 (disable-model-invocation 경고 포함)

🤖 Generated with Claude Code
EOF
)"
```
