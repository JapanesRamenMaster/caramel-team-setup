#!/usr/bin/env node
// 카라멜 LMS/SMS/MMS 발송 wrapper.
// caramel-api `/careplus/message/send/v2`를 직접 호출한다.
//
// 사용:
//   lms-send.sh --to 01012345678 --content "본문"
//   lms-send.sh --to 010-1234-5678,010-9876-5432 --channel LMS --subject "제목" --content "본문"
//   lms-send.sh --csv-file recipients.csv --content "안녕하세요 $1님, $2 쿠폰 도착!"
//   lms-send.sh --json '{"signalType":"MMS",...}'
//   echo '{...}' | lms-send.sh --stdin
//
// 옵션:
//   --to <CSV>             쉼표 구분 수신번호 (단일 본문 발송용)
//   --csv-file <path>      개인화 발송 — 한 줄에 "phone,var1,var2,..." 형식
//   --csv <text>           개인화 CSV 텍스트 직접 전달
//   --channel SMS|LMS|MMS  기본 LMS
//   --content <text>       본문 (필수). 변수는 $1, $2, ... 사용
//   --subject <text>       제목 (LMS/MMS, 변수치환 적용)
//   --from <number>        발신번호 (기본 15228574 사무실)
//   --group <id>           messageGroup (기본 claude_<unixtime>)
//   --reserve <iso8601>    예약발송 시각
//   --no-suffix            "[무료수신거부] 0808701439" 자동 추가 비활성
//   --json <payload>       UnifiedSignalMessageRequest 통째 (suffix/개인화 미적용)
//   --stdin                stdin에서 페이로드 읽기
//   --dry-run              실제 발송 안 하고 페이로드만 출력
//   --concurrency <N>      개인화 동시 발송 수 (기본 30)
//
// 환경: ~/.config/caramel/admin.env 에 ADMIN_USERNAME / ADMIN_PASSWORD / CARAMEL_GATEWAY

const fs = require('fs');
const path = require('path');
const os = require('os');

const OPT_OUT_TEXT = '[무료수신거부] 0808701439';
const OPT_OUT_SUFFIX = `\n\n${OPT_OUT_TEXT}`;
const DEFAULT_CHUNK = 30;
const CHUNK_DELAY_MS = 500;

function loadEnv() {
  const envPath = path.join(os.homedir(), '.config/caramel/admin.env');
  if (!fs.existsSync(envPath)) {
    die(`${envPath} not found`);
  }
  const out = {};
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith("'") && v.endsWith("'")) || (v.startsWith('"') && v.endsWith('"'))) {
      v = v.slice(1, -1);
    }
    out[m[1]] = v;
  }
  return out;
}

function die(msg, body) {
  process.stderr.write(`ERROR: ${msg}\n`);
  if (body) process.stderr.write(typeof body === 'string' ? body + '\n' : JSON.stringify(body, null, 2) + '\n');
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    channel: 'LMS',
    from: '15445932',
    group: `claude_${Math.floor(Date.now() / 1000)}`,
    dryRun: false,
    noSuffix: false,
    concurrency: DEFAULT_CHUNK,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case '--to': args.to = next(); break;
      case '--csv-file': args.csvFile = next(); break;
      case '--csv': args.csv = next(); break;
      case '--channel': args.channel = next(); break;
      case '--subject': args.subject = next(); break;
      case '--content': args.content = next(); break;
      case '--from': args.from = next(); break;
      case '--group': args.group = next(); break;
      case '--reserve': args.reserve = next(); break;
      case '--json': args.json = next(); break;
      case '--stdin': args.stdin = true; break;
      case '--no-suffix': args.noSuffix = true; break;
      case '--concurrency': args.concurrency = parseInt(next(), 10); break;
      case '--dry-run': args.dryRun = true; break;
      case '-h':
      case '--help': {
        const help = fs.readFileSync(__filename, 'utf8').split('\n').slice(1, 33).map(l => l.replace(/^\/\/ ?/, '')).join('\n');
        process.stdout.write(help + '\n');
        process.exit(0);
      }
      default:
        die(`unknown arg: ${a}`);
    }
  }
  return args;
}

function applySuffix(content, noSuffix) {
  if (noSuffix) return content;
  if (content.includes(OPT_OUT_TEXT)) return content;
  return content + OPT_OUT_SUFFIX;
}

function applyVars(template, vars) {
  if (!template) return template;
  let out = template;
  // $10, $11 같은 두자리 먼저 (회피용 — 큰 숫자부터 치환)
  for (let i = vars.length; i >= 1; i--) {
    out = out.split(`$${i}`).join(vars[i - 1] ?? '');
  }
  return out;
}

function parseCsv(text) {
  return text.split('\n')
    .map(l => l.trim())
    .filter(Boolean)
    .map(line => {
      const cells = line.split(',').map(c => c.trim());
      const phone = cells[0].replace(/[\s\-]/g, '');
      return { phone, vars: cells.slice(1) };
    })
    .filter(row => row.phone);
}

function buildPayload(args, to, content, subject) {
  const payload = {
    signalType: 'MMS',
    from: args.from,
    messageGroup: args.group,
    to,
    content,
    messageChannelType: args.channel,
  };
  if (subject) payload.subject = subject;
  if (args.reserve) payload.reserveTime = args.reserve;
  return payload;
}

async function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

