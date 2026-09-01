# 팀 스킬 목록

당번이 현장에서 불릴 때 뭘 쓸 수 있는지 유형별로 정리했다.
클로드에게 `/스킬이름`으로 부르거나, 그냥 상황을 말하면 알아서 고른다.

설치는 [install-skill](install-skill/SKILL.md) 참고. 팀 셋업(`setup.sh`)을 안 돌려도
레포만 클론하고 필요한 스킬 디렉토리만 복사하면 된다.

```bash
git clone https://github.com/the-trive/caramel-team-setup ~/.caramel-team-setup
cp -R ~/.caramel-team-setup/skills/reassign ~/.claude/skills/reassign
```

> 자기 클로드 설정(SessionStart 훅 등)을 쓰고 있으면 `setup.sh`보다 위 방식을 권한다.
> DB를 보는 스킬은 `mysql-query.sh` 옆에 `.env`가 있어야 돈다.

---

## 스케줄 조율

현장에서 제일 자주 들어오는 유형.

| 스킬 | 쓰는 상황 |
|---|---|
| [reassign](reassign/SKILL.md) | 디테일러가 휴가·휴무·퇴사·파견이라 그날 예약을 못 소화할 때 대체자를 찾아 옮긴다. 존 외 예약 조율 포함 |
| [rain-retouch](rain-retouch/SKILL.md) | 비 온 다음날 리터치 신청(`REQUESTED`)이 쌓였을 때 존별 일괄 배정 |
| [zone-change](zone-change/SKILL.md) | 디테일러 존 변경 (Z1 → Z3). DB 실제 변경까지 |
| [zone-assignment](zone-assignment/SKILL.md) | 신입·파견 디테일러를 어느 존에 넣을지 분석. 결정 단계까지만 — 실제 변경은 zone-change |
| [clean-multi-reservations](clean-multi-reservations/SKILL.md) | 동일 차량 다중예약 알림이 떴을 때 취소 대상 분석 후 정리 |

**rain-retouch는 5단계로 돈다** — REQUESTED 조회 → 존별 디테일러 근무시간(휴무 제외) →
예약 점유 확인 → 후보 선택 → API 배정.
후보 선택은 원디테일러 우선 → 이른 슬롯 → 동선 점수 순이고,
외부만 예약 뒤 +1시간 슬롯까지 계산에 넣는다.
2026-06-19 운영 사고에서 나온 필수 필터 체크리스트가 들어 있다.

## 세차권·구독·결제

| 스킬 | 쓰는 상황 |
|---|---|
| [grant-wash-voucher](grant-wash-voucher/SKILL.md) | 세차권 지급. 전화번호로 고객 찾고 → 지급 → DB로 몇 장 늘었는지 검증까지 |
| [ticket-audit](ticket-audit/SKILL.md) | "세차권이 사라졌다" "결제가 매달 다르다" "해지했다는데" — 발급·사용·결제 타임라인을 교차검증해 원인을 찾는다 |

**티어 무관 외부만 = `serviceId 135`**가 기본값이다.
티어별 가격 세차권(15/18/21/24/27/30/33)과 다른 물건이고, 135는 어느 티어 차량에나 쓴다.
올클린 케어는 1, 내부 디테일링은 8인데 이 둘은 현행 여부를 먼저 확인하는 게 좋다.

## 어드민 조작 — caramel-admin-api

[caramel-admin-api](caramel-admin-api/SKILL.md)는 종합 스킬이다.
어드민 고객상세 화면에서 클릭으로 하던 걸 전부 API로 부른다.

**읽기**

- 고객 상세
- 예약폼 옵션 (주소·디테일러)
- 구독 취소계획 — 얼마 환불되는지 미리 보기
- 차량 서비스이력
- 주소 검색
- 차량 브랜드·모델 (빙의 토큰 필요)
- 상품 목록 (타입·티어별)

**세차권·티켓**

- 세차권/옵션 지급
- 티켓 수정 — 사용여부·유료여부·삭제·후불·연결예약·만료일
- 반얀 패키지 지급

**예약**

- 예약 생성 (주소·차량·디테일러·시각·세차권 지정)
- 예약 수정 / 재배정 / 완료 처리
- 예약 일괄취소 — 세차권 반환(`GIVE_BACK`) 또는 삭제(`DELETE`) 선택

