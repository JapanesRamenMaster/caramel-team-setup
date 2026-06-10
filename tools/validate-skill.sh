#!/usr/bin/env bash
# 팀 스킬 프론트매터 표준 검증 스크립트
# 사용: ./tools/validate-skill.sh skills/zone-change/SKILL.md

FILE="${1}"
ERRORS=0

if [ -z "$FILE" ]; then
  echo "Usage: validate-skill.sh <path-to-SKILL.md>"
  exit 1
fi

if [ ! -f "$FILE" ]; then
  echo "❌ 파일 없음: $FILE"
  exit 1
fi

check_field() {
  local field="$1"
  local label="$2"
  if ! grep -q "^${field}:" "$FILE" && ! grep -q "^${field}: " "$FILE"; then
    echo "❌ 필수 필드 누락: ${label} (${field}:)"
    ERRORS=$((ERRORS + 1))
  else
    echo "✅ ${label}"
  fi
}

echo "검증 중: $FILE"
echo "---"

if grep -q "^scope: team" "$FILE"; then
  check_field "name" "name"
  check_field "description" "description"
  check_field "scope" "scope"
  check_field "owner" "owner"
  check_field "side-effects" "side-effects"

  if grep -qE "^[[:space:]]+-[[:space:]]+(db-write|notification|slack-send|deploy)" "$FILE"; then
    if ! grep -q "disable-model-invocation: true" "$FILE"; then
      echo "❌ 비가역 side-effect 있음 → disable-model-invocation: true 필수"
      ERRORS=$((ERRORS + 1))
    else
      echo "✅ disable-model-invocation: true (비가역 액션 잠금)"
    fi
  fi
else
  echo "ℹ️  scope: team 아님 — 팀 스킬 표준 검사 생략"
fi

echo "---"
if [ "$ERRORS" -eq 0 ]; then
  echo "✅ 통과"
  exit 0
else
  echo "❌ ${ERRORS}개 오류 발견"
  exit 1
fi
