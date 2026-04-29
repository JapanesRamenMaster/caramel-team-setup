#!/bin/bash
# CBR 주간 점검 — 매주 1회 (수요일 CBR 전 또는 월요일 아침)
#
# 점검 항목:
#   1. cache 테이블 freshness (어제 데이터 있는지)
#   2. 1쿼리=1메트릭 원칙 위반 패널
#   3. DB connection 에러 추세
#
# Usage:
#   bash grafana-audit/weekly_cbr_health.sh

set -u
ROOT="/Users/trive/claude"
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d)

echo "================================"
echo "CBR Weekly Health Check"
echo "Today: $TODAY"
echo "================================"

echo ""
echo "## 1. Cache freshness (어제까지 적재됐어야 함: $YESTERDAY)"
"$ROOT/mysql-query.sh" "
SELECT 'airbridge_install' AS cache_table, MAX(event_date) AS latest_date FROM airbridge_daily_install
UNION ALL SELECT 'revenue', MAX(date) FROM cbr_daily_revenue_snapshot
UNION ALL SELECT 'cohort', MAX(cohort_week) FROM cbr_cohort_repurchase_snapshot
UNION ALL SELECT 'time_compliance', MAX(date) FROM cbr_daily_time_compliance_snapshot
"

echo ""
echo "## 2. 1쿼리=1메트릭 검증"
python3 "$ROOT/grafana-audit/validate_one_metric.py" 2>&1 | tail -5

echo ""
echo "## 3. DB Connection 에러 추세 (모두 0이어야 정상)"
"$ROOT/mysql-query.sh" "SHOW STATUS WHERE Variable_name IN ('Aborted_connects','Aborted_clients','Connection_errors_max_connections','Connection_errors_internal','Threads_connected','Max_used_connections')"

echo ""
echo "## 4. Cache 데이터 정합성 (sample row)"
"$ROOT/mysql-query.sh" "
SELECT date, total_revenue, completed_washes
FROM cbr_daily_revenue_snapshot
ORDER BY date DESC LIMIT 3
"

echo ""
echo "================================"
echo "✅ 점검 완료"
echo "================================"
echo ""
echo "[다음 액션 가이드]"
echo "- 1번 cache freshness가 어제 날짜 아니면 → SyncCbrCache trigger 작동 확인"
echo "- 2번 violations > 0이면 → 새 패널 추가됐는지 확인 후 fix"
echo "- 3번 errors가 늘었다면 → DB 연결 문제 시작 신호"
