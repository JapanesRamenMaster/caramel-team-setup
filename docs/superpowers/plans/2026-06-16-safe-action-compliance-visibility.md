# 안전 액션 레이어 — 준수 가시성(하트비트 + 세팅 게이트 + 현황판) 구현 플랜

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 팀원이 세팅이 깨진 채로는 Claude로 작업을 시작조차 못 하게 막고(차단형 게이트), 정상 세션은 매번 중앙 시트에 하트비트를 남겨, 메인테이너가 아침에 시트 한 장으로 전원 안전 상태(🟢/⚪/🔴)를 확인할 수 있게 한다.

**Architecture:** SessionStart 훅은 세션을 차단할 수 없으므로(context-only), 게이트를 2단으로 나눈다 — (1) `gate.sh`가 SessionStart에서 `update.sh`(자가복구) **다음에** 돌며 세팅 자가체크 결과를 상태 마커 파일에 쓰고 하트비트를 시트에 append, (2) `enforce.py`가 PreToolUse(모든 툴)에서 그 마커를 읽어 FAIL이면 모든 도구 호출을 deny. 하트비트는 외부 라이브러리 의존 없이 node 빌트인(`crypto`+`https`)으로 서비스 계정 JWT를 직접 발급해 Google Sheets API에 쓴다(팀원 머신에 google-auth python이 없어도 동작). 현황판은 같은 시트의 수식 기반 탭으로 자동 갱신된다. 모든 신규 스크립트는 team-setup 레포에 두고 `update.sh`가 전파·자가복구한다(구성요소 #5 확장).

**Tech Stack:** bash(SessionStart 훅 `gate.sh`, `update.sh`), Python 3(PreToolUse 훅 `enforce.py`, 메인테이너 1회 셋업 `setup-sheet.py`), Node.js 빌트인 only(`heartbeat.js` — `crypto`/`https`, 외부 패키지 0), Google Sheets API v4 + 서비스 계정(`~/.claude/google-sheets-key.json`).

---

## 배경 / 사전 확인된 사실

- 상위 설계: `docs/superpowers/specs/2026-06-16-safe-action-layer-design.md` (머지됨, main 375c9b8). 이 플랜은 그 6개 구성요소 중 **#6(준수 가시성) + #5(전파)의 #6용 확장**만 다룬다. #1·#2(가드 대안유도), #4(요청 큐)는 별도 플랜.
- **훅 메커니즘(claude-code-guide 확인, 2026-06-16):**
  - SessionStart 훅은 세션 시작을 **차단할 수 없다**(어떤 exit code도 비차단, `permissionDecision` 필드 없음). `additionalContext`(plain stdout)만 모델 컨텍스트에 system-reminder로 삽입.
  - PreToolUse 훅은 **exit 0 + stdout JSON** `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}` 로 도구 호출을 차단하고, reason이 모델에 전달된다.
  - PreToolUse에서 모든 툴 매칭: `"matcher": ""`(빈 문자열) = `"*"` = 생략, 셋 다 동일.
  - 공식 문서: https://code.claude.com/docs/en/hooks.md
- **저장소 결정(맹주성, 2026-06-16):** 하트비트 = Google Sheet 한 장. 현황판 = 같은 시트의 `현황판` 탭(수식 자동 갱신). (Vercel/Slack 안 씀.)
- **시트 쓰기 경로:** 서비스 계정 키 `~/.claude/google-sheets-key.json`(`client_email: claude-sheets@modern-crane-488415-p6.iam.gserviceaccount.com`)는 `update.sh` v4 마이그레이션이 팀원 머신에 이미 내려준다. SA **단독(impersonation 없이)**으로 쓰되, 대상 시트를 SA 이메일에 editor로 공유한다(팀원이 전부 맹주성으로 기록되는 것 방지 + DWD readonly-scope 트랩 회피).
- **현재 SessionStart 훅 순서**(`~/.claude/settings.json`): `[update.sh, sync-caramel-prod.sh]`. `gate.sh`는 반드시 `update.sh` **뒤**에 와야 한다(복구가 먼저 일어나야 게이트가 오탐을 안 냄).
- **node**: 메인테이너 v22. `heartbeat.js`는 `fetch` 대신 `https` 빌트인을 써서 node 버전 의존을 없앤다.
- **선결 과제(이 플랜 밖, 별도 처리):** team-setup 레포 org 이관 `JapanesRamenMaster`(개인) → `the-trive`. 현재 origin이 개인 계정이라 팀 공급망이 개인 종속. 본 플랜은 현 origin 기준으로 진행 가능하나, 이관 후 SSH/PAT 경로 점검 필요.

## 파일 구조

신규/수정 파일과 각자의 책임:

| 파일 | 종류 | 책임 |
|---|---|---|
| `safe-action/config.json` | 신규(레포, 전파) | 하트비트 시트 ID + 마커/escape 파일 경로 등 설정 한 곳 |
| `safe-action/heartbeat.js` | 신규(레포, 전파) | node 빌트인만으로 SA JWT 발급 → Sheets `values:append`. best-effort, 항상 exit 0 |
| `safe-action/gate.sh` | 신규(레포, 전파) | SessionStart: 세팅 자가체크 → 마커 파일 기록 → `heartbeat.js` 호출 → 요약 stdout |
| `safe-action/enforce.py` | 신규(레포, 전파) | PreToolUse(전체): 마커 FAIL → 모든 도구 deny. escape 파일 있으면 통과 |
| `safe-action/setup-sheet.py` | 신규(레포, 메인테이너 1회) | 하트비트 시트+`heartbeat`/`현황판` 탭 생성, SA에 editor 공유, 현황판 수식 주입, SHEET_ID 출력 |
| `update.sh` | 수정 | 섹션 7 `ensure_hook` 확장: `gate.sh` SessionStart + `enforce.py` PreToolUse 등록·자가복구. `LATEST_VERSION` 6→7 |
| `team-diagnose.sh` | 수정 | `LATEST_VERSION` 7 동기화 + 안전 액션 훅/마커 점검 항목 추가 |

런타임 상태 파일(레포 아님, 머신 로컬):
- `~/.claude/.safe-action-gate-state` — 게이트 결과 마커(JSON). 매 SessionStart 갱신.
- `~/.claude/.safe-action-gate-disable` — 존재 시 enforce 통과(메인테이너 긴급 escape hatch = spec의 "빠른 예외요청 경로").

## 범위 밖 (이 플랜에서 안 함)

- 가드 훅에 "차단 + 대안 유도"(#1·#2), incoming 요청 큐 연결(#4) — 별도 플랜.
- db/git-guardrail 등 가드레일의 팀원 전파 — 별도 작업. 게이트의 자가체크는 **안전 액션 체인 자신의 무결성 + 버전**만 검사한다(우리가 지금 전파를 통제하는 대상).
- Slack 슬래시 커맨드(`/팀세팅현황`) — 시트 탭으로 충분, 추후.

---

### Task 1: 하트비트 시트 생성 (메인테이너 1회 셋업)

**Files:**
- Create: `safe-action/setup-sheet.py`

> 이 태스크는 메인테이너(맹주성) 머신에서 1회 실행한다. 팀원 머신은 실행하지 않는다. 산출물 SHEET_ID는 Task 2의 `config.json`에 박는다.

- [ ] **Step 1: `setup-sheet.py` 작성**

```python
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
    ['=BYROW(B3:B, LAMBDA(p, IF(p="","", LET(last, MAXIFS(heartbeat!A:A,heartbeat!C:C,p), '
     'st, IFERROR(VLOOKUP(last, SORT(FILTER({heartbeat!A:A,heartbeat!F:F},heartbeat!C:C=p),1,FALSE),2,FALSE),""), '
     'IF(INT(last)=TODAY(), IF(st="PASS","🟢","🔴"), "⚪")))))',
     '=SORT(UNIQUE(FILTER(heartbeat!C2:C100000, heartbeat!C2:C100000<>"")))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", MAXIFS(heartbeat!A:A,heartbeat!C:C,p))))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", IFERROR(VLOOKUP(MAXIFS(heartbeat!A:A,heartbeat!C:C,p), '
     'SORT(FILTER({heartbeat!A:A,heartbeat!E:E},heartbeat!C:C=p),1,FALSE),2,FALSE),""))))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", IFERROR(VLOOKUP(MAXIFS(heartbeat!A:A,heartbeat!C:C,p), '
     'SORT(FILTER({heartbeat!A:A,heartbeat!F:F},heartbeat!C:C=p),1,FALSE),2,FALSE),""))))',
     '=BYROW(B3:B, LAMBDA(p, IF(p="","", IFERROR(VLOOKUP(MAXIFS(heartbeat!A:A,heartbeat!C:C,p), '
     'SORT(FILTER({heartbeat!A:A,heartbeat!G:G},heartbeat!C:C=p),1,FALSE),2,FALSE),""))))'],
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
```

- [ ] **Step 2: 실행해서 시트 생성 + SHEET_ID 확보**

Run: `python3 safe-action/setup-sheet.py`
Expected: `SHEET_ID = <44자 내외 ID>` 출력, 에러 없음. (실패 시 reference_google_sheets_read의 DWD/impersonation 트랩 점검 — scope에 readonly 넣지 말 것.)

- [ ] **Step 3: 시트 직접 확인**

브라우저로 출력된 URL 열어서: `heartbeat` 탭에 헤더 8칸, `현황판` 탭에 제목/헤더 행이 보이고 수식이 `#REF`/`#ERROR` 없이 빈 표로 렌더되는지 확인(데이터가 아직 없으니 표는 비어 있는 게 정상). 파일 공유 설정에 SA 이메일이 편집자로 있는지 확인.

- [ ] **Step 4: Commit (setup-sheet.py만; SHEET_ID는 Task 2에서)**

```bash
git add safe-action/setup-sheet.py
git commit -m "feat(safe-action): 하트비트 시트 1회 셋업 스크립트"
```

---

### Task 2: 설정 파일 (config.json)

**Files:**
- Create: `safe-action/config.json`

- [ ] **Step 1: config.json 작성** (Task 1에서 얻은 실제 SHEET_ID로 `PASTE_SHEET_ID` 치환)

```json
{
  "HEARTBEAT_SHEET_ID": "PASTE_SHEET_ID",
  "HEARTBEAT_TAB": "heartbeat",
  "SA_KEY_PATH": "~/.claude/google-sheets-key.json",
  "GATE_STATE_FILE": "~/.claude/.safe-action-gate-state",
  "GATE_DISABLE_FILE": "~/.claude/.safe-action-gate-disable",
  "LATEST_VERSION": 7
}
```

- [ ] **Step 2: 유효성 확인**

Run: `python3 -c "import json; print(json.load(open('safe-action/config.json'))['HEARTBEAT_SHEET_ID'])"`
Expected: 실제 SHEET_ID 출력(‘PASTE_SHEET_ID’가 아님).

- [ ] **Step 3: Commit**

```bash
git add safe-action/config.json
git commit -m "feat(safe-action): 하트비트/게이트 설정 파일"
```

---

### Task 3: 하트비트 라이터 (heartbeat.js — node 빌트인 only)

**Files:**
- Create: `safe-action/heartbeat.js`
- Test: 임시 실행 + 시트 read-back

- [ ] **Step 1: heartbeat.js 작성**

인자: `node heartbeat.js <name> <host> <version> <gate> <reasons> <session_id>`. 설정은 같은 디렉터리 `config.json`에서 읽는다. 실패해도 절대 비정상 종료하지 않는다(세션 차단 금지).

```javascript
#!/usr/bin/env node
// 안전 액션 레이어 하트비트 라이터.
// node 빌트인(crypto, https, fs)만 사용 — 팀원 머신에 외부 패키지/ google-auth 없어도 동작.
// 서비스 계정 JWT(RS256)를 직접 발급해 Google Sheets values:append. best-effort, 항상 exit 0.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const https = require('https');

function expand(p) { return p.replace(/^~/, process.env.HOME); }
function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function post(host, pathName, headers, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      { host, path: pathName, method: 'POST', headers, timeout: 5000 },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve({ status: res.statusCode, body: data }));
      });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
}

async function main() {
  const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));
  const key = JSON.parse(fs.readFileSync(expand(cfg.SA_KEY_PATH), 'utf8'));
  const [name, host, version, gate, reasons, sessionId] = process.argv.slice(2);

  // 1) JWT 발급 (SA 단독, impersonation 없음)
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64url(JSON.stringify({
    iss: key.client_email,
    scope: 'https://www.googleapis.com/auth/spreadsheets',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now, exp: now + 3600,
  }));
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(`${header}.${claim}`);
  const sig = b64url(signer.sign(key.private_key));
  const jwt = `${header}.${claim}.${sig}`;

  // 2) access token
  const form = `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}` +
    `&assertion=${jwt}`;
  const tok = await post('oauth2.googleapis.com', '/token',
    { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(form) },
    form);
  const accessToken = JSON.parse(tok.body).access_token;
  if (!accessToken) throw new Error('no access_token: ' + tok.body);

  // 3) KST 타임스탬프
  const kst = new Date(Date.now() + 9 * 3600 * 1000).toISOString(); // ...T09:12:34.000Z
  const ts = kst.slice(0, 10) + ' ' + kst.slice(11, 19);  // "2026-06-16 09:12:34"
  const dateKst = kst.slice(0, 10);

  // 4) values:append (USER_ENTERED → ts가 datetime으로 파싱됨)
  const range = encodeURIComponent(`${cfg.HEARTBEAT_TAB}!A:H`);
  const apiPath = `/v4/spreadsheets/${cfg.HEARTBEAT_SHEET_ID}/values/${range}` +
    `:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS`;
  const payload = JSON.stringify({
    values: [[ts, dateKst, name || '', host || '', version || '',
              gate || '', reasons || '', sessionId || '']],
  });
  const ap = await post('sheets.googleapis.com', apiPath,
    { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload) },
    payload);
  if (ap.status >= 300) throw new Error('append failed: ' + ap.status + ' ' + ap.body);
}

main().catch((e) => {
  // best-effort: 기록 실패가 세션을 막아선 안 됨. stderr만 남기고 정상 종료.
  process.stderr.write('[heartbeat] skip: ' + (e && e.message) + '\n');
}).finally(() => process.exit(0));
```

- [ ] **Step 2: 실패해도 exit 0인지 먼저 검증 (잘못된 시트 ID로)**

Run:
```bash
node safe-action/heartbeat.js "테스트" "$(hostname)" 7 PASS "" "test-session"; echo "exit=$?"
```
Expected: `exit=0` (시트 ID가 실제면 행이 들어가고, 가짜/네트워크 실패여도 `[heartbeat] skip:` 후 `exit=0`).

- [ ] **Step 3: 실제 append 확인 (Task 1/2 완료 후 실제 SHEET_ID로)**

Run: 위 명령 1회 실행 후, 시트 read-back으로 마지막 행 확인:
```bash
python3 -c "
import warnings; warnings.filterwarnings('ignore')
from google.oauth2 import service_account
from googleapiclient.discovery import build
import json
cfg=json.load(open('safe-action/config.json'))
c=service_account.Credentials.from_service_account_file('/Users/trive/.claude/google-sheets-key.json',scopes=['https://www.googleapis.com/auth/spreadsheets'])
s=build('sheets','v4',credentials=c)
r=s.spreadsheets().values().get(spreadsheetId=cfg['HEARTBEAT_SHEET_ID'],range='heartbeat!A:H').execute()
print(r['values'][-1])
"
```
Expected: 마지막 행 = `['2026-06-16 HH:MM:SS', '2026-06-16', '테스트', '<host>', '7', 'PASS', '', 'test-session']`. (이 read-back은 SA 단독 — Task 1의 editor 공유가 됐는지도 함께 검증된다.)

- [ ] **Step 4: 테스트 행 삭제 + Commit**

테스트로 넣은 행은 시트에서 수동 삭제. 그 후:
```bash
git add safe-action/heartbeat.js
git commit -m "feat(safe-action): node 빌트인 하트비트 라이터"
```

---

### Task 4: 세팅 게이트 (gate.sh — SessionStart)

**Files:**
- Create: `safe-action/gate.sh`
- Test: 정상/깨진 settings.json 시뮬레이션

게이트 자가체크 = **안전 액션 체인 자신의 무결성 + 버전**. update.sh가 SessionStart에서 먼저 돌며 자가복구하므로, gate.sh가 그 뒤에서 재검사해 *그래도* 깨졌으면 FAIL.

기준(전부 만족해야 PASS):
1. `~/caramel-claude/.setup-config`의 `SETUP_VERSION` == config.json의 `LATEST_VERSION`(7)
2. `~/.claude/settings.json`에 `caramel-team-setup/update.sh` 훅 등록
3. 같은 파일에 `safe-action/gate.sh` 훅 등록
4. 같은 파일에 `safe-action/enforce.py` 훅 등록

- [ ] **Step 1: gate.sh 작성**

```bash
#!/bin/bash
# 안전 액션 레이어 세팅 게이트 (SessionStart, update.sh 뒤에 실행).
# 세팅 자가체크 → 마커 파일 기록 → 하트비트 append → 요약 출력.
# SessionStart는 세션을 차단 못 하므로, 실제 차단은 enforce.py(PreToolUse)가 이 마커를 읽어 수행.
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SA_DIR="$INSTALL_DIR/safe-action"
WORK_DIR="$HOME/caramel-claude"
CONFIG_FILE="$WORK_DIR/.setup-config"
SETTINGS_FILE="$HOME/.claude/settings.json"

# config.json에서 값 읽기 (python3로 안전 파싱)
read_cfg() { python3 -c "import json;print(json.load(open('$SA_DIR/config.json')).get('$1',''))" 2>/dev/null; }
STATE_FILE=$(read_cfg GATE_STATE_FILE); STATE_FILE="${STATE_FILE/#\~/$HOME}"
LATEST_VERSION=$(read_cfg LATEST_VERSION)
[ -z "$STATE_FILE" ] && STATE_FILE="$HOME/.claude/.safe-action-gate-state"
[ -z "$LATEST_VERSION" ] && LATEST_VERSION=7

reasons=""
add() { reasons="${reasons:+$reasons; }$1"; }

# 1) 버전
cur_ver=$(grep "^SETUP_VERSION=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
[ "${cur_ver:-0}" -lt "$LATEST_VERSION" ] 2>/dev/null && add "버전 stale(v${cur_ver:-?}<v$LATEST_VERSION)"
# 2~4) 훅 등록
grep -q "caramel-team-setup/update.sh" "$SETTINGS_FILE" 2>/dev/null || add "update.sh 훅 미등록"
grep -q "safe-action/gate.sh"          "$SETTINGS_FILE" 2>/dev/null || add "gate.sh 훅 미등록"
grep -q "safe-action/enforce.py"       "$SETTINGS_FILE" 2>/dev/null || add "enforce.py 훅 미등록"

if [ -z "$reasons" ]; then status="PASS"; else status="FAIL"; fi

# 마커 기록 (enforce.py가 읽음)
mkdir -p "$(dirname "$STATE_FILE")"
python3 -c "
import json,sys
json.dump({'status':'$status','reasons':'''$reasons''','version':'${cur_ver:-}'},
          open('$STATE_FILE','w'), ensure_ascii=False)
" 2>/dev/null

# 하트비트 (best-effort; node 없으면 조용히 스킵)
NAME=$(grep "^EMAIL=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
[ -z "$NAME" ] && NAME=$(grep "^ROLE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
[ -z "$NAME" ] && NAME="$USER"
if command -v node >/dev/null 2>&1; then
  node "$SA_DIR/heartbeat.js" "$NAME" "$(hostname)" "${cur_ver:-}" "$status" "$reasons" \
    "${CLAUDE_SESSION_ID:-$$}" 2>/dev/null &
fi

# 요약 (additionalContext로 모델/사용자에 노출)
if [ "$status" = "PASS" ]; then
  echo "[안전세팅] 정상 — 가드 체인 OK, v${cur_ver}. 하트비트 기록됨."
else
  echo "[안전세팅] ⚠️ 깨짐 → 도구 사용이 차단됩니다. 사유: $reasons"
  echo "  복구: 터미널에서  bash ~/.caramel-team-setup/update.sh  실행 후 새 세션."
  echo "  그래도 안 되면  bash ~/.caramel-team-setup/team-diagnose.sh  결과를 맹주성님께."
fi
exit 0
```

- [ ] **Step 2: 정상 케이스 테스트**

전제: 본인 머신이 v7 + 세 훅 등록된 상태(Task 6 적용 후). 임시로 직접 실행:
```bash
bash safe-action/gate.sh; echo "---"; cat ~/.claude/.safe-action-gate-state
```
Expected: `[안전세팅] 정상...` 출력, 마커에 `"status":"PASS"`.

- [ ] **Step 3: 깨진 케이스 테스트 (격리된 임시 settings로)**

```bash
TMP=$(mktemp -d)
echo '{"hooks":{}}' > "$TMP/settings.json"
# gate.sh가 보는 SETTINGS_FILE을 임시로 가리키도록 env 오버라이드는 없으므로,
# 깨짐 판정 로직만 단위 검증: 훅 없는 settings에서 grep이 실패하는지 확인
grep -q "safe-action/enforce.py" "$TMP/settings.json" || echo "DETECT: enforce 미등록 정상 감지"
rm -rf "$TMP"
```
Expected: `DETECT: enforce 미등록 정상 감지` 출력. (gate.sh의 add() 경로가 트리거됨을 확인. 전체 FAIL 통합 검증은 Task 7 E2E에서.)

- [ ] **Step 4: Commit**

```bash
git add safe-action/gate.sh
git commit -m "feat(safe-action): SessionStart 세팅 게이트 + 하트비트 트리거"
```

---

### Task 5: 차단 집행기 (enforce.py — PreToolUse)

**Files:**
- Create: `safe-action/enforce.py`
- Test: 마커 PASS/FAIL/없음/disable 4케이스

- [ ] **Step 1: enforce.py 작성**

```python
#!/usr/bin/env python3
"""PreToolUse(전체 툴) 차단 집행기 — fail-closed.

게이트 마커가 FAIL(또는 없음=게이트 미실행)이면 모든 도구 호출을 deny.
escape 파일이 있으면 통과(메인테이너 긴급 우회).
"""
import json
import os
import sys

HOME = os.path.expanduser("~")
STATE_FILE = os.path.join(HOME, ".claude", ".safe-action-gate-state")
DISABLE_FILE = os.path.join(HOME, ".claude", ".safe-action-gate-disable")

RECOVER = ("터미널에서  bash ~/.caramel-team-setup/update.sh  실행 후 새 세션을 여세요. "
           "그래도 안 되면  bash ~/.caramel-team-setup/team-diagnose.sh  결과를 맹주성님께 전달하세요.")


def allow():
    sys.exit(0)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    # stdin은 소비하되 내용은 불필요 (모든 툴 동일 차단)
    try:
        sys.stdin.read()
    except Exception:
        pass

    # escape hatch
    if os.path.exists(DISABLE_FILE):
        allow()

    # 마커 읽기
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except Exception:
        deny("[안전세팅] 세팅 게이트가 실행되지 않았습니다(마커 없음). "
             "안전 체인이 설치되지 않았거나 깨졌습니다. " + RECOVER)

    if state.get("status") == "PASS":
        allow()

    deny("[안전세팅] 세팅이 깨져 모든 작업이 차단됩니다. 사유: "
         + (state.get("reasons") or "(불명)") + ". " + RECOVER)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: PASS 마커 → 통과**

```bash
echo '{"status":"PASS","reasons":"","version":"7"}' > ~/.claude/.safe-action-gate-state
echo '{}' | python3 safe-action/enforce.py; echo "exit=$?"
```
Expected: 출력 없음, `exit=0`.

- [ ] **Step 3: FAIL 마커 → deny JSON**

```bash
echo '{"status":"FAIL","reasons":"버전 stale(v5<v7)","version":"5"}' > ~/.claude/.safe-action-gate-state
echo '{}' | python3 safe-action/enforce.py
```
Expected: `{"hookSpecificOutput":{...,"permissionDecision":"deny","permissionDecisionReason":"[안전세팅] 세팅이 깨져 ... 사유: 버전 stale(v5<v7). 터미널에서 ..."}}`

- [ ] **Step 4: 마커 없음 → fail-closed deny, disable 파일 → 통과**

```bash
rm -f ~/.claude/.safe-action-gate-state
echo '{}' | python3 safe-action/enforce.py    # → deny(마커 없음)
touch ~/.claude/.safe-action-gate-disable
echo '{}' | python3 safe-action/enforce.py; echo "exit=$?"   # → 통과
rm -f ~/.claude/.safe-action-gate-disable
```
Expected: 첫 호출 deny JSON, 둘째 호출 출력 없음 `exit=0`. (테스트 후 정상 마커 복구: `echo '{"status":"PASS","reasons":"","version":"7"}' > ~/.claude/.safe-action-gate-state`)

- [ ] **Step 5: Commit**

```bash
git add safe-action/enforce.py
git commit -m "feat(safe-action): PreToolUse 차단 집행기 (fail-closed)"
```

---

### Task 6: 전파 + 자가복구 + 버전 (update.sh / team-diagnose.sh)

**Files:**
- Modify: `update.sh` (섹션 7 `ensure_hook` 호출부 + `LATEST_VERSION`)
- Modify: `team-diagnose.sh` (`LATEST_VERSION` + 점검 항목)

`update.sh`의 기존 `ensure_hook()` 함수는 SessionStart에 임의 커맨드 1개를 추가하는 범용이 아니라 update.sh 전용이다. 안전 액션 훅 2종(SessionStart `gate.sh`, PreToolUse `enforce.py`)을 등록하는 전용 보강 함수를 추가하고, 기존 `ensure_hook` 호출 직후 호출한다.

- [ ] **Step 1: update.sh에 `ensure_safe_action_hooks()` 추가 + 호출**

`update.sh`의 섹션 7 `ensure_hook` 정의 바로 아래(라인 137 `}` 다음)에 함수 추가:

```bash
# 안전 액션 레이어 훅 보강: gate.sh(SessionStart) + enforce.py(PreToolUse)
ensure_safe_action_hooks() {
  local target_file="$1"
  [ -f "$target_file" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local gate_cmd="$INSTALL_DIR/safe-action/gate.sh"
  local enforce_cmd="/usr/bin/python3 $INSTALL_DIR/safe-action/enforce.py"

  GATE_CMD="$gate_cmd" ENFORCE_CMD="$enforce_cmd" TARGET="$target_file" python3 - <<'PYEOF'
import json, os
target = os.environ["TARGET"]
gate_cmd = os.environ["GATE_CMD"]
enforce_cmd = os.environ["ENFORCE_CMD"]
try:
    with open(target) as f:
        data = json.load(f)
except Exception:
    return_code = 0
    raise SystemExit(0)
hooks = data.setdefault("hooks", {})

# SessionStart: gate.sh가 update.sh '뒤'에 오도록 append (순서 보장)
ss = hooks.setdefault("SessionStart", [])
def has(cmd_substr, groups):
    return any(cmd_substr in h.get("command", "")
               for g in groups for h in g.get("hooks", []))
if not has("safe-action/gate.sh", ss):
    ss.append({"matcher": "", "hooks": [{"type": "command", "command": gate_cmd}]})

# PreToolUse: enforce.py (모든 툴 = matcher "")
pre = hooks.setdefault("PreToolUse", [])
if not has("safe-action/enforce.py", pre):
    pre.append({"matcher": "", "hooks": [{"type": "command", "command": enforce_cmd, "timeout": 5}]})

with open(target, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
}
```

그리고 기존 글로벌/프로젝트 `ensure_hook` 호출(라인 140, 149) 각각 **다음 줄**에 보강 호출 추가:

```bash
ensure_hook "$SETTINGS_FILE"
ensure_safe_action_hooks "$SETTINGS_FILE"
```
```bash
  ensure_hook "$PROJECT_SETTINGS"
  ensure_safe_action_hooks "$PROJECT_SETTINGS"
```

- [ ] **Step 2: `LATEST_VERSION` 6→7 + v6→v7 마이그레이션 추가**

`update.sh` 라인 14 `LATEST_VERSION=6` → `LATEST_VERSION=7`.
v5→v6 블록(라인 549~600) **다음**, "버전 업데이트" 블록(라인 602) **앞**에 추가:

```bash
  # --- Migration v6 → v7: 안전 액션 레이어 준수 가시성 (게이트 훅은 ensure_safe_action_hooks가 매번 보강) ---
  if [ "${CURRENT_VERSION}" -lt 7 ]; then
    # 훅 등록은 위 ensure_safe_action_hooks가 이미 처리.
    # 여기선 마커 디렉터리만 보장(첫 게이트 실행 전 enforce가 fail-closed로 막지 않게 PASS 시드).
    mkdir -p "$HOME/.claude"
    if [ ! -f "$HOME/.claude/.safe-action-gate-state" ]; then
      echo '{"status":"PASS","reasons":"초기시드","version":"7"}' > "$HOME/.claude/.safe-action-gate-state"
    fi
    MIGRATED="$MIGRATED 안전액션게이트"
  fi
```

> **롤아웃 순서 주의:** SessionStart에서 update.sh가 먼저 돌며 (a) 코드 pull→재실행, (b) `ensure_safe_action_hooks`로 두 훅 등록, (c) v7 마이그레이션으로 마커 PASS 시드, (d) 버전 7로 bump. 그 다음 (이미 등록돼 있던 다음 세션부터) gate.sh가 실행. 첫 세션엔 enforce 훅이 세션 중간에 추가되어 당 세션엔 비활성(fail-open) → 다음 세션부터 활성. 시드 마커 덕에 enforce가 처음부터 사람을 가두지 않는다.

- [ ] **Step 3: update.sh 구문 검사 + 멱등성 확인**

Run:
```bash
bash -n update.sh && echo "syntax OK"
# 멱등성: 두 번 돌려도 훅이 한 번만 추가되는지 (격리 settings로)
TMP=$(mktemp); echo '{"hooks":{"SessionStart":[],"PreToolUse":[]}}' > "$TMP"
INSTALL_DIR="$(pwd)" bash -c 'source <(sed -n "/^ensure_safe_action_hooks()/,/^}/p" update.sh); ensure_safe_action_hooks "'"$TMP"'"; ensure_safe_action_hooks "'"$TMP"'"'
python3 -c "import json;d=json.load(open('$TMP'));print('SS gate:',sum('gate.sh' in h['command'] for g in d['hooks']['SessionStart'] for h in g['hooks']));print('Pre enforce:',sum('enforce.py' in h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']))"
rm -f "$TMP"
```
Expected: `syntax OK`, `SS gate: 1`, `Pre enforce: 1` (두 번 호출해도 1개).

- [ ] **Step 4: team-diagnose.sh 동기화**

라인 13 `LATEST_VERSION=6` → `LATEST_VERSION=7`. 그리고 섹션 6(스킬 심링크) 뒤, "진단 요약" 앞에 추가:

```bash
# ── 7) 안전 액션 레이어 ─────────────────────────────────────
hdr "7. 안전 액션 레이어 (게이트/하트비트)"
SA_STATE="$HOME/.claude/.safe-action-gate-state"
if grep -q "safe-action/gate.sh" "$SETTINGS_FILE" 2>/dev/null; then
  echo "$PASS SessionStart gate.sh 훅 등록됨"
else
  echo "$FAIL gate.sh 훅 미등록"; problems+=("안전 액션 gate.sh 훅 미등록")
fi
if grep -q "safe-action/enforce.py" "$SETTINGS_FILE" 2>/dev/null; then
  echo "$PASS PreToolUse enforce.py 훅 등록됨"
else
  echo "$FAIL enforce.py 훅 미등록 → 차단 집행 안 됨"; problems+=("안전 액션 enforce.py 훅 미등록")
fi
if [ -f "$SA_STATE" ]; then
  st=$(python3 -c "import json;print(json.load(open('$SA_STATE')).get('status',''))" 2>/dev/null)
  echo "   게이트 마커: $st"
  [ "$st" = "FAIL" ] && { echo "$WARN 게이트 FAIL 상태 → 도구 차단 중"; problems+=("게이트 마커 FAIL"); }
else
  echo "$WARN 게이트 마커 없음 (아직 한 번도 세션 안 열었거나 gate.sh 미실행)"
fi
```

- [ ] **Step 5: team-diagnose 구문 검사 + 실행**

Run: `bash -n team-diagnose.sh && echo OK && bash team-diagnose.sh | sed -n '/7. 안전 액션/,/진단 요약/p'`
Expected: `OK`, 섹션 7이 출력되고 본인 머신 기준 gate/enforce 등록 ✅.

- [ ] **Step 6: Commit**

```bash
git add update.sh team-diagnose.sh
git commit -m "feat(safe-action): 게이트/집행 훅 전파·자가복구 + v7 + 진단 항목"
```

---

### Task 7: 메인테이너 머신 E2E 도그푸드 + 현황판 검증

**Files:** (없음 — 통합 검증)

- [ ] **Step 1: 실제 등록 + 새 세션 시뮬레이션**

Run(메인테이너 머신, 실제 `~/.claude/settings.json` 대상):
```bash
bash ~/.caramel-team-setup/update.sh; echo "---"
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude/settings.json')));print('gate:', any('gate.sh' in h['command'] for g in d['hooks']['SessionStart'] for h in g['hooks']));print('enforce:', any('enforce.py' in h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']))"
```
Expected: `gate: True`, `enforce: True`. (update.sh가 두 훅을 실제로 등록.)

- [ ] **Step 2: gate.sh 실행 → PASS 마커 + 하트비트**

Run: `bash ~/.caramel-team-setup/safe-action/gate.sh; sleep 3; cat ~/.claude/.safe-action-gate-state`
Expected: `[안전세팅] 정상...`, 마커 `"status":"PASS"`. (백그라운드 하트비트가 시트에 1행 추가 — 3초 대기 후 다음 스텝에서 확인.)

- [ ] **Step 3: 현황판 자동 갱신 확인 (시트 직접 열기)**

브라우저로 `현황판` 탭 열기. Expected: 본인(맹주성 이메일) 행이 🟢 + 오늘 KST 시각 + v7 + PASS로 보이고, 1행 제목이 `... 오늘 활성 1명 / 정상 1 · 주의 0 ...`. `heartbeat` 탭에 방금 행이 datetime으로 들어갔는지도 확인(좌측 정렬 텍스트 아님).

- [ ] **Step 4: 차단 동작 확인 (FAIL 강제)**

Run:
```bash
echo '{"status":"FAIL","reasons":"E2E 테스트","version":"7"}' > ~/.claude/.safe-action-gate-state
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | python3 ~/.caramel-team-setup/safe-action/enforce.py
echo '{"status":"PASS","reasons":"","version":"7"}' > ~/.claude/.safe-action-gate-state   # 복구
```
Expected: deny JSON 출력(차단 동작 확인). 복구 후 정상.

- [ ] **Step 5: 테스트 하트비트 행 정리**

E2E로 생긴 테스트성 하트비트 행 중 불필요한 것 시트에서 삭제. 현황판이 다시 정상 집계되는지 확인.

> 이 태스크는 코드 변경이 없으므로 commit 없음.

---

### Task 8: 롤아웃 노트 + escape hatch 문서화

**Files:**
- Modify: `docs/superpowers/specs/2026-06-16-safe-action-layer-design.md` (오픈 이슈 해소 기록) — 또는 별도 `safe-action/README.md`

- [ ] **Step 1: safe-action/README.md 작성**

```markdown
# 안전 액션 레이어 — 준수 가시성

