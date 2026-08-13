---
name: caramel-deploy
description: Use when creating a PR, pushing to a caramel repo branch, or deploying any caramel service. Covers repo-specific deploy flows, common conflict pitfalls, and verification steps.
---

# caramel-deploy

카라멜 레포 배포 체크리스트. PR 생성 전 반드시 실행.

**스킬 시작 시 아래 명령 실행 (게이트 해제):**
```bash
touch /tmp/caramel-deploy-ran
```

## 공통 흐름

```
feature 브랜치
  → develop PR → 머지
  → develop CI 완료 확인 (gh run list --branch develop --limit 1)
  → develop→main PR → 머지
  → main CI 완료 확인
```

## 공통 주의사항

**⚠️ 브랜치 전환은 commit과 같은 Bash 호출에 chain하지 말 것 (가드레일 함정)**
`git-guardrail.py` PreToolUse 훅은 명령에 `git commit`이 있으면 **실행 전에** 현재 HEAD를 읽어 보호 브랜치(main/master/develop)면 deny한다. `git checkout -b X && git add && git commit`을 **한 호출로 보내면** checkout이 아직 실행 안 돼 HEAD=보호브랜치로 읽혀 **무조건 차단**됨(= "체크아웃이 안 먹는 것처럼" 보이는 현상. 미스터리 아님). 올바른 순서:
```bash
git checkout -b feat/x origin/<base>            # ① 단독 호출 (fetch는 훅이 자동 주입)
cd <repo> && git add <경로> && git commit -m "…"  # ② 별도 호출 — HEAD가 feat/x라 통과
```
push·PR(`gh pr create`)·머지(`gh pr merge --squash --delete-branch`)는 ② 이후 자유. 상세: 메모리 `feedback_git_safety_guardrail`.

**merge conflict 해결 시**
- conflict 해결 후 반드시 DTO-service 타입 일관성 확인
- DTO에 없는 필드를 service에서 참조하면 빌드 실패 (tsc 에러, 런타임이 아님)

**develop→main 충돌 패턴**
- main에 hotfix가 같은 파일을 수정했으면 계속 충돌 발생
- 해결: 충돌 파일 없는 커밋만 별도 브랜치로 만들어 직접 수정 후 PR

**CI 실패 확인**
```bash
gh run view <run-id> --log-failed | grep -E "error TS|exit code|ERROR"
```

---

## 레포별 특이사항

### ⚠️ DB 스키마 변경의 SOT = caramel-zero (caramel-api 아님)

DB 형상(테이블·컬럼)의 진짜 단일 진실원천은 **caramel-zero** 다. caramel-api의 `libs/caramel-prisma/prisma/schema.prisma`는 **outdated**이며, 그걸 기준으로 db push/ALTER 하면 테이블이 삭제된다 (2026-06-08 dev DB 테이블 4개 삭제 사고). db-guardrail.py가 caramel-api 대상 prisma db push/migrate를 하드블록한다.

**올바른 스키마 변경 절차 (이것만 사용):**
1. `caramel-zero/apps/api/prisma/schema.prisma` 수정
2. `cd apps/api && pnpm db:migrate` (= `prisma migrate dev`) — CLI가 migration 이름 물어봄(또는 `--name <설명>`으로 비대화식)
3. `apps/api/prisma/migrations/`에 `migration.sql` 자동 생성
4. git diff에 **2개 파일**(schema.prisma + migration.sql) 잡히면 정상. prod 반영은 `db:migrate:deploy`
- 금지: `prisma db push`, 수기 `ALTER TABLE`로 스키마 변경, caramel-api 스키마 대상 prisma 작업.
- 상세: 메모리 `reference_prisma_schema_sot_caramel_zero`.

