#!/bin/bash
#
# agent-env.sh - agent-app 실행 환경 변수 정의
#
# setup-agent.sh 가 이 파일을 /etc/profile.d/agent-app.sh 로 배포한다.
#   - 로그인 셸: /etc/profile 이 자동으로 읽어 모든 계정에 동일한 값이 적용된다.
#   - cron: 최소 환경(HOME/PATH/SHELL)만 주어지므로 monitor.sh 가 직접 source 한다.
# 실행 환경을 한 곳에 고정해 두어야 "내 셸에서는 되는데 cron 에서는 안 되는" 차이가 없다.
#

export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="${AGENT_HOME}/upload_files"

# 과제 명세는 AGENT_KEY_PATH 를 키 "파일" 경로(api_keys/t_secret.key)로 안내하지만,
# 제공된 바이너리는 이 값을 키 "디렉터리"로 해석하고 그 안의 secret.key 를 읽는다.
# 파일 경로를 넣으면 부트 2단계에서 Key Path Mismatch 로 실패한다. 상세는 README 참고.
export AGENT_KEY_PATH="${AGENT_HOME}/api_keys"

export AGENT_LOG_DIR=/var/log/agent-app

# 제공된 애플리케이션 바이너리(x86_64). monitor.sh 의 프로세스 검사 대상이기도 하다.
export AGENT_APP_BIN="${AGENT_HOME}/agent-app-linux-x86"
