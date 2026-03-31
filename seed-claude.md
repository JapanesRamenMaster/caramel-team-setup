# Caramel 팀 셋업

이 파일은 초기 설치용입니다. 설치가 끝나면 자동으로 교체됩니다.

## 설치 방법

팀원이 "설치해줘" 또는 "셋업해줘"라고 하면 아래를 실행하세요:

1. 레포를 아직 클론하지 않았다면:
   `git clone https://github.com/JapanesRamenMaster/caramel-team-setup.git /tmp/caramel-team-setup`
2. OS를 감지하여 적합한 스크립트 실행:
   - **macOS / Linux**: `bash /tmp/caramel-team-setup/setup.sh --role {역할} --db-host {호스트} --db-password {비밀번호}`
   - **Windows (PowerShell)**: `powershell -ExecutionPolicy Bypass -File /tmp/caramel-team-setup/setup.ps1 -Role {역할} -DbHost {호스트} -DbPassword {비밀번호}`
   - Windows에서 `/tmp/` 경로가 없으면 `$env:TEMP\caramel-team-setup`에 클론
3. 역할: cs, marketing, operations 중 하나 (팀원이 안 말했으면 물어보세요)
4. DB 호스트와 비밀번호: 팀원에게 "슬랙 #claude-setup 채널에서 확인해주세요"라고 안내
5. 설치 완료 후 `code ~/caramel-claude` (Windows: `code $env:USERPROFILE\caramel-claude`) 실행하여 VSCode에서 자동으로 폴더 열기

## 한국어로 소통
