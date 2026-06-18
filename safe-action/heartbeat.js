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

  // 성공했을 때만 1일1회 스탬프 기록 (실패하면 gate.sh가 다음 세션에 재시도)
  const stamp = process.env.SAFE_ACTION_STAMP;
  const today = process.env.SAFE_ACTION_TODAY;
  if (stamp && today) {
    try { fs.writeFileSync(stamp, today); } catch (e) { /* best-effort */ }
  }
}

main().catch((e) => {
  // best-effort: 기록 실패가 세션을 막아선 안 됨. stderr만 남기고 정상 종료.
  process.stderr.write('[heartbeat] skip: ' + (e && e.message) + '\n');
}).finally(() => process.exit(0));
