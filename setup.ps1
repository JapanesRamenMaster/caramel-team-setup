# Caramel 팀원 Claude 환경 셋업 스크립트 (Windows PowerShell)
# 사용법:
#   powershell -ExecutionPolicy Bypass -File setup.ps1 -Role cs -DbHost HOST -DbPassword PASS

param(
    [string]$Role,
    [string]$DbHost,
    [string]$DbPassword
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Caramel Claude 팀 환경 셋업 ==="
Write-Host ""

# 1. 역할 선택
$RoleMap = @{ "cs" = "CS"; "marketing" = "마케팅"; "operations" = "운영" }

if (-not $Role -or -not $RoleMap.ContainsKey($Role)) {
    Write-Host "ERROR: -Role 뒤에 cs, marketing, operations 중 하나를 입력하세요."
    exit 1
}
$RoleName = $RoleMap[$Role]
Write-Host "${RoleName}팀으로 설정합니다."

# 2. 작업 디렉토리 설정
$WorkDir = Join-Path $env:USERPROFILE "caramel-claude"
Write-Host ""
Write-Host "작업 디렉토리: $WorkDir"

if (Test-Path $WorkDir) {
    Write-Host "기존 디렉토리가 있습니다. 덮어씁니다."
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# 3. CLAUDE.md 생성 (공통 + 역할별 병합)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CommonMd = Get-Content (Join-Path $ScriptDir "CLAUDE.md") -Raw
$RoleMd = Get-Content (Join-Path $ScriptDir "roles" "$Role.md") -Raw
Set-Content -Path (Join-Path $WorkDir "CLAUDE.md") -Value ($CommonMd + "`n" + $RoleMd) -Encoding UTF8
Write-Host "CLAUDE.md 생성 완료 (공통 + ${RoleName}팀 규칙)"

# 4. DB 접속 정보
$DbPort = "3306"
$DbUser = "caramel_reader"
$DbName = "caramel-prod"

if (-not $DbHost -or -not $DbPassword) {
    Write-Host "ERROR: -DbHost와 -DbPassword가 필요합니다. 맹주성에게 슬랙 DM으로 문의하세요."
    exit 1
}

$EnvContent = @"
# Caramel DB 접속 정보 (자동 생성)
# 이 파일은 절대 공유하지 마세요
DB_HOST=$DbHost
DB_PORT=$DbPort
DB_USER=$DbUser
DB_PASSWORD=$DbPassword
DB_NAME=$DbName
"@
Set-Content -Path (Join-Path $WorkDir ".env") -Value $EnvContent -Encoding UTF8
Write-Host ".env 파일 생성 완료"

# 5. mysql-query.sh 복사
Copy-Item (Join-Path $ScriptDir "mysql-query.sh") (Join-Path $WorkDir "mysql-query.sh")
Write-Host "mysql-query.sh 복사 완료 (읽기 전용 가드레일 포함)"

# 6. .mcp.json 생성
$McpJson = @"
{
  "mcpServers": {
    "mysql": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@benborla29/mcp-server-mysql"],
      "env": {
        "MYSQL_CONNECTION_STRING": "mysql://${DbUser}:${DbPassword}@${DbHost}:${DbPort}/${DbName}",
        "MULTI_DB": "false"
      }
    }
  }
}
"@
Set-Content -Path (Join-Path $WorkDir ".mcp.json") -Value $McpJson -Encoding UTF8
Write-Host ".mcp.json 생성 완료"

# 7. 참조 문서 복사
$RefFiles = @("QUERY_REFERENCE.md", "DB_SCHEMA.md")
foreach ($f in $RefFiles) {
    $src = Join-Path $ScriptDir $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $WorkDir $f)
    }
}

# 8. Skills 설치
$SkillsDir = Join-Path $env:USERPROFILE ".claude" "skills"
$FeedbackSkillSrc = Join-Path $ScriptDir "skills" "feedback" "SKILL.md"
if (Test-Path $FeedbackSkillSrc) {
    $FeedbackSkillDst = Join-Path $SkillsDir "feedback"
    New-Item -ItemType Directory -Force -Path $FeedbackSkillDst | Out-Null
    Copy-Item $FeedbackSkillSrc (Join-Path $FeedbackSkillDst "SKILL.md")
    Write-Host "/feedback 스킬 설치 완료"
}

# 9. Node.js 확인 및 mysql2 설치
Write-Host ""
Write-Host "=== 의존성 확인 ==="

$NodeExists = Get-Command node -ErrorAction SilentlyContinue
if (-not $NodeExists) {
    Write-Host "ERROR: Node.js가 설치되어 있지 않습니다."
    Write-Host "https://nodejs.org 에서 LTS 버전을 설치하세요."
    exit 1
}
$NodeVersion = node -v
Write-Host "Node.js $NodeVersion 확인됨"

Push-Location $WorkDir
npm init -y --silent 2>$null
npm install mysql2 --silent
Write-Host "mysql2 설치 완료"
Pop-Location

# 10. DB 연결 테스트
Write-Host ""
Write-Host "=== DB 연결 테스트 ==="
Push-Location $WorkDir
$TestResult = node -e "const m=require('mysql2/promise');(async()=>{const c=await m.createConnection({host:'$DbHost',port:$DbPort,user:'$DbUser',password:'$DbPassword',database:'$DbName'});const[r]=await c.execute('SELECT 1 AS test');console.log(JSON.stringify(r[0]));await c.end()})()" 2>&1
Pop-Location

if ($TestResult -match '"test":1' -or $TestResult -match '"test": 1') {
    Write-Host "DB 연결 성공!"
} else {
    Write-Host "DB 연결 실패: $TestResult"
    Write-Host "맹주성에게 문의하세요."
    exit 1
}

Write-Host ""
Write-Host "=== 셋업 완료 ==="
Write-Host ""
Write-Host "  작업 폴더: $WorkDir"
Write-Host "  역할: ${RoleName}팀"
Write-Host "  스킬: /feedback"
Write-Host ""

# VSCode에서 자동으로 폴더 열기
$CodeExists = Get-Command code -ErrorAction SilentlyContinue
if ($CodeExists) {
    Write-Host "VSCode에서 $WorkDir 폴더를 엽니다..."
    code $WorkDir
} else {
    Write-Host "  VSCode에서 $WorkDir 폴더를 열어주세요."
}
Write-Host ""