**구독**

- 구독 추가
- 구독 수정 — 상태·종료일·일시정지·해지·대표차량
- 구독 취소 — 현금/포인트 환불액, 후처리 지정

**포인트**

- 지급 (금액·만료일·사유) / 수정 / 삭제

**고객 정보**

- 주소 추가·수정·삭제
- 차량 추가·수정
- 기본정보 수정 (이름·전화·메모)
- 결제 환불
- 빙의 토큰 발급 — 고객 화면을 그대로 본다

### 재배정할 땐 가드를 먼저 읽을 것

재배정 API는 **대상 디테일러의 근무시간·휴무·퇴사 여부를 전혀 검증하지 않는다.**
API가 200을 주는 것과 그 디테일러가 실제로 갈 수 있는 것은 별개다.
스킬 안에 적격 필터 6개(현직·필드·예약수령·휴무아님·겹침없음·더미제외)와
반얀 파견 예외가 정리돼 있다. `detailer.retired_yn`은 못 믿는다 — 실제 퇴사자도 0이다.

예약 수정 PATCH에는 **안 실은 필드가 `null`로 덮어써지는** 함정이 있다.
차량 연결이 통째로 사라지므로 재배정할 땐 현재값을 그대로 실어 보낸다.

## 문자 발송

[lms](lms/SKILL.md) — SMS·LMS·MMS.

- 본문 길이·이미지 유무로 채널 자동 선택 (SMS 45자 / LMS 1000자 / MMS 이미지 1장)
- `$1` `$2` 개인화 — CSV로 사람마다 다른 이름·날짜·금액
- 대량 발송 (30명씩 청크, 실패 번호 별도 리포트)
- 무료수신거부 문구 자동 첨부
- 예약 발송, dry run
- 발송 전 미리보기 강제, 고객이 1명이라도 포함되면 명시적 확인 필요

발송은 비용이 나간다. 본인 번호로 한 번 테스트하고 보내는 걸 권한다.
발신번호는 사무실 `15445932`를 쓴다.

## 버그·데이터

| 스킬 | 쓰는 상황 |
|---|---|
| [bug-report](bug-report/SKILL.md) | 현장에서 받은 현상을 개발자가 바로 파고들 수 있는 티켓으로 변환 |
| [cbr-query](cbr-query/SKILL.md) | 그라파나 대시보드용 분석 쿼리 생성 (세차당 매출, 디테일러 생산성, 옵션 추가율 등) |
| [amplitude-chart](amplitude-chart/SKILL.md) | 퍼널·세그멘테이션 차트 생성 |
| [partner-alert-rule](partner-alert-rule/SKILL.md) | 제휴처 알림 카드가 안 올 때 판정 규칙 추가·수정 |

## 쓰기·만들기

| 스킬 | 쓰는 상황 |
|---|---|
| [experiment-doc](experiment-doc/SKILL.md) | 실험 설계·실험 문서 |
| [feedback](feedback/SKILL.md) | 팀원 작업물 리뷰 |
| [writing](writing/SKILL.md) | 문서 작성 원칙 |
| [slides](slides/SKILL.md) | 발표 덱 |
| [caramel-deploy](caramel-deploy/SKILL.md) | PR 생성·배포. 레포별 base 브랜치와 충돌 함정 |
| [install-skill](install-skill/SKILL.md) | 팀 스킬 설치 |
| [data-learn](data-learn/SKILL.md) | 쿼리 지식을 QUERY_REFERENCE·DB_SCHEMA에 반영 |

---

## 안전 규칙 (전부 공통)

- 어드민 API와 세차권·문자 스킬은 **운영 서버에 즉시 반영**된다. 되돌리기 어렵다.
- 쓰기 작업은 대상 id와 내용을 확인받은 뒤에 실행한다. 스킬 안에 확인 단계가 박혀 있다.
- DB 직접 쓰기는 하지 않는다. 반드시 API를 경유한다.
- 실행 후에는 DB나 화면으로 결과를 확인하고 보고한다. "했습니다"만 쓰지 않는다.

## 스킬을 고치는 것도 씨앗이다

당번날 겪은 걸 스킬에 반영해두면 다음 당번이 같은 걸 안 겪는다.
브랜치 만들어 PR 올리면 된다.
