# Caramel 팀 셋업

이 파일은 초기 설치용입니다. 설치가 끝나면 자동으로 교체됩니다.

## 설치 방법

팀원이 "설치해줘" 또는 "셋업해줘"라고 하면 아래를 실행하세요:

### 사전 준비

- **Node.js** 필요: `node -v`로 확인. 없으면 https://nodejs.org 에서 LTS 설치
- gh CLI는 필요 없습니다

### 설치 실행

1. `git clone https://github.com/JapanesRamenMaster/caramel-team-setup.git /tmp/caramel-team-setup`
   - **반드시 /tmp에 클론하세요.** `~/caramel-team-setup` 등 홈 디렉토리에 클론하지 마세요.
   - 공개 레포이므로 인증 없이 클론 가능합니다.
2. `bash /tmp/caramel-team-setup/setup.sh --role "{역할}" --db-password "{비밀번호}" --email "{이메일}"`
   - 역할: 팀원이 맡고 있는 역할을 자유롭게 입력 (예: CS, 마케팅, 운영, 개발, 디자인, PM 등)
   - `--role`을 생략하면 대화형으로 물어봄
   - DB 비밀번호: 팀원에게 "슬랙 #claude-setup 채널에서 확인해주세요"라고 안내
   - 이메일: 팀원의 회사 이메일 (예: name@thetrive.com). Google Sheets 연동에 필요
3. `rm -rf /tmp/caramel-team-setup` (설치 완료 후 임시 파일 정리)
4. 설치 완료 후 사용자에게 반드시 안내:
   - "~/caramel-claude 폴더가 작업 공간입니다. VSCode에서 이 폴더를 열어주세요."
   - 다른 폴더(caramel-team-setup 등)가 보이면 무시해도 됩니다. 자동으로 정리됩니다.

**중요**: /tmp 외의 위치에 클론하지 마세요. 홈 디렉토리에 클론하면 사용자가 폴더 2개를 보고 혼동합니다.

## 한국어로 소통
