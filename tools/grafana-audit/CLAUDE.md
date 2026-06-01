# Grafana SQL Audit 프로젝트

## 프로젝트 목적

Caramel(카라멜) 세차 서비스 플랫폼의 Grafana 대시보드에 있는 SQL 쿼리를 전수 점검한다.
`grafana_sql_audit.py` 스크립트로 자동 추출 + 룰 기반 점검을 수행하고,
플래그된 쿼리를 스키마 기준으로 수정한다.

## 핵심 파일

- `grafana_sql_audit.py` — Grafana API로 전체 대시보드 SQL 추출 + 자동 점검 스크립트
- `caramel_de_schema_updated.md` — **DB 스키마 레퍼런스 (필독)**. 모든 쿼리 점검/수정 시 이 파일 기준으로 판단할 것. 테이블명, 컬럼, product_id 분류 등 모두 이 파일에서 확인
- `audit_report.csv` — 스크립트 실행 결과 (플래그 목록)
- `audit_report.txt` — 스크립트 실행 결과 (사람용 요약)

## DB 환경

- MySQL (sql_mode = ONLY_FULL_GROUP_BY)
- DateTime은 UTC 저장 → KST 변환 필요 (INTERVAL 9 HOUR 또는 CONVERT_TZ)
- 실제 테이블명: user → app_user, option → options

## 쿼리 점검 시 반드시 확인할 규칙

1. **완료 상태**: `WASHED`, `REPORT_SENT`만 완료. `COMPLETED`는 미사용. `IN_PROGRESS`는 진행중이지만 status 필터에 포함해도 무방
2. **live_user 필터**: deleted_yn=0, test_yn=0, temp_yn=0 + 블랙리스트 전화번호 제외
3. **구독 여부**: reservation.subscription_id는 98% NULL → subscription 테이블 EXISTS로 판단
4. **reservation_car.confirmed_yn**: 대부분 0이므로 =1 필터 사용 금지
5. **KST 변환**: reservation_datetime 등 날짜 grouping 시 +9시간 변환 필수
6. **detailer_supply_sheet JOIN**: COLLATE utf8mb4_general_ci 필수
7. **매출 집계**: PARTIAL_CANCELED는 amount - IFNULL(cancel_amount, 0)
8. **중앙값**: 슬롯/거리 등 skewed 분포에는 AVG 대신 ROW_NUMBER 기반 median

## 용어 규칙

- **CBR** = Caramel Business Review (대시보드/리포트 전체). "세차당 매출" 지표를 CBR이라 부르지 말 것
- **세차당 매출** = 세차 1회 완료당 매출. 쿼리 주석/파일명에서도 "세차당 매출"로 표기
- 약어/용어를 모를 때 임의로 만들지 말 것

## 패널 생성 스타일 규칙

새 패널 추가 시 **기존 패널의 차트 타입, 레이아웃, 스타일을 그대로 복제**할 것.

- **1쿼리 = 1메트릭 절대 준수** — 결과 컬럼은 정확히 2개(`time` + metric 1개). dummy/보조/multi-share 컬럼 금지. 새 패널/SQL 변경 후 반드시 `python3 grafana-audit/validate_one_metric.py` 실행. 위반 시 split해서 패널 분리.
- **주간(6주)**: barchart, w=8, h=14, x=0 / fixedColor="green", fillOpacity=80, showValue="always"
  - **집계 단위: 주간** — `DATE_SUB(DATE(kst), INTERVAL WEEKDAY(kst) DAY)` 로 주 월요일 기준 GROUP BY
  - 결과 행 수: **6행 정확히** (진행중 주 제외, 직전 완성 6주)
  - **CBR cutoff 필수**: 모든 6w 패널 SQL은 outer wrap (`SELECT * FROM (...) cbr_cutoff_wrap WHERE cbr_cutoff_wrap.<time_col> < 이번_주_월요일`)으로 진행중 주를 제외해야 함. 수요일 CBR에서 "이번 주 월~화 막대만 짧게 찍히는" false drop 방지
  - **시작점 권장**: `INTERVAL 6 WEEK` (cutoff 후에도 6 row 유지). `INTERVAL 5 WEEK` 사용 시 cutoff 적용 후 5 row만 남으므로 권장 안 함
  - 신규 6w 패널 추가 후 또는 일괄 점검 시: `python3 grafana-audit/apply_cbr_cutoff.py apply` 실행 (idempotent)
- **월간(12개월)**: timeseries, w=16, h=14, x=8 / linear, fillOpacity=0, legend hidden
  - **집계 단위: 월간** — `CAST(DATE_FORMAT(kst, '%Y-%m-01') AS DATE)` 로 월 1일 기준 GROUP BY
  - 결과 행 수: 12~13행
  - **⚠️ 절대 주간 집계 사용 금지** — 12m 쿼리에 WEEKDAY 기반 주간 버킷을 쓰면 52개 데이터포인트가 찍혀 timeseries가 깨짐
- 주간+월간 같은 행에 나란히 (8+16=24)
- datasource uid: `fe9zb9udylatcd` (caramel-prod), dataset: `caramel-prod`
- unit은 기본값(None) 사용
- description 필드에 지표 설명 포함
- 복제 원본: Panel 86 (주간 barchart), Panel 87 (월간 timeseries)

## 대시보드 저장 규칙 (절대 준수)

CBR 대시보드 4개 + legacy `ju46j5j`는 모두 **`🔥 팀 대시보드 🔥`** 폴더(`folderUid: eefeyl9nunqiof`)에 속한다. `POST /api/dashboards/db`는 `folderUid` 생략 시 General로 떨어뜨려서 폴더에서 튕긴다 — 매번 같은 실수가 반복됨.

**정책:**
- 대시보드 저장은 **무조건 `grafana_save.py` 헬퍼 사용**. inline urllib `POST /api/dashboards/db` 금지.
- 헬퍼는 (1) `meta.folderUid` 자동 주입, (2) CBR UID는 팀 폴더 아니면 저장 거부, (3) 저장 후 re-fetch로 폴더 유지 검증한다.
- 저장 후 항상 `python3 grafana-audit/grafana_save.py verify` 실행 (exit 0 확인).
- 사용 예: `from grafana_save import fetch, save, create, TEAM_FOLDER_UID`

## 작업 스타일

- 결론 먼저, 근거 뒤에
- 쿼리 수정 시: 수정 포인트 설명 → 확인 → 전체 쿼리 제공 (snippet만 주지 말 것)
- 한국어로 소통
