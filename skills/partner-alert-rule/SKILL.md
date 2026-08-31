---
name: partner-alert-rule
description: "제휴·VIP 예약 알림의 판정 규칙을 추가·수정한다. Use when: 제휴처 알림 추가, 새 제휴처 알림, 제휴 규칙 추가, 예약 알림 규칙, 제휴처 카드 안 옴, VIP 알림 추가, VIP 고객 등록, 제휴·VIP 알림 채널 변경. 🔴VIP 개별 고객은 코드가 아니라 어드민 체크박스다(§1에서 갈래를 먼저 정할 것)."
---

# /partner-alert-rule — 제휴·VIP 예약 알림 규칙 추가

제휴처 고객이나 VIP 고객이 세차를 예약하면 슬랙으로 알려 숙련 디테일러 배정을 검토하게 하는 기능의 **판정 규칙**을 다룬다.

배경: 이 기능은 2026-08-10에 드로플릿 파이썬 크론(3분 폴링) + 구글시트에서 caramel-zero 안으로 이관됐다. 상세 이력은 메모리 `project_partner_vip_alert_zero`.

---

## 1. 🔴 먼저 갈래를 정한다 — 코드냐 어드민이냐

요청을 받으면 **가장 먼저** 이걸 가른다. 틀리면 필요 없는 배포를 하거나, 반대로 배포로 해결될 걸 어드민에서 찾는다.

| 요청 | 어디서 | 배포 |
|---|---|---|
| **개별 고객 한 명을 VIP로** ("이분 VIP로 해줘", "VIP 추가") | **어드민 체크박스** → §2 | 불필요 |
| **제휴처/조건을 새로** ("신세계 제휴 알림 추가", "이 쿠폰 쓰면 알림") | **코드 상수** → §3 | 필요 |
| 알림이 와야 하는데 안 옴 | 진단 → §6 | 경우에 따라 |

VIP 개별 고객은 코드에 없다. `user_grade_signal` 테이블 + 어드민 UI로 관리한다.

---

## 2. 개별 VIP 추가 (배포 불필요, CS가 직접)

1. `https://b2b.thetrive.com/admin/users` 에서 전화번호나 이름으로 고객 검색
2. 고객 클릭 → 고객상세
3. 맨 위 "고객 정보" 칸의 **[수정]** 버튼
4. **`VIP 고객 (예약 시 알림 발송 · 디테일러 앱에 배지 표시)`** 체크박스 ON (관리자 여부 바로 위)
5. **같은 창의 "메모" 칸에 사유를 적는다** ← 이게 실제로 디테일러 앱에 뜨는 칸
6. 저장 → 창을 다시 열어 체크가 남아 있으면 반영됨

API로 할 때는 `caramel-admin-api` 스킬의 `PATCH /v1/admin/users/{userId}`.
바디는 **전필드 필수**: `{adminYn, name, note, phone, vipYn}`. 현재값을 GET으로 읽어 그대로 재전송하고 바꿀 필드만 교체한다.

- ⚠️ `note`는 **덮어쓰기**다. 기존 내용을 읽어 줄바꿈 후 append할 것.
- ⚠️ `user_grade_signal.reason` 컬럼이 있지만 **입력 UI가 없어 아무도 읽지 않는다.** 사유는 `note`에 넣는다.

### 🔴 이미 잡혀 있는 예약에는 알림이 가지 않는다

알림 트리거는 **예약 생성 시점 1회**다. VIP를 켜기 전에 이미 만들어진 예약은 슬랙 카드도, 20시 다이제스트도 안 나간다(다이제스트는 생성 시 기록한 `reservation_metadata.partner`를 읽는다). **디테일러 앱 배지는 뜬다** — 배지는 조회 시점 판정이다.

⟹ 급한 예약이 이미 잡혀 있으면 사람이 직접 챙겨야 한다. 그 고객의 다음 예약부터 자동이다.

