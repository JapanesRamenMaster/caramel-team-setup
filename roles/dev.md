## 개발 작업 추가 규칙

이 역할은 코드를 **수정하고 PR을 만든다**. 위 "코드는 읽기 전용" 규칙 대신 아래를 따른다.

### 코드를 읽는 순서

- 현행 동작은 **`repos/caramel-zero`의 `origin/main`** 부터 본다. 레거시 레포(caramel-app, caramel-api, careplus-web)는 화면·엔드포인트에서 역추적으로 확인됐을 때만 근거로 쓴다.
- 로컬 파일이 아니라 **배포된 코드**를 봐야 한다. `git show origin/develop:<경로>` 로 확인한다.
- `caramel-zero` 작업 전 레포 루트의 `AGENTS.md` 를 먼저 읽는다(헥사고날 구조·import 규칙이 거기 있다).

### 개발 파이프라인

| 단계 | 무엇을 | 검증 |
|---|---|---|
| 1. 계획 | 다단계면 `superpowers:writing-plans`. 각 단계를 `[단계] → 검증: [방법]` 으로 먼저 적는다 | 검증 방법이 안 적히는 단계는 계획이 덜 된 것 |
| 2. TDD | 버그 수정은 **재현 테스트 먼저**. 구현 전에 빨간불을 눈으로 본다 | 구현을 되돌려 다시 빨간불인지 확인 |
| 3. 구현 | 요청된 것만. 인접 코드·주석·포매팅을 "개선"하지 않는다 | 파일을 읽지 않고 수정하지 않는다 |
| 4. 리뷰 | `/review` + `codex:rescue` 로 diff를 **독립 2회** 리뷰 | 단일 엔진에는 사각지대가 있다 |
| 5. 배포·검증 | PR → 머지 → 배포까지 끝내고, curl·앱으로 핵심 플로우를 **직접 실행** | 보고에 `테스트 결과: ...` 를 포함한다. CI 초록 ≠ 배포 완료 |

- `/caramel-deploy` — 레포별 배포 절차·base 브랜치·conflict 함정. **배포 작업을 시작할 때** 호출한다.
- `/bug-report` — 버그를 다른 개발자에게 넘길 때. 현상·재현 경로를 상대가 자기 전문성을 쓸 수 있는 형태로 정리한다.

### PR base 브랜치 — 틀리면 prod 사고

| 레포 | base | 이유 |
|---|---|---|
| `caramel-zero` | **`develop`** | `main` 머지 = prod 자동 배포 |
| `caramel-api` | **`develop`** | 위와 동일 |
| `caramel-sales-admin` | `main` | 어드민은 대상 아님 |

만들기 전에 `gh pr list --state merged` 로 실제 base를 확인한다. 기억에 의존하지 않는다.

### 안전 규칙

- 새 작업은 `git fetch` 후 `git checkout -b <브랜치> origin/<base>`.
- 스테이징은 **내가 바꾼 경로만**. `git add -A` · `git commit -a` 금지.
- 보호 브랜치 직접 push 금지. 무조건 PR.
- **제품 레포(zero·api·app·detailer-app)의 main 머지는 사람의 명시 승인이 필요하다.** PR 생성까지만 하고 멈춘다.
- `git push --force` · `reset --hard` · `clean -f` · `checkout .` 금지.
- DB는 읽기 전용. 스키마 변경은 `schema.prisma` 를 고쳐 마이그레이션으로 한다. **raw DDL을 DB에 직접 치지 않는다**(마이그레이션 파일이 없으면 다음 배포에서 테이블이 사라진다).

### 가드레일 훅 — 막히면 우회하지 말고 이유를 읽는다

`~/.caramel-team-setup/hooks/` 의 훅이 아래를 차단한다. 권한 설정과 무관하게 동작한다.

| 훅 | 막는 것 |
|---|---|
| `git-guardrail` | 보호 브랜치 직접 push, force push, 위험한 reset |
| `prod-main-merge-gate` | 제품 레포 main 타겟 PR 머지 (승인 후 `PROD_MERGE_APPROVED=1` 을 붙여 재실행) |
| `db-guardrail` | DROP / TRUNCATE / `prisma --accept-data-loss` / `migrate reset` |
| `prisma-migration-guard` | 마이그레이션 파일 손편집, 스키마 우회 DDL |
| `caramel-deploy-gate` | `/caramel-deploy` 스킬을 안 거친 `gh pr create` |
| `caramel-zero-agents-gate` | caramel-zero 첫 편집 시 AGENTS.md 미확인 |
| `caramel-api-commit-guard` | caramel-api 의 Prisma createMany 관련 커밋 위험 경고 |

훅이 막았다면 그 명령이 되돌리기 어렵다는 뜻이다. `--no-verify` 나 샌드박스 해제로 뚫지 말고, 막힌 이유를 읽고 다른 방법을 찾는다. 정말 필요하면 사람에게 확인받는다.

### 자주 하는 실수

- **로컬 초록 ≠ 통과**: 변경한 spec 파일만 돌리면 다른 shard의 실패를 놓친다. 파이프(`| tail`)를 쓰면 exit code 가 tail 것으로 바뀐다.
- **PR diff 통계는 3-dot**: `git diff origin/<base>...HEAD`. 2-dot 은 남의 커밋까지 센다.
- **DB 시각은 UTC**: KST 로 보려면 +9시간.
- **테스트 데이터는 보고 전에 지운다.**

### 추가로 설치할 것 (한 번만)

이 셋업은 팀 공통 부분만 깐다. 개발용 도구는 Claude Code 안에서 직접 설치한다.

```
/plugin marketplace add obra/superpowers-marketplace
/plugin marketplace add DietrichGebert/ponytail
/plugin install superpowers
/plugin install ponytail
/plugin install codex
```

브라우저 QA 도구(`/qa`, `/browse`, `/review`, `/ship`):

```
git clone https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
```
