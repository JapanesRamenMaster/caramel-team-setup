#!/usr/bin/env python3
"""안전 액션 레이어 하트비트 시트 1회 생성 (메인테이너 전용).

- 맹주성 Drive에 스프레드시트 생성(impersonation)
- 탭: heartbeat(원시 로그), 현황판(수식 자동 갱신)
- 서비스 계정에 editor 공유 → 팀원 머신은 SA 단독으로 append
- 현황판 수식 주입 후 SHEET_ID 출력
"""
import warnings; warnings.filterwarnings('ignore')
from google.oauth2 import service_account
from googleapiclient.discovery import build

KEY = '/Users/trive/.claude/google-sheets-key.json'
SUBJECT = 'juseong.maeng@thetrive.com'
SA_EMAIL = 'claude-sheets@modern-crane-488415-p6.iam.gserviceaccount.com'

creds = service_account.Credentials.from_service_account_file(
    KEY, scopes=['https://www.googleapis.com/auth/spreadsheets',
                 'https://www.googleapis.com/auth/drive']).with_subject(SUBJECT)
sheets = build('sheets', 'v4', credentials=creds)
drive = build('drive', 'v3', credentials=creds)

# 1) 스프레드시트 생성 (탭 2개)
ss = sheets.spreadsheets().create(body={
    'properties': {'title': '카라멜 팀 안전세팅 현황'},
    'sheets': [
        {'properties': {'title': 'heartbeat'}},
        {'properties': {'title': '현황판'}},
    ],
}).execute()
sid = ss['spreadsheetId']
print('SHEET_ID =', sid)

# 2) heartbeat 헤더
sheets.spreadsheets().values().update(
    spreadsheetId=sid, range="heartbeat!A1:H1", valueInputOption='RAW',
    body={'values': [['ts_kst', 'date_kst', 'name', 'host',
                      'version', 'gate', 'reasons', 'session_id']]}).execute()

# 3) 현황판 수식 (USER_ENTERED → 수식으로 들어감)
dash = [
    ['=CONCATENATE("카라멜 팀 안전세팅 현황 — 오늘 활성 ", '
     'COUNTIF(A3:A,"🟢")+COUNTIF(A3:A,"🔴"), "명 / 정상 ", '
     'COUNTIF(A3:A,"🟢"), " · 주의 ", COUNTIF(A3:A,"🔴"), "  (자동 갱신)")'],
    ['상태', '팀원', '최근 하트비트(KST)', '버전', '게이트', '사유'],
    # ⚠️ heartbeat 행 범위는 절대참조($C$2:...)로. 상대참조면 셀 위치 기준으로 행이 밀려
    #    데이터를 못 읽고 #N/A가 난다(2026-06-17 수정). 전체열 참조도 $A:$A로 고정.
    ['=BYROW(B3:B, LAMBDA(p, IF(p="","", LET(last, MAXIFS(heartbeat!$A:$A,heartbeat!$C:$C,p), '
     'st, IFERROR(VLOOKUP(last, SORT(FILTER({heartbeat!$A:$A,heartbeat!$F:$F},heartbeat!$C:$C=p),1,FALSE),2,FALSE),""), '
     'IF(INT(last)=TODAY(), IF(st="PASS","🟢","🔴"), "⚪")))))',
     # 전체열 참조(행번호 X) — API 단일셀 쓰기가 행을 밀어 #N/A 내는 것 방지. 헤더 "name" 제외.
     # IFERROR("") — 하트비트 0행일 때 FILTER #N/A가 전 칸에 번지는 것 방지(빈 상태=깔끔).
     '=IFERROR(SORT(UNIQUE(FILTER(heartbeat!$C:$C, heartbeat!$C:$C<>"", heartbeat!$C:$C<>"name"))), "")',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", TEXT(MAXIFS(heartbeat!$A:$A,heartbeat!$C:$C,p),"yyyy-mm-dd hh:mm"))))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", IFERROR(VLOOKUP(MAXIFS(heartbeat!$A:$A,heartbeat!$C:$C,p), '
     'SORT(FILTER({heartbeat!$A:$A,heartbeat!$E:$E},heartbeat!$C:$C=p),1,FALSE),2,FALSE),""))))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", IFERROR(VLOOKUP(MAXIFS(heartbeat!$A:$A,heartbeat!$C:$C,p), '
     'SORT(FILTER({heartbeat!$A:$A,heartbeat!$F:$F},heartbeat!$C:$C=p),1,FALSE),2,FALSE),""))))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", IFERROR(VLOOKUP(MAXIFS(heartbeat!$A:$A,heartbeat!$C:$C,p), '
     'SORT(FILTER({heartbeat!$A:$A,heartbeat!$G:$G},heartbeat!$C:$C=p),1,FALSE),2,FALSE),""))))'],
]
sheets.spreadsheets().values().update(
    spreadsheetId=sid, range="현황판!A1", valueInputOption='USER_ENTERED',
    body={'values': dash}).execute()

# 4) 서비스 계정에 editor 공유 (팀원 머신 SA 단독 append용)
drive.permissions().create(
    fileId=sid, sendNotificationEmail=False,
    body={'type': 'user', 'role': 'writer', 'emailAddress': SA_EMAIL}).execute()

print('현황판 URL: https://docs.google.com/spreadsheets/d/%s/edit#gid=현황판' % sid)
print('완료. 위 SHEET_ID를 safe-action/config.json HEARTBEAT_SHEET_ID 에 넣으세요.')
