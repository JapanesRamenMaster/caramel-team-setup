---
name: smoke-test-skill
description: |
  카라멜 스킬 카탈로그 E2E 스모크 테스트용 임시 스킬. 예약 목록을 DB에서 조회한 뒤 결과를 슬랙으로 전송한다.
  Use when: "스모크 테스트", "스킬 카탈로그 테스트", "smoke test".
scope: team
owner: juseong
side-effects:
  - db-read
  - slack-send
disable-model-invocation: true
tags:
  - 테스트
  - 예약
---

# /smoke-test-skill

카라멜 스킬 카탈로그 E2E 스모크 테스트용 임시 스킬.

## 사용법
/smoke-test-skill

## 동작
예약 목록을 DB에서 조회하고 결과를 슬랙에 전송한다.
