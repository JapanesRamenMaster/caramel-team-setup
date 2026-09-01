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
    """스킬 본문을 받아 프론트매터가 보강된 전체 SKILL.md 내용을 반환한다."""
    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

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
    return f"{new_frontmatter}\n\n{body.strip()}\n"


def create_pr(
    enriched_content: str,
    skill_name: str,
    submitter: str,
    source: str,
    github_token: str,
    repo_name: str = "the-trive/caramel-team-setup",
) -> str:
    """enriched_content를 skills/{skill_name}/SKILL.md로 PR 생성. PR URL 반환."""
    g = Github(github_token)
    repo = g.get_repo(repo_name)

    branch_name = f"skill-submit/{skill_name}-{submitter}"
    default_branch = repo.default_branch
    base_sha = repo.get_branch(default_branch).commit.sha

    try:
        repo.create_git_ref(f"refs/heads/{branch_name}", base_sha)
    except GithubException as e:
        if e.status == 422:
            branch_name = f"{branch_name}-2"
            repo.create_git_ref(f"refs/heads/{branch_name}", base_sha)
        else:
            raise

    file_path = f"skills/{skill_name}/SKILL.md"

    has_dangerous = any(
        tag in enriched_content
        for tag in ["notification", "db-write", "slack-send", "deploy"]
    )
    warning = (
        "\n⚠️ **`disable-model-invocation: true` 자동 설정됨** (비가역 액션 감지)\n"
        if has_dangerous
        else ""
    )

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
    if len(sys.argv) < 3:
        print("Usage: enrich_skill.py <skill_file> <submitter>")
        sys.exit(1)

    skill_file = sys.argv[1]
    submitter = sys.argv[2]

    with open(skill_file) as f:
        content = f.read()

    skill_name = os.path.basename(os.path.dirname(skill_file)) or os.path.splitext(os.path.basename(skill_file))[0]
    enriched = enrich_skill(content, os.path.basename(skill_file))

    print("=== 보강된 결과 (첫 500자) ===")
    print(enriched[:500])

    if os.environ.get("GITHUB_TOKEN"):
        url = create_pr(
            enriched, skill_name, submitter, "CLI",
            os.environ["GITHUB_TOKEN"]
        )
        print(f"\nPR 생성됨: {url}")