### caramel-api (`~/Desktop/Github/caramel-api`) — 레거시, 코드/배포만
- **base**: develop / **prod**: main (K8s 자동배포)
- DB 스키마 변경은 여기서 하지 말 것 (위 caramel-zero 절차 사용). 코드(서비스/리졸버) 변경·배포만.
- sales-admin UI가 dev API 연결 → API 배포 먼저, UI 배포 나중
- **⚠️ CI 이중 필터 함정 (2026-07-13 확인)**: `ci-apps.yml`은 ①트리거 자체가 `paths: apps/**, libs/**, dockerfiles/**` ②잡 내부 dorny paths-filter로 mobile/batch 구분. 그래서 (a) `scripts/` 등 그 외 경로만 고친 푸시는 **CI가 아예 안 돎** → `gh workflow run ci-apps.yml --repo the-trive/caramel-api --ref <branch>` (workflow_dispatch=전 서비스 강제 빌드)로 수동 실행. (b) format 잡(`pnpm format`=ultracite)이 오랜만에 깨어나면 **남의 잠복 린트 부채**가 내 푸시에서 터질 수 있음 — 내 diff가 클린하면 원인 파일 이력(`git log -- <파일>`)으로 무관 확인 후 해당 파일 상단 `/** biome-ignore-all lint/...: 사유 */` suppress PR로 해제 (실사례: #480 머지 → scripts CLI console 린트로 develop 차단 → #481).

#### ⚠️ Prisma createMany 필드 추가 시 필수 검증 (center_price 10시간 사건)

Prisma는 클라이언트 스키마에 없는 필드를 **에러 없이 silent ignore** 한다.
Claude Code 세션에서 커밋 시 lint-staged(ultracite)가 createMany data 필드를 **자동 제거**할 수 있다.

**신규 컬럼을 createMany에 추가할 때마다 아래 3단계 필수:**

1. **커밋에 실제로 포함됐는지 확인**
   ```bash
   git show HEAD:libs/crm-logic/src/services/crm-quote-version.service.ts | grep 새_필드명
   ```
   → 결과 없으면 lint-staged가 제거한 것. **맹주성님 터미널에서 직접 커밋** 필요.

2. **배포 후 DB에 실제 저장되는지 확인**
   ```bash
   # 테스트 데이터 1건 저장 후:
   ~/claude/mysql-query.sh "SELECT 새_컬럼 FROM quote_version_item ORDER BY id DESC LIMIT 1;"
   ```
   → null이면 Prisma 클라이언트가 여전히 모르는 것. K8s 재배포 필요.

3. **맹주성님 직접 커밋 방법** (Claude Code 커밋 불가 시)
   ```bash
   git fetch origin $(gh api repos/the-trive/caramel-api/branches/main --jq '.commit.sha')
   git checkout -b fix/브랜치명 FETCH_HEAD
   # 파일 편집 후:
   git add 파일 && git commit -m "메시지" && git push -u origin fix/브랜치명
   gh pr create --base main --head fix/브랜치명 ...
   ```

### caramel-zero (`~/Desktop/Github/caramel-zero`)
- **base**: develop / **prod**: main
- 모노레포: apps/api, apps/web CI 트리거 별도

### caramel-sales-admin (`~/Desktop/Github/caramel-sales-admin`)
- **main 직접 머지 OK** → Vercel 자동배포 (develop 없음)
- UI 변경 시: feature 브랜치 → **preview URL browse 검증 먼저** → main 머지
- Vercel preview 보호 해제됨 (2026-06-09) → browse 직접 접근 가능
- browse 로그인: 메모리 `reference_credentials.md` 참조

### caramel-slack-bot 차비스 봇 (`~/projects/caramel-slack-bot`) — 운영 브랜치 = `deploy`

**핵심 원칙: 운영 브랜치(`deploy`)로는 작업 브랜치 HEAD를 직접 push하지 말 것.**
작업 브랜치(예: `phase3-wiki-lint`)가 `origin/deploy`보다 뒤처져(stale) 있으면 `git push origin HEAD:deploy`가 **운영 최신 코드를 되돌린다**(2026-06-29 partner_alert 사건 직전까지 감). `git-guardrail.py`가 stale push(=origin/deploy가 push 대상에 없음)를 자동 차단하지만, 애초에 fresh base에서 작업한다.

**올바른 배포 절차 (deploy로 보낼 땐 항상 이 방식):**
```bash
git fetch origin deploy
git worktree add /tmp/cz-deploy origin/deploy -b feat/<name>   # ① origin/deploy 기준 fresh
# ② /tmp/cz-deploy에서 변경 재적용 → 경로 명시 add → commit
cd /tmp/cz-deploy && git push origin HEAD:deploy               # ③ fresh라 ff push·가드 통과
git worktree remove /tmp/cz-deploy --force                     # ④ 정리
```
- **cron 모듈**(`partner_alert` 등) 변경: Droplet `git -C /opt/caramel-analysis-bot pull`만 — **systemctl restart 불필요**(다음 cron부터 반영).
- **봇 메인**(`app.py`/`runner.py`) 변경: pull 후 `systemctl restart caramel-analysis-bot`. 의존성 변경 시 `.venv/bin/pip install -r requirements.txt` 먼저.
- Droplet 접속·경로 상세: 메모리 `project_caramel_slack_bot`.

### Vercel CLI 사이드프로젝트 (`~/projects/*` — scrum-linear-bridge, detailer-allocation-announce 등)
GitHub CI 자동배포가 **아니라** 로컬에서 Vercel CLI로 **워킹트리를 직접** 올린다(= git 머지와 배포가 분리됨).
- **base 브랜치 = `master`** (caramel-api/zero의 develop과 다름). 새 작업은 `git checkout -b <branch> origin/master`.
- 코드 흐름: feature 브랜치 → `gh pr create --base master` → `gh pr merge --squash --delete-branch` → master pull.
- **배포 명령** (레포 루트에서):
  ```bash
  npx vercel --prod --scope caramel-thetrive --token "$(cat ~/Desktop/vercel/.vercel-token)" --yes
  ```
  - ⚠️ **토큰 경로는 반드시 `~/Desktop/vercel/.vercel-token`** — auto모드 인증 분류기가 이 경로만 허용. 동일 토큰이라도 다른 경로(`~/projects/.../.vercel-token`)는 경로 기준 거부(2026-06-22 확인).
  - 배포는 **git이 아니라 현재 워킹트리**를 올림 → 머지 후 `git checkout master && git pull`한 뒤 배포해야 최신이 반영됨.
  - `scope caramel-thetrive` = 팀, 토큰 계정 = juseongmaeng-8500.
- **public/ 정적 파일**은 빌드 없이 루트에서 서빙(`public/race.html` → `/race.html`). API는 `api/*.ts` 서버리스.
- **배포 완료 확인**: alias(`<project>.vercel.app`)에 `curl -s -o /dev/null -w '%{http_code}'`로 200 + 변경 내용 직접 확인.
- 상세: 메모리 `project_scrum_linear_bridge`, `project_detailer_allocation_announce`.

---

## 배포 완료 확인

| 레포 | 확인 방법 |
|------|----------|
| caramel-api | `gh run list --branch main --limit 1` → success |
| caramel-zero | 동일 |
| caramel-sales-admin | Vercel 대시보드 또는 PR checks |

## 자주 하는 실수

- DB 스키마를 caramel-api에서 변경(db push/ALTER) → outdated 스키마라 테이블 삭제 위험. caramel-zero `pnpm db:migrate`로만.
- develop CI 완료 전에 sales-admin preview 테스트 → 신규 컬럼 null로 나옴
- hotfix 충돌 반복 해결 시도 → 충돌 파일 없는 별도 브랜치로 처음부터
