#!/bin/bash
# build-claude-md.sh — work/CLAUDE.md 를 repo 베이스로 (재)조립한다.
#
# 왜 있나: setup.sh(최초)와 update.sh(매 업데이트)가 똑같은 로직으로 CLAUDE.md를
#   만들어야 베이스 규칙 개선이 팀원에게 전파된다. 한 곳에 모아 drift를 없앤다.
#
# 보존 규칙:
#   - 관리 영역은 <!-- TEAM-SETUP:BEGIN --> ~ <!-- TEAM-SETUP:END --> 마커로 감싼다.
#   - 마커 바깥(개인 메모 등)과 날짜 섹션은 그대로 보존한다.
#   - 마커가 없는 기존(legacy) 파일은 .bak로 백업 후 새로 만든다(손실 0).
#   - 역할은 .setup-config의 ROLE에서 가져와 보존한다.
#
# 사용: build-claude-md.sh <INSTALL_DIR> <WORK_DIR> <ROLE>

set -u

INSTALL_DIR="${1:?INSTALL_DIR 필요}"
WORK_DIR="${2:?WORK_DIR 필요}"
ROLE="${3:-}"

BASE="$INSTALL_DIR/CLAUDE.md"
OUT="$WORK_DIR/CLAUDE.md"
BEGIN="<!-- TEAM-SETUP:BEGIN — 이 블록은 자동 생성됨. 편집 금지(업데이트 시 덮어씀). 개인 메모는 END 마커 아래에. -->"
END="<!-- TEAM-SETUP:END -->"

[ -f "$BASE" ] || { echo "ERROR: $BASE 없음"; exit 1; }
mkdir -p "$WORK_DIR"

# --- 1) 관리 블록 본문 조립 (임시 파일) ---
BLOCK="$(mktemp)"
rolefile=""   # ROLE 이 비어도 아래 코드 레포 분기에서 참조하므로 여기서 초기화 (set -u)
{
  cat "$BASE"

  # 역할 섹션
  if [ -n "$ROLE" ]; then
    printf '\n## 이 사용자의 역할\n이 사용자는 카라멜 팀에서 **%s** 역할을 맡고 있습니다. 이 역할에 맞게 답변을 조정하세요.\n' "$ROLE"
    # 역할별 추가 규칙 파일 (alias 매핑)
    rl="$(printf '%s' "$ROLE" | tr '[:upper:]' '[:lower:]')"
    rolefile=""
    case "$rl" in
      cs) rolefile="cs" ;;
      마케팅|marketing) rolefile="marketing" ;;
      운영|operations) rolefile="operations" ;;
      데이터|분석|data|data-analyst|데이터분석) rolefile="data-analyst" ;;
      개발|개발자|엔지니어|dev|developer|engineer) rolefile="dev" ;;
      *) [ -f "$INSTALL_DIR/roles/$rl.md" ] && rolefile="$rl" ;;
    esac
    if [ -n "$rolefile" ] && [ -f "$INSTALL_DIR/roles/$rolefile.md" ]; then
      printf '\n'; cat "$INSTALL_DIR/roles/$rolefile.md"
    fi
  fi

  # 코드 레포 섹션 (항상 포함 — 어디서 코드를 찾는지 안내)
  cat << 'REPOEOF'

## 코드 레포

리팩토링으로 **고객 앱은 caramel-zero**, **디테일러앱/어드민은 caramel-all** 로 분리되어 있어. 코드 질문이 오면 아래 매핑에 따라 올바른 레포부터 검색할 것.

### `repos/caramel-zero/` — 신규 고객 앱 (Turborepo)
- `apps/customer-app/` — 고객 모바일 앱 (React Native / Expo)
- `apps/web/` — 고객 웹
- `apps/api/` — 고객 앱 API
- `packages/` — 공용 패키지 (date-common, refund-common, typescript-config)
- 고객 앱·웹·API 관련 질문은 **여기를 먼저 검색**

### `repos/caramel-all/` — 어드민/디테일러 (모노레포)
- `caramel-detailer-app/` — 디테일러 앱
- `caramel-sales-admin/` — 영업 어드민
- 그 외 서브모듈(`caramel-app`, `caramel-api`, `careplus-web`)은 리팩토링 이전 코드 — 참조용으로만 보고, 현행 동작 확인이 필요하면 caramel-zero를 우선

### 공통 규칙
REPOEOF

  # 코드 수정 권한은 역할에 따라 갈린다 (dev 역할만 쓰기 가능)
  if [ "$rolefile" = "dev" ]; then
    printf -- '- 코드 수정·PR은 위 "개발 작업 추가 규칙"의 절차를 따를 것\n'
  else
    printf -- '- 코드는 **읽기 전용**. 절대 수정하지 말 것\n'
  fi
  printf -- '- 어느 레포를 봐야 할지 불확실하면 사용자에게 먼저 확인\n'
} > "$BLOCK"

# --- 2) 기존 파일에서 보존할 개인 메모 추출 (END 마커 ~ DATE_MARKER 사이) ---
# 날짜 섹션은 항상 맨 끝에 새로 붙이므로 여기선 제외한다 (update.sh 날짜 갱신과 충돌 방지).
PERSONAL="$(mktemp)"
: > "$PERSONAL"
if [ -f "$OUT" ] && grep -qF "$END" "$OUT"; then
  # END 다음 줄부터 끝까지 → 그중 DATE_MARKER 이후는 잘라냄
  awk -v end="$END" 'found{print} index($0,end){found=1}' "$OUT" \
    | awk '/<!-- DATE_MARKER -->/{exit} {print}' > "$PERSONAL"
elif [ -f "$OUT" ]; then
  # legacy(마커 없음) → 통째로 백업하고 안내 (손실 0)
  cp "$OUT" "$OUT.pre-rebuild.bak"
  echo "  CLAUDE.md: 마커 없는 기존본 → $OUT.pre-rebuild.bak 로 백업 (개인 메모가 있었다면 END 마커 아래로 옮기세요)" >&2
fi
# 개인 메모 앞뒤 빈 줄 정리 (전부 공백이면 비움)
if ! grep -q '[^[:space:]]' "$PERSONAL" 2>/dev/null; then : > "$PERSONAL"; fi

# --- 3) 최종 조립: [마커]관리블록[마커] + 개인메모 + 날짜(항상 맨 끝) ---
{
  echo "$BEGIN"
  cat "$BLOCK"
  echo "$END"
  if [ -s "$PERSONAL" ]; then printf '\n'; cat "$PERSONAL"; fi
  printf '\n<!-- DATE_MARKER -->\n## 현재 날짜\n오늘은 %s입니다. 날짜 관련 질문이나 쿼리에서 이 날짜를 기준으로 하세요.\n' "$(date '+%Y년 %m월 %d일')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

rm -f "$BLOCK" "$PERSONAL"
