## 데이터 분석/CBR 작업 추가 규칙

### 주요 업무
- CBR(Caramel Business Review) 대시보드용 분석 쿼리 생성/수정
- Grafana 패널 추가/삭제/리뷰
- 메트릭 정의 변경 시 cache 테이블 재생성

### 자주 쓰는 명령
- `/cbr-query` — CBR 쿼리 생성 (인터뷰→참조→생성→검증→학습 5단계). 6주(주간 barchart) + 12개월(월간 timeseries) 둘 다 자동 생성
- `/data-learn` — DB 작업 후 새 발견을 QUERY_REFERENCE.md / DB_SCHEMA.md에 반영

### CBR 작업 시 핵심 원칙

1. **1쿼리=1메트릭**: 패널 SQL 결과 컬럼은 정확히 2개 (time + 1 metric). 위반 시 `python3 ~/caramel-claude/tools/grafana-audit/validate_one_metric.py` 빨간 경고. multi-series 의도면 패널 description에 `[multi-series ok]` 마커 추가
2. **6w cutoff 필수**: 모든 6주 패널은 outer wrap (`cbr_cutoff_wrap`)으로 진행중 주 제외. 신규 패널 추가 후 `python3 ~/caramel-claude/tools/grafana-audit/apply_cbr_cutoff.py apply`
3. **6w + 12m 둘 다**: 메트릭 추가 시 둘 다 만들기. 기간은 묻지 말 것
4. **무거운 메트릭은 cache**: JSON_TABLE 등 5초+ 걸리는 메트릭은 daily snapshot 테이블화 (예시: `cbr_daily_revenue_snapshot`, `cbr_cohort_repurchase_snapshot`, `cbr_daily_time_compliance_snapshot`)

### CBR 4개 대시보드 UID

| 대시보드 | UID |
|---|---|
| 톱레벨 | `7039d06f-e206-4a06-99bc-b215451176b0` |
| 마케팅 drill-down | `7a3999a7-7df7-4cc8-94f1-09a7885d9fc1` |
| 제품 drill-down | `488a461e-1d76-4de1-b332-e1ae74337171` |
| 오토랩 drill-down | `c0151105-1e38-40b6-a080-b58594bf2c02` |

### 도구 위치 (~/caramel-claude/tools/grafana-audit/)

- `validate_one_metric.py` — 1쿼리=1메트릭 검증 (전체 178+ 패널 ~1분)
- `apply_cbr_cutoff.py apply` — 신규 패널에 cutoff 일괄 적용
- `weekly_cbr_health.sh` — 주간 점검 (cache freshness, validation, connection 에러)
- `caramel_de_schema_updated.md` — DB 스키마 레퍼런스 (필독)
- `CLAUDE.md` — Grafana audit 작업 규칙
- `cbr-queries/` — 생성된 SQL 모음 (재사용)

### 환경 변수 필요

`~/caramel-claude/.env`에 `GRAFANA_TOKEN=glsa_...` 추가 (#claude-setup 채널에서 토큰 받기). 이 토큰 없으면 validate/apply 스크립트 동작 안 함.

### 주의사항

- **prod schema 변경 (CREATE TABLE / CREATE INDEX) 금지** — CPO에게 요청
- cache 테이블 INSERT/UPDATE는 Apps Script `SyncCbrCache`가 daily 자동 처리. 수동 backfill은 CPO에게 요청
- Grafana dashboard 변경 시 사용자 컨펌 받기 (다른 팀원이 보고 있을 수 있음)
