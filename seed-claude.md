# Caramel 팀 셋업

이 파일은 초기 설치용입니다. 설치가 끝나면 자동으로 교체됩니다.

## 설치 방법

팀원이 "설치해줘" 또는 "셋업해줘"라고 하면 아래를 실행하세요:

### 사전 준비

- **gh CLI** 필요: `gh auth status`로 로그인 확인. 안 되어 있으면 `gh auth login` 먼저 실행
- **Node.js** 필요: `node -v`로 확인. 없으면 https://nodejs.org 에서 LTS 설치

### 설치 실행

1. `gh repo clone JapanesRamenMaster/caramel-team-setup /tmp/caramel-team-setup`
2. `bash /tmp/caramel-team-setup/setup.sh --role "{역할}" --db-password "{비밀번호}"` 실행
   - 역할: 팀원이 맡고 있는 역할을 자유롭게 입력 (예: CS, 마케팅, 운영, 개발, 디자인, PM 등)
   - `--role`을 생략하면 대화형으로 물어봄
   - DB 비밀번호: 팀원에게 "슬랙 #claude-setup 채널에서 확인해주세요"라고 안내
3. 설치 완료 후 "VSCode에서 ~/caramel-claude 폴더를 열어주세요"라고 안내

## 한국어로 소통
