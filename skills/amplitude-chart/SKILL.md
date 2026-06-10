---
name: amplitude-chart
version: 1.0.0
description: |
  앰플리튜드 퍼널/세그멘테이션 차트 생성. 실험 문서 또는 구두 설명 기반.
  Triggers: "앰플리튜드 차트", "amplitude chart", "차트 만들어", "퍼널 차트", "대시보드 차트".
scope: team
owner: juseong
side-effects:
  - api-call-write
tags:
  - 분석
  - Amplitude
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
  - AskUserQuestion
  - TodoWrite
  - mcp__claude_ai_Amplitude__get_context
  - mcp__claude_ai_Amplitude__get_dashboard
  - mcp__claude_ai_Amplitude__get_events
  - mcp__claude_ai_Amplitude__get_cohorts
  - mcp__claude_ai_Amplitude__query_amplitude_data
  - mcp__claude_ai_Amplitude__query_chart
  - mcp__claude_ai_Amplitude__query_charts
  - mcp__claude_ai_Amplitude__render_chart
  - mcp__claude_ai_Amplitude__save_chart_edits
  - mcp__claude_ai_Amplitude__edit_dashboard
  - mcp__claude_ai_Amplitude__search
---

# /amplitude-chart -- 앰플리튜드 차트 생성

사용자의 실험 문서 또는 구두 설명을 기반으로 앰플리튜드 퍼널/세그멘테이션 차트를 생성한다.

## 워크플로우

### 1단계: 맥락 파악
- 사용자의 요구사항을 이해하고, 불명확한 부분은 질문
- 어떤 퍼널/지표를 보고 싶은지 확인

### 2단계: 이벤트 확인
- 아래 **자주 쓰는 이벤트 레퍼런스**에서 먼저 찾기
- 없으면 `events.yaml` (repos/caramel-all/events.yaml) 참조
- yaml에도 없으면 프론트 코드베이스에서 실제 이벤트명 확인
- **yaml과 실제 앰플리튜드 이벤트명이 다르면 사용자에게 보고** (실제 이벤트로 차트 생성)

### 3단계: 차트 계획 제안
- 기존 대시보드(fig4uf5q) 패턴을 참고하여 차트 구성 제안
- 이벤트 스텝, 세그먼트, 필터, conversion window 등 명시
- **사용자 확인 후 진행** (바로 만들지 않음)

### 4단계: 차트 생성
- `render_chart` → `save_chart_edits`로 생성
- 한 개씩 만들고 링크 공유

### 5단계: 수동 작업 안내
차트 생성 후 반드시 안내:
- **publish 필요**: 차트가 비공개(개인 스페이스)로 생성됨. 앰플리튜드에서 직접 publish 해야 검색 가능
- **스텝 라벨 필요**: 퍼널 스텝 이름을 한국어로 rename 필요 (API로 설정 불가). 라벨 매핑 목록을 텍스트로 제공

### 6단계: 대시보드 배치 (요청 시에만)
- 사용자가 명시적으로 요청할 때만 `edit_dashboard`로 배치
- 요청 없으면 차트 생성 + 링크 공유까지만

---

## 프로젝트 정보

- 프로젝트: **Careplus-B2C** (appId: `608017`)
- Tester 코호트: `zkv5o7ol` — **모든 차트에서 반드시 제외**
- Timezone: Asia/Seoul
- 메인 대시보드: `fig4uf5q`

## 차트 네이밍 규칙

- `Funnel_[설명]_[YYMMDD]` — measurement가 Conversion일 때
- `FOT_[설명]_[YYMMDD]` — FOT = Funnel Over Time. measurement가 Over Time일 때

## 결제 이벤트 구분

- `Event/Payment/Complete` — **앱** 결제 성공
- `Event/Payment/Success` — **웹** 결제 성공

## 세그먼트 용어

- **딥링크**: 웹 랜딩 → 앱 설치 (DeepLink/Received >= 1 within 1일)
- **Direct**: 앱마켓 직접 설치 (DeepLink/Received < 1 within 1일)
- "Organic"이 아니라 "Direct"로 구분

## 현재 가입 플로우 순서 (2026-04 기준)

View/FirstLaunchBenefitModal → 약관 동의 → Click/FirstLaunchBenefitModal/SignInButton → 전화번호 인증 → Event/SignIn

## MCP API 제약사항

- `customXAxisLabels` (퍼널 스텝 라벨): **설정 불가**. 라벨 목록을 텍스트로 제공
- `customSerieLabels` (세그먼트 라벨): **설정 불가**
- 차트 publish: **불가**. 비공개로만 생성됨
- 세그먼트 `label` 필드: params.segments에서 설정 가능

