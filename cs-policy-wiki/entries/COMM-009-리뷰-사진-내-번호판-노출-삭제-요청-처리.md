---
entry_id: COMM-009
title: 리뷰 사진 내 번호판 노출 삭제 요청 처리
category: 고객커뮤니케이션
source_file: 리뷰-내-번호판-노출-사진-삭제-요청-처리-기준.md
source_section: CS 처리 기준 / 내부 처리 절차
last_verified: 2026-06-25
source_content_hash: 50ddf5ffbc091329
---

## 적용 조건 (when_to_use)
고객이 본인이 리뷰에 올린 사진에 번호판 등 개인정보가 노출되어 해당 사진 삭제를 요청하는 경우.

## 비적용 조건 (not_when_to_use)
- ⛔ 고객이 리뷰 텍스트(문구) 수정·삭제를 요청하는 경우 — 이미지 삭제 절차와 다름
- ⛔ 타인(제3자)이 올린 리뷰 사진에 본인 번호판이 노출되었다고 주장하는 경우 — 본 entry는 리뷰 작성자 본인의 요청에만 적용
- ⛔ 번호판 외 다른 사유(사진 품질, 오업로드 등)로 리뷰 사진 삭제를 요청하는 경우 — 적용 조건 재확인 필요

## 처리 방법
1. 채널톡 프로필 또는 고객 메시지에서 예약 ID 확인
2. DB 조회로 이미지 목록 확인 (mysql-query.sh):
```sql
SELECT ri.id, ri.image_url
FROM review r
JOIN review_image ri ON r.id = ri.review_id
WHERE r.reservation_id = {예약ID}
  AND ri.deleted_yn = 0;
```
3. 삭제할 이미지 ID 확인 후 소프트 삭제 (mysql-write.sh 사용):
```sql
UPDATE review_image SET deleted_yn = 1 WHERE id = {이미지ID};
```
이미지가 여러 장이면: WHERE id IN (id1, id2, ...)
4. 별도 슬랙 보고 불필요
5. 처리 완료 후 바로 고객 안내

## 고객 안내 문구
안녕하세요, 카라멜입니다. 요청해 주신 사진을 삭제 처리 완료했습니다. 감사합니다.