async function login(gateway, username, password) {
  const body = JSON.stringify({
    query: 'mutation Login($l: AdminLoginDto!) { adminLogin(loginDto: $l) { accessToken } }',
    variables: { l: { username, password } },
  });
  const res = await fetch(`${gateway}/graphql`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { die('login response not JSON', text); }
  const token = json?.data?.adminLogin?.accessToken;
  if (!token) die('login failed', json);
  return token;
}

async function postSend(gateway, token, payload) {
  const res = await fetch(`${gateway}/careplus/message/send/v2`, {
    method: 'POST',
    headers: {
      'authorization': `Bearer ${token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}: ${text}`);
    err.status = res.status;
    err.body = text;
    throw err;
  }
  return text;
}

async function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

async function sendBulkPersonalized(gateway, token, args, rows) {
  const total = rows.length;
  let success = 0;
  const failed = [];
  const chunkSize = Math.max(1, args.concurrency || DEFAULT_CHUNK);

  for (let i = 0; i < rows.length; i += chunkSize) {
    const chunk = rows.slice(i, i + chunkSize);
    const results = await Promise.allSettled(chunk.map(async (row) => {
      const content = applySuffix(applyVars(args.content, row.vars), args.noSuffix);
      const subject = args.subject ? applyVars(args.subject, row.vars) : undefined;
      const payload = buildPayload(args, [row.phone], content, subject);
      await postSend(gateway, token, payload);
      return row.phone;
    }));
    results.forEach((r, idx) => {
      if (r.status === 'fulfilled') success++;
      else failed.push({ phone: chunk[idx].phone, error: r.reason.message });
    });
    process.stdout.write(`  진행: ${Math.min(i + chunkSize, total)}/${total} (성공 ${success}, 실패 ${failed.length})\n`);
    if (i + chunkSize < rows.length) await sleep(CHUNK_DELAY_MS);
  }

  return { total, success, failed };
}

(async () => {
  const args = parseArgs(process.argv.slice(2));
  const env = loadEnv();
  const gateway = env.CARAMEL_GATEWAY || 'https://gateway-prod.thetrive.com';

  // 모드 1: --json / --stdin → 통째 페이로드
  if (args.json || args.stdin) {
    const payload = args.json ? JSON.parse(args.json) : JSON.parse(await readStdin());
    if (args.dryRun) {
      process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
      return;
    }
    if (!env.ADMIN_USERNAME || !env.ADMIN_PASSWORD) die('ADMIN_USERNAME / ADMIN_PASSWORD missing in admin.env');
    const token = await login(gateway, env.ADMIN_USERNAME, env.ADMIN_PASSWORD);
    const text = await postSend(gateway, token, payload);
    process.stdout.write('OK\n');
    if (text) {
      try { process.stdout.write(JSON.stringify(JSON.parse(text), null, 2) + '\n'); }
      catch { process.stdout.write(text + '\n'); }
    }
    return;
  }

  // 모드 2: 개인화 (CSV)
  const csvText = args.csv || (args.csvFile ? fs.readFileSync(args.csvFile, 'utf8') : null);
  if (csvText) {
    if (!args.content) die('--content required');
    if (!['SMS', 'LMS', 'MMS'].includes(args.channel)) die(`--channel must be SMS|LMS|MMS, got: ${args.channel}`);
    const rows = parseCsv(csvText);
    if (rows.length === 0) die('no valid rows in CSV');

    if (args.dryRun) {
      // 첫 3행 미리보기
      const preview = rows.slice(0, 3).map(row => buildPayload(
        args,
        [row.phone],
        applySuffix(applyVars(args.content, row.vars), args.noSuffix),
        args.subject ? applyVars(args.subject, row.vars) : undefined,
      ));
      process.stdout.write(`[dry-run] ${rows.length}명, 첫 ${preview.length}개 미리보기:\n`);
      process.stdout.write(JSON.stringify(preview, null, 2) + '\n');
      return;
    }

    if (!env.ADMIN_USERNAME || !env.ADMIN_PASSWORD) die('ADMIN_USERNAME / ADMIN_PASSWORD missing in admin.env');
    const token = await login(gateway, env.ADMIN_USERNAME, env.ADMIN_PASSWORD);
    process.stdout.write(`개인화 발송 시작: ${rows.length}명, 청크 ${args.concurrency}\n`);
    const result = await sendBulkPersonalized(gateway, token, args, rows);
    process.stdout.write(`\n완료: 총 ${result.total}, 성공 ${result.success}, 실패 ${result.failed.length}\n`);
    if (result.failed.length > 0) {
      process.stdout.write('실패 목록:\n');
      result.failed.forEach(f => process.stdout.write(`  ${f.phone}: ${f.error}\n`));
      process.exit(12);
    }
    return;
  }

  // 모드 3: 단일 본문 다중 수신자
  if (!args.to) die('--to (or --csv/--csv-file/--json/--stdin) required');
  if (!args.content) die('--content required');
  if (!['SMS', 'LMS', 'MMS'].includes(args.channel)) die(`--channel must be SMS|LMS|MMS, got: ${args.channel}`);

  const to = args.to.split(',').map(s => s.replace(/[\s\-]/g, '')).filter(Boolean);
  if (to.length === 0) die('no valid recipients in --to');

  const content = applySuffix(args.content, args.noSuffix);
  const payload = buildPayload(args, to, content, args.subject);

  if (args.dryRun) {
    process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
    return;
  }

  if (!env.ADMIN_USERNAME || !env.ADMIN_PASSWORD) die('ADMIN_USERNAME / ADMIN_PASSWORD missing in admin.env');
  const token = await login(gateway, env.ADMIN_USERNAME, env.ADMIN_PASSWORD);
  const text = await postSend(gateway, token, payload);
  process.stdout.write(`OK (${to.length}명)\n`);
  if (text) {
    try { process.stdout.write(JSON.stringify(JSON.parse(text), null, 2) + '\n'); }
    catch { process.stdout.write(text + '\n'); }
  }
})().catch(err => die(err.message || String(err)));