세팅이 깨진 팀원은 Claude 도구 사용이 차단되고, 정상 세션은 중앙 시트에 하트비트를 남깁니다.

## 구성
- `gate.sh` (SessionStart): 세팅 자가체크 → 마커 기록 → 하트비트 append
- `enforce.py` (PreToolUse): 마커 FAIL이면 모든 도구 deny (fail-closed)
- `heartbeat.js`: node 빌트인으로 시트 append (외부 패키지 불필요)
- 현황판: 시트 `현황판` 탭 (자동 갱신) — 메인테이너가 아침에 확인

## 차단됐을 때 (팀원)
1. 터미널에서 `bash ~/.caramel-team-setup/update.sh` 실행 → 새 세션
2. 안 되면 `bash ~/.caramel-team-setup/team-diagnose.sh` 결과를 맹주성님께

## 긴급 우회 (메인테이너 전용)
가드 버그로 팀이 갇히면: `touch ~/.claude/.safe-action-gate-disable` → enforce 통과.
원인 수정 후 `rm ~/.claude/.safe-action-gate-disable`.

## 신뢰 경계
로컬 훅이라 작정하고 떼면 우회 가능(spec "신뢰 경계" 참조). 평소 쓰던 사람의 하트비트 끊김이 알림 신호. 진짜 강제는 B단계 계정 권한.
```

- [ ] **Step 2: spec 오픈 이슈 갱신**

spec의 "오픈 이슈"에서 "현황판 구현 위치 최종 결정" 항목을 해소로 표시:
```
- ~~현황판 구현 위치 최종 결정~~ → **결정(2026-06-16): Google Sheet 한 장 + `현황판` 수식 탭.** 구현 플랜 `2026-06-16-safe-action-compliance-visibility.md`.
```

- [ ] **Step 3: Commit**

```bash
git add safe-action/README.md docs/superpowers/specs/2026-06-16-safe-action-layer-design.md
git commit -m "docs(safe-action): 롤아웃/escape hatch README + 오픈이슈 해소"
```

---

## Self-Review 체크리스트 (작성자 수행 완료)

**Spec 커버리지:** 구성요소 #6(하트비트+게이트+현황판) = Task 1~5,7. #5 전파/자가복구의 #6 확장 = Task 6. "쓰는 중=정상" 불변식 = 게이트 PASS 마커 + enforce 차단 + 하트비트(Task 4·5·3). 현황판 🟢/⚪/🔴 = Task 1 수식 + Task 7 검증. 실패 정책 fail-closed = enforce 마커 없음→deny(Task 5 Step4). escape 경로 = disable 파일(Task 5·8). #1·#2·#4는 명시적 범위 밖.

**미해결/주의 (실행자가 알아야 할 것):**
- 첫 롤아웃 세션은 enforce 훅이 세션 중간 등록이라 비활성 → 다음 세션부터 차단 활성. v7 마이그레이션의 마커 PASS 시드가 첫 세션 락아웃을 방지.
- 동시 세션은 마커 1개 공유(마지막 SessionStart가 덮어씀) — MVP 허용.
- 게이트 자가체크는 안전 체인 무결성+버전만 검사. db/git-guardrail 팀원 전파 점검은 미포함(별도 작업).
- org 이관(JapanesRamenMaster→the-trive) 선결 — 이관 시 origin/배포키 경로 재점검.
- 현황판 수식(BYROW/LAMBDA/MAXIFS/VLOOKUP)은 Task 7 Step3에서 실데이터로 반드시 눈으로 검증(수식 미세조정 가능성).
