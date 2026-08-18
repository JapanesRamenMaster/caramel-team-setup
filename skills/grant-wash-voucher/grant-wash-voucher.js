#!/usr/bin/env node
// grant-wash-voucher.js — 고객에게 세차권(user_service)을 serviceId로 직접 지급한다.
// caramel-api 게이트웨이 `POST /careplus/users-admin/{userId}/services {serviceId}` 호출.
// 각 호출 = user_service 1행 (ended_at=2999-12-31 무기한, paid_yn=1, product_id=null).
//
// 사용법:
//   grant-wash-voucher.sh --user <userId> [--service <serviceId=135>] [--count <n=1>] [--dry-run]
//
// serviceId 135 = "외부만" (tier_id=null, 티어 무관, 어느 차에나 사용). 다른 세차권은 skill 카탈로그/DB 참조.
// 환경: ~/.config/caramel/admin.env (ADMIN_USERNAME / ADMIN_PASSWORD / CARAMEL_GATEWAY) — lms-send.js와 동일.

const fs = require('fs');
const os = require('os');
const path = require('path');

function die(msg, extra) {
  console.error('ERROR: ' + msg);
  if (extra) console.error(typeof extra === 'string' ? extra : JSON.stringify(extra, null, 2));
  process.exit(1);
}

function loadEnv() {
  const p = path.join(os.homedir(), '.config/caramel/admin.env');
  if (!fs.existsSync(p)) die('admin.env 없음: ' + p);
  const env = {};
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return env;
}

function parseArgs(argv) {
  const a = { service: 135, count: 1, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--user') a.user = parseInt(argv[++i], 10);
    else if (k === '--service') a.service = parseInt(argv[++i], 10);
    else if (k === '--count') a.count = parseInt(argv[++i], 10);
    else if (k === '--dry-run') a.dryRun = true;
    else die('알 수 없는 인자: ' + k);
  }
  if (!a.user || Number.isNaN(a.user)) die('--user <userId> 필수');
  if (!a.service || Number.isNaN(a.service)) die('--service <serviceId> 잘못됨');
  if (!a.count || a.count < 1) die('--count <n> 은 1 이상');
  return a;
}

async function login(gateway, username, password) {
  const body = JSON.stringify({
    query: 'mutation Login($l: AdminLoginDto!) { adminLogin(loginDto: $l) { accessToken } }',
    variables: { l: { username, password } },
  });
  const res = await fetch(`${gateway}/graphql`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body,
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { die('login 응답이 JSON 아님', text); }
  const token = json?.data?.adminLogin?.accessToken;
  if (!token) die('login 실패', json);
  return token;
}

async function issue(gateway, token, userId, serviceId) {
  const res = await fetch(`${gateway}/careplus/users-admin/${userId}/services`, {
    method: 'POST',
    headers: { 'authorization': `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ serviceId }),
  });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text };
}

(async () => {
  const args = parseArgs(process.argv.slice(2));
  const env = loadEnv();
  const gateway = env.CARAMEL_GATEWAY || 'https://gateway-prod.thetrive.com';
  if (!env.ADMIN_USERNAME || !env.ADMIN_PASSWORD) die('admin.env에 ADMIN_USERNAME / ADMIN_PASSWORD 없음');

  console.error(`[GRANT] user=${args.user} service=${args.service} count=${args.count}${args.dryRun ? ' (DRY-RUN)' : ''}`);
  console.error(`  endpoint: POST ${gateway}/careplus/users-admin/${args.user}/services  body={"serviceId":${args.service}}`);

  const token = await login(gateway, env.ADMIN_USERNAME, env.ADMIN_PASSWORD);
  console.error('  로그인 OK');

  if (args.dryRun) {
    console.error(`  DRY-RUN: ${args.count}회 호출 예정 (실제 지급 안 함)`);
    console.log(JSON.stringify({ dryRun: true, user: args.user, service: args.service, count: args.count }));
    return;
  }

  let success = 0; const ids = []; const fails = [];
  for (let i = 1; i <= args.count; i++) {
    try {
      const r = await issue(gateway, token, args.user, args.service);
      if (r.ok) {
        success++;
        let id = null; try { id = JSON.parse(r.text)?.id ?? null; } catch {}
        ids.push(id);
        process.stderr.write(`  #${i}: OK (us_id=${id})\n`);
      } else {
        fails.push({ i, status: r.status, text: r.text });
        process.stderr.write(`  #${i}: FAIL HTTP ${r.status} ${r.text}\n`);
      }
    } catch (e) {
      fails.push({ i, err: String(e) });
      process.stderr.write(`  #${i}: ERROR ${e}\n`);
    }
    await new Promise(res => setTimeout(res, 150));
  }
  console.error(`\n결과: 성공 ${success}/${args.count}, 실패 ${fails.length}`);
  console.log(JSON.stringify({ user: args.user, service: args.service, requested: args.count, success, ids, fails }));
})();
