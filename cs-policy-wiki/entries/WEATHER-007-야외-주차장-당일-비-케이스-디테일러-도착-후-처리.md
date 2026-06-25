---
entry_id: WEATHER-007
title: 야외 주차장 + 당일 비 케이스 — 디테일러 도착 후 처리
category: 우천/계절
source_file: 예약-변경취소-요청-대응.md
source_section: 고객이 일정 변경을 요청하는 경우 > 당일 요청 > 야외 주차장 + 당일 비 케이스 > 디테일러 도착 후
last_verified: 2026-06-25
source_content_hash: 3b53ba6251623db5
---

## 적용 조건 (when_to_use)
야외 주차장 환경에서 당일 비가 오는 상황이며, 디테일러가 이미 현장에 도착한 이후인 경우.

## 비적용 조건 (not_when_to_use)
- ⛔ 디테일러가 아직 도착하지 않은 경우 — '야외 주차장 + 당일 비, 도착 전' entry 사용
- ⛔ 실내 주차장 환경에서의 우천 취소 요청 — 우천 당일 취소 일반 entry 사용
- ⛔ 우천이 아닌 고객 단순 변심 취소 — 고객 당일 취소 일반 entry 사용

## 처리 방법
세차 불가 안내 후 철수. 이미 방문을 위해 이동/도착한 상황이므로 무료 취소 불가 안내
#caramel_realtime에 보고

## 주의사항
도착 후이므로 무료 취소 불가. #caramel_realtime 보고 필수.