---

## 3. 제휴처 규칙 추가 (코드)

### 파일

`apps/api/src/domains/reservation/infrastructure/persistence/notification/partner-vip-alert.rules.ts`

`export const PARTNER_VIP_ALERT_RULES` 배열 (규칙 9개, 마지막이 `프리미엄 세차권`).

⚠️ **2026-08-14에 이 파일로 분리됐다.** 예전엔 `slack-reservation-ops-notification.repository.ts` 안에 있었다. 20시 크론의 미판정 훑기(#1558)가 같은 규칙을 써야 해서 슬랙 어댑터에서 떼어냈다 — 즉 **규칙 한 줄이 슬랙 카드와 크론 훑기 양쪽을 동시에 바꾼다.**

⚠️ **코드를 읽을 땐 `origin/main`을 쓴다.** 로컬 `main`은 거의 항상 낡아 있다 — `git show main:<경로>`가 심볼을 못 찾으면 코드가 없는 게 아니라 참조가 stale인 것이다(2026-08-12에 실제로 이걸로 헛짚었다). 진실은 `git fetch && git show origin/main:<경로>` 또는 `git ls-remote`.

### 규칙 한 덩이의 모양

```ts
{
  channels: PARTNER_ALERT_CHANNELS,          // 전 규칙이 같은 채널을 쓴다
  couponNamePatterns: ['신세계'],
  label: '신세계',                            // 슬랙 카드 헤더에 그대로 찍힌다
  mentionIds: PARTNER_VIP_OPS_MENTION_IDS,
  utmPatterns: ['신세계', 'SSG'],
},
```

해당되는 신호 키만 쓴다. 없는 키는 생략.

| 키 | 무엇을 보나 | 매칭 |
|---|---|---|
| `utmPatterns` | `app_user.utm_source` | 부분일치, 대소문자 무시 |
| `couponNamePatterns` | 그 고객의 `coupon_code.name` 전체 이력 | 부분일치, 대소문자 무시 |
| `couponCodes` | 그 고객의 `coupon_code.code` 전체 이력 | **정확일치** |
| `servicePatterns` | 이 예약에 쓴 `service.name` | 부분일치, 대소문자 무시 |

빈 문자열 패턴(`''`)은 건너뛴다(오탐 방지). 규칙 내 검사 순서는 utm → 쿠폰명 → 쿠폰코드 → 세차권명.

### 🔴 넣는 위치 — 배열 순서가 우선순위다

**첫 매칭 하나만** 채택한다. 새 제휴처는 **맨 마지막 `프리미엄 세차권` 규칙 앞**에 넣는다.

`프리미엄 세차권`을 앞으로 옮기면 "유입경로가 더현대인 고객이 프리미엄 패키지로 예약"했을 때 제휴처 채널이 아니라 **디테일러방·마케팅방으로 새어나간다.** 이게 이 기능의 유일한 "잘못된 방으로 새는" 사고 모드다.

테스트로 잠겨 있다 — 같은 디렉터리 `slack-reservation-ops-notification.repository.spec.ts`의 `PARTNER_VIP_ALERT_RULES 배열 순서 잠금` describe(규칙 상수는 옆 파일로 분리됐지만 순서 잠금 스펙은 여기 남아 있다). 순서를 깨면 CI가 빨간불이 된다.

### 새 슬랙 채널로 보낼 때

기존 채널이 아니면 두 단계 더 필요하다.

1. `apps/api/src/platform/slack/domain/slack-channel-registry.ts`의 `SLACK_CHANNEL_KEYS`에 추가. 채널명 조회 권한이 없는 방은 **채널 ID로 등록**한다(`chat.postMessage`는 ID도 받고 채널명 변경에도 안 깨진다).
2. **그 방에 봇을 초대.** 빠뜨리면 코드는 정상인데 카드만 안 온다.

레지스트리에 키를 추가하면 `openapi.json`의 enum이 바뀐다 → `pnpm openapi:sync` 후 변경분 커밋. 생성물 손편집 금지.

### 기존 채널 상수

2026-08-31 이후 제휴·VIP 카드는 규칙과 무관하게 한 채널로만 간다. 반얀트리·프리미엄 세차권만
디테일러 방·마케팅 방으로 따로 가던 것을 합치면서 `PREMIUM_VOUCHER_ALERT_CHANNELS`는 사라졌다.

| 상수 | 실제 채널 |
|---|---|
| `PARTNER_ALERT_CHANNELS` | `C0BTM7NRUS1` (#caramel_vip_알림) |
| `PARTNER_VIP_OPS_MENTION_IDS` | 이보희·`U079D626ZAP`·이현복·전승엽 |

배정된 디테일러의 `slack_member_id`가 있으면 멘션 맨 앞에 자동으로 붙는다.

---

## 4. dev 검증 (규칙 추가하면 반드시)

### 🔴 dev의 `service.id`는 prod와 다르다 — 여기서 제일 많이 틀린다

prod id로 dev 테스트를 짜면 **에러 없이 0건**이 나와 "기능 미동작"으로 오판한다.

| | prod | dev |
|---|---|---|
| 137 | `프리미엄 세차 패키지 올클린 케어` | **`[B2B] 외부만`** |
| 120 / 140 / 142 | 반얀 / 자스민 / 외부+내부 프리미엄 | **dev에 없음** |
| dev에서 규칙에 걸리는 세차권 | — | **47 · 48 · 50 · 138** |

⟹ dev 쿼리는 항상 `service.name LIKE`로 id를 되찾아 쓴다.

### 검증용 계정 (2026-08-10 실측)

| 항목 | 값 |
|---|---|
| 고객 | `app_user 33053` (테스트 / 01082214316) — 차량 4088, 주소 12687 |
| 디테일러 | `detailer 183` 맹주성(테스트), `slack_member_id` 있음 → 멘션 눈으로 확인됨 |
| 세차권 발급 | `POST /v1/admin/users/33053/tickets {"productIds":[3537]}` → service 14 (규칙 무매칭) |
| 예약 생성 | `POST /v1/admin/users/33053/reservations` — `keyDirectHandoverYn`은 **boolean** |
| dev 어드민 | `https://test.caramel.thetrive.com/admin/users/33053` (⛔ gamma·b2b는 prod다) |

dev 어드민 토큰·빙의 토큰 레시피는 메모리 `reference_caramel_dev_db_access`.

### 신호 심는 법

| 신호 | 방법 |
|---|---|
| 세차권명 | 티켓 발급 후 `UPDATE user_service SET service_id=47 WHERE id=<발급id>` (dev에 그 service를 주는 상품이 없다) |
| utm | `UPDATE app_user SET utm_source='더현대' WHERE id=33053` — **테스트 후 원복 필수** |
| 쿠폰명 | `coupon_code` 1행 INSERT(`code`,`name`,`expired_at` 필요) + `coupon_code_usage(coupon_code_id, user_id)` 1행. 코드가 읽는 건 이 조인뿐이라 2행으로 신호가 정확히 재현된다 |
| VIP | 어드민 PATCH `vipYn: true` |

예약 테이블은 **직접 쓰지 않는다** — 예약은 API로만 만든다.

### 판정 확인

```sql
SELECT `key`, value FROM reservation_metadata
WHERE reservation_id = <RID> AND `key` IN ('partner','partnerReason');
```

`partner`=라벨, `partnerReason`=근거(`utm_source=…` / `쿠폰명~…` / `쿠폰코드=…` / `세차권~…` / `VIP 고객`). 이 문자열은 슬랙 카드 "판정:" 줄과 **같은 값**이다.

### 🔴 회귀 최소 실증 — 이것만은 반드시

**무매칭 고객으로 예약 1건**을 만들어 ①기존 예약 카드가 `caramel_세차신청_알림`에 평소처럼 오고 ②새 카드 0장 ③`partner` 기록 0행인지 본다.

⚠️ **0행이 "정확히 판정해서"인지 "경로가 죽어서"인지 가려야 한다.** 방법 = **단일 변수 A/B**: 같은 고객·차량·주소·디테일러·세차권·날짜에서 신호 하나만 바꿔 두 번 예약해 0행 vs 2행을 만든다. 로그로도 확인:

```bash
POD=$(kubectl get pods -n dev | grep zero-api | grep Running | awk '{print $1}' | head -1)
kubectl logs -n dev "$POD" --since=10m | grep -E "<RID>|Failed to send Slack"
```

`Booking created ops notification sent`가 찍혔으면 기존 경로는 살아 있다.

### ⚠️ dev에도 발송 억제가 없다

- 슬랙: `.env.dev`에 `SLACK_BOT_TOKEN`이 있고 dev 분기가 없다 → **실채널로 발송**된다(카드 제목에 `(DEV)`만 붙음). 제휴·VIP 카드는 전부 `C0BTM7NRUS1`(#caramel_vip_알림)에 뜬다. 테스트 발송은 사전 공지하거나 짧게 몰아서 끝낸다.
- 문자·알림톡: 시그널 어댑터(bizm·naver-sens·expo-push)도 dev 억제가 없다 → **20시 크론 엔드포인트(`POST /v1/internal/cron/dailyDetailerSchedule`)를 그냥 누르면 실제 디테일러에게 발송된다.** 누르지 말고 조회 조건을 SQL로 재현해 검증한다:

```sql
SELECT r.id, r.reservation_datetime, u.name, d.name AS detailer,
       (SELECT m.value FROM reservation_metadata m
        WHERE m.reservation_id=r.id AND m.`key`='partner' AND m.deleted_at IS NULL
        ORDER BY m.id LIMIT 1) AS partner
FROM reservation r JOIN app_user u ON u.id=r.user_id
LEFT JOIN detailer d ON d.id=r.detailer_id
WHERE r.deleted_yn=0 AND r.status IN ('CONFIRMED','IN_PROGRESS')
  AND u.deleted_yn=0 AND u.test_yn=0
  AND EXISTS (SELECT 1 FROM reservation_metadata m2
              WHERE m2.reservation_id=r.id AND m2.`key`='partner' AND m2.deleted_at IS NULL)
  AND r.reservation_datetime >= '<내일KST00:00> - 9h' AND r.reservation_datetime < '<모레KST00:00> - 9h';
```

### 정리 (보고 전 필수)

예약 `bulk-cancel` → 심은 신호 원복(utm·service_id) → 시드 쿠폰 삭제 → VIP OFF → 테스트 `partner` 기록 삭제 → 잔존 0 확인.

---

## 5. 배포

| 순서 | 무엇 | 주의 |
|---|---|---|
| 1 | `--base develop` PR → CI → 머지 | develop 머지 = 몇 분 뒤 dev 자동 반영 |
| 2 | dev 검증 (§4) | 회귀 실증부터 |
| 3 | main 승격 — **사용자 승인 필수** | 아래 |

### 🔴 main은 통째 승격하지 말고 격리 체리픽

`develop → main` PR을 만들면 develop에 쌓인 **남의 커밋 전부**가 prod에 간다. 2026-08-10에 실제로 막았다 — develop이 main보다 41커밋 앞서 있었고 그 안에 **prod에 존재하지 않는 신규 테이블 4개**를 참조하는 코드가 있어서, 통째로 올리면 남의 기능 3개가 prod에서 500이 됐다. prod DDL은 GitOps로 자동 실행되지 않는다.

판별법:

```bash
git diff --stat origin/main origin/develop -- apps/api/prisma/schema.prisma   # 0이 아니면 위험
git diff origin/main origin/develop -- apps/api/prisma/schema.prisma | grep '^+model'
# 나온 테이블이 prod에 있는지:
./mysql-query.sh "SELECT TABLE_NAME FROM information_schema.TABLES
  WHERE TABLE_SCHEMA='caramel-prod' AND TABLE_NAME IN ('...')"
```

격리 체리픽:

```bash
git fetch origin
git checkout -b hotfix/<이름> origin/main
git cherry-pick <develop의 squash 커밋>
# conflict는 대개 생성물뿐 → main 쪽(--ours) 취한 뒤 pnpm openapi:sync 재생성
```

체리픽 후 확인: 커밋 1개 · `schema.prisma` 변경 0 · 남의 신규 테이블 참조 0건 · 4앱 typecheck · api/web/detailer 테스트.

승인 후에만 `PROD_MERGE_APPROVED=1` 마커를 붙여 머지한다.

### prod 배포 확인은 동작으로

`prod` 네임스페이스는 권한이 없어 파드를 못 본다. 대신 동작으로 판정한다 — 예: 어드민 응답에 새 필드가 실리는지(응답 스키마가 `.strict()`라 계약에 없으면 깎인다), 또는 실제 예약에 `partner` 기록이 붙는지.

---

## 6. 알림이 안 올 때 진단 순서

1. **판정이 됐나** — `reservation_metadata`에 `partner` 행이 있나
   - 없다 → 규칙 매칭 실패. 그 고객의 `utm_source`·쿠폰 이력·이 예약의 `service.name`을 실제로 조회해 패턴과 대조. dev면 §4의 service.id 함정부터.
   - 있다 → 2번으로
2. **슬랙으로 나갔나** — 로그에 `Failed to send Slack`이 있나
   - ⚠️ **`partner` 기록이 있다는 게 "카드가 갔다"를 뜻하지 않는다.** 기록이 슬랙 발송보다 **먼저** 일어난다. 발송 확인은 채널을 직접 봐야 한다.
3. **봇이 그 방에 있나** — 새 채널을 추가했으면 초대 여부
4. **예약 생성 경로를 탔나** — 비 오는 날 리터치로 만들어진 예약은 예약 생성 이펙트를 타지 않아 알림 대상이 아니다(알려진 갭)
5. **VIP를 켠 시점이 예약 생성보다 늦나** — §2의 시점 갭

### 실패해도 예약 생성은 안 죽는다

슬랙 발송은 `SlackFacadeService`가 예외를 자체로 삼켜 위로 전파되지 않는다. 쿠폰 조회·판정 기록 실패도 전부 삼킨다. 신규 코드는 기존 발송(예약 카드·반얀 알림) **뒤**에 있다. 즉 알림 문제로 예약이 실패하는 일은 없다 — 반대로 **조용히 안 오는 것**이 이 기능의 실패 모드다.

---

## 7. 파이썬 크론 병행 상태 (2026-08-12 현재)

드로플릿(`139.59.121.39`) 파이썬 크론이 **아직 돌고 있다.** 시트에 있는 제휴처는 카드가 2장 온다.

끄기 전 조건: VIP 15명 이관 완료(✅) → 반나절 병행 관찰 → **회차 대조(파이썬 `COUNT(*)` vs zero `reservation.terms`)**. 끌 때는 crontab 2줄을 주석 처리하고 **heartbeat까지 꺼야 한다**(안 그러면 미동작 의심 DM이 매일 온다).

⚠️ `프리미엄 세차권` 규칙은 **시트에 없다** — 파이썬이 원래 안 잡던 건이라 비교 대상이 아니다.

관련 메모리: `project_partner_vip_alert_zero` · `project_caramel_slack_bot` · `reference_caramel_dev_db_access` · `reference_zero_api_slack_notification_paths` · `reference_zero_api_prod_deploy_is_gitops`