---

## 자주 쓰는 이벤트 레퍼런스

### 웹 랜딩 → 앱 설치

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/OnboardLandingPage | 랜딩 페이지 조회 | Web |
| View/OnboardLandingPage/Section | 섹션 노출 | Web |
| Click/OnboardLandingPage/CTA | CTA 클릭 | Web |
| View/AppInstallNudgeModal | 앱 설치 모달 조회 | Web |
| Click/AppInstallNudgeModal/InstallButton | 앱 설치 클릭 | Web |

### 앱 첫 실행 → 가입

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/FirstLaunchBenefitModal | 첫 실행 혜택 모달 조회 | App |
| Click/FirstLaunchBenefitModal/SignInButton | 로그인하고 혜택 받기 클릭 | App |
| View/SignInScreen/TermsAgreeFunnel | 약관 동의 페이지 조회 | App |
| Click/SignInScreen/TermsAgreeFunnel/AllAgreeCheckbox | 모든 약관 동의 클릭 | App |
| View/SignInScreen/PhoneNumberCertificationFunnel | 전화번호 인증 페이지 조회 | App |
| Event/SignInScreen/PhoneNumberCertificationFunnel/Verify/Success | 인증 성공 | App |
| Event/SignIn | 로그인/가입 완료 (property: newUserYn) | App |

### 차량 등록

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| Event/AddCarModal/Submit | 차량 등록 완료 | App |
| Event/CreateCar/Success | 차량 등록 성공 | App |

### 상품 선택 → 예약

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/OnboardProductPage | 상품 페이지 조회 | App |
| Click/OnboardProductPage/Subscribe | 상품 선택 | App |
| Select/OnePageReservation/SelectAddressStep/Address | 주소 선택 | App |
| Select/OnePageReservation/SelectAddressStep/RecentAddress | 최근 주소 선택 | App |
| Click/OnePageReservation/SelectOptionStep/TimeSlots/SelectTime | 시간 선택 | App |
| Open/OnboardReservationConfirmBottomSheet | 예약 확인 바텀시트 | App |
| Click/OnboardPrecautionPage/Submit | 유의사항 확인 완료 | App |

### 결제

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/CartBottomSheet | 결제 모달 조회 | App |
| Click/CartBottomSheet/PurchaseButton | 결제하기 클릭 | App |
| Event/Payment/Complete | 결제 성공 | **App** |
| Event/Payment/Success | 결제 성공 | **Web** |
| Event/Payment/Error | 결제 실패 | App |

### 딥링크/어트리뷰션

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| DeepLink/Received | 딥링크 수신 (raw) | App |
| DeepLink/Parsed | 딥링크 파싱 완료 | App |
| DeepLink/Routed | 딥링크 라우팅 완료 | App |
| DeepLink/AttributionCaptured | 어트리뷰션 데이터 캡쳐 | App |

### 홈/내 차고

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/MyGarage/Page | 내 차고 페이지 조회 (property: contentFlag) | App |
| Click/MyGarage/ProductCards/CTAButton | 상품 CTA 클릭 | App |
| Click/MyGarage/FirstReservationButton | 첫 세차 예약 CTA 클릭 | App |
| Click/MyGarage/ReservationCreateButton | 세차 예약하기 CTA 클릭 | App |

### 구독

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/SubscriptionProductsPage | 구독 상품 페이지 조회 | App |
| Click/SubscriptionProductsPage/CTAButton | 구독/다회권 구매하기 클릭 | App |
| View/AppFirstWashProductsPage | 첫 세차 전용 예약 페이지 조회 | App |
| Click/AppFirstWashProductsPage/CTAButton | 예약 가능한 시간 보기 클릭 | App |

### 레퍼럴

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| Open/ReferralModal | 레퍼럴 모달 오픈 | App |
| Click/ReferralModal/CTAButton | 레퍼럴 CTA 클릭 | App |
| Event/ReferralModal/Share/Success | 공유 성공 | App |
| View/ReferralLandingPage | 레퍼럴 랜딩 페이지 조회 | App |

### 웰컴 쿠폰 / 첫세차 프로모션

| 이벤트 | 설명 | 플랫폼 |
|--------|------|--------|
| View/WelcomeCouponModal | 웰컴 쿠폰 모달 조회 | App |
| Click/WelcomeCouponModal/CTAButton | 웰컴 쿠폰 CTA 클릭 | App |
| Event/AppFirstWashPromotion/DownloadSuccess | 첫세차 쿠폰 받기 성공 | App |
