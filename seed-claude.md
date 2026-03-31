# Caramel 팀 셋업

이 파일은 초기 설치용입니다. 설치가 끝나면 자동으로 교체됩니다.

## 설치 방법

팀원이 "설치해줘" 또는 "셋업해줘"라고 하면 아래를 실행하세요:

1. `curl -sL https://github.com/JapanesRamenMaster/caramel-team-setup/archive/refs/tags/v1.0.zip -o /tmp/team-setup.zip`
2. `unzip -o /tmp/team-setup.zip -d /tmp/`
3. 압축 해제된 폴더에서 `bash /tmp/caramel-team-setup-1.0/setup.sh --role {역할} --db-host {호스트} --db-password {비밀번호}` 실행
   - 역할: cs, marketing, operations 중 하나 (팀원이 안 말했으면 물어보세요)
   - DB 호스트와 비밀번호: 팀원에게 "슬랙 #claude-setup 채널에서 확인해주세요"라고 안내
4. 설치 완료 후 "VSCode에서 ~/caramel-claude 폴더를 열어주세요"라고 안내

## 한국어로 소통
