---
entry_id: SITE-024
title: 디테일러 지각으로 인한 고객 취소 요청 처리
category: 현장대응
source_file: 예약-변경취소-요청-대응.md
source_section: 지각으로 인해 고객이 취소를 원하는 경우
last_verified: 2026-06-25
source_content_hash: 3b53ba6251623db5
---

## 적용 조건 (when_to_use)
디테일러의 지각으로 인해 고객이 예약 취소를 원하는 경우.

## 비적용 조건 (not_when_to_use)
- ⛔ 고객 사정(변심, 일정 변경 등)으로 취소를 원하는 경우 — 고객 당일 취소 entry 사용
- ⛔ 우천으로 인해 고객이 취소를 원하는 경우 — 우천 당일 취소 entry 사용
- ⛔ 디테일러가 정시에 도착했으나 고객이 취소를 원하는 경우

## 처리 방법
1. 아래 내용을 안내하고 #caramel_realtime에 보고 (지각 이유 포함)
1. 고객에게 두 옵션 중 선택하도록 안내:
  - 예약 취소 후 재예약
  - 예약 취소 후 세차권 환불

## 주의사항
#caramel_realtime 보고 시 지각 이유 반드시 포함
