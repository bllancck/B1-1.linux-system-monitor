#!/bin/bash
#
# setup-agent.sh - 계정/그룹/디렉터리/권한/환경변수/앱/관제 스크립트/cron 구성
#
# root 로 실행한다. 여러 번 실행해도 결과가 같도록(멱등) 작성했다.
#
#   REPO_DIR=<리포지토리 경로> bash setup-agent.sh
#
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE=/etc/profile.d/agent-app.sh
APP_BINARY=agent-app-linux-x86
SECRET_VALUE=agent_api_key_test
CRON_LINE='* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1'

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] setup-agent.sh 는 root 로 실행해야 한다." >&2
    exit 1
fi

echo "[1/8] 계정 생성"
# agent-admin: 운영/관리, cron 실행자
# agent-dev  : 개발/운영, monitor.sh 작성자
# agent-test : QA/테스트
for u in agent-admin agent-dev agent-test; do
    if id -u "${u}" >/dev/null 2>&1; then
        echo "   ... ${u} 이미 존재"
    else
        useradd -m -s /bin/bash "${u}"
        echo "   ... ${u} 생성"
    fi
done

echo "[2/8] 그룹 생성 및 소속 부여"
# agent-common: 세 계정 전부 (공유 영역)
# agent-core  : admin, dev 만    (보안 영역)
for g in agent-common agent-core; do
    getent group "${g}" >/dev/null || groupadd "${g}"
done
gpasswd -M agent-admin,agent-dev,agent-test agent-common >/dev/null
gpasswd -M agent-admin,agent-dev            agent-core   >/dev/null

echo "[3/8] 환경 변수 배포 -> ${ENV_FILE}"
install -o root -g root -m 644 "${REPO_DIR}/scripts/agent-env.sh" "${ENV_FILE}"
# shellcheck disable=SC1090
. "${ENV_FILE}"

echo "[4/8] 디렉터리 구조 및 권한 구성"
# AGENT_HOME 은 agent-admin 의 홈(/home/agent-admin, 750) 안에 있다. 하위 권한을
# 아무리 열어도 상위 디렉터리를 통과(x)하지 못하면 접근이 막히므로, 홈에는 ACL 로
# agent-common 에게 실행 비트만 준다. r 은 주지 않으므로 홈 목록 조회는 여전히 불가.
setfacl -m g:agent-common:x /home/agent-admin

# AGENT_HOME 자체는 agent-common 이 통과할 수 있어야 agent-test 가 upload_files 에
# 접근할 수 있다. 보안 경계는 하위 디렉터리(api_keys)에서 그룹으로 다시 나눈다.
install -d -o agent-admin -g agent-common -m 750 "${AGENT_HOME}"
install -d -o agent-admin -g agent-common -m 770 "${AGENT_UPLOAD_DIR}"
install -d -o agent-admin -g agent-core   -m 770 "${AGENT_KEY_PATH}"
install -d -o agent-admin -g agent-core   -m 770 "${AGENT_LOG_DIR}"
install -d -o agent-dev   -g agent-core   -m 750 "${AGENT_HOME}/bin"

# 기본 ACL(-d)까지 걸어야 나중에 만들어지는 파일도 그룹 권한을 물려받는다.
setfacl -m  g:agent-common:rwx -m o::--- "${AGENT_UPLOAD_DIR}"
setfacl -d -m g:agent-common:rwx -m o::--- "${AGENT_UPLOAD_DIR}"
setfacl -m  g:agent-core:rwx   -m o::--- "${AGENT_KEY_PATH}"
setfacl -d -m g:agent-core:rwx -m o::--- "${AGENT_KEY_PATH}"
setfacl -m  g:agent-core:rwx   -m o::--- "${AGENT_LOG_DIR}"
setfacl -d -m g:agent-core:rwx -m o::--- "${AGENT_LOG_DIR}"

echo "[5/8] API 키 파일 생성"
# 바이너리가 실제로 읽는 이름은 secret.key 다. t_secret.key 는 과제 명세에 적힌
# 이름이라 같은 내용으로 함께 둔다(둘 다 있어도 앱 동작에는 영향 없음).
for k in secret.key t_secret.key; do
    printf '%s\n' "${SECRET_VALUE}" > "${AGENT_KEY_PATH}/${k}"
    chown agent-admin:agent-core "${AGENT_KEY_PATH}/${k}"
    chmod 640 "${AGENT_KEY_PATH}/${k}"
done

echo "[6/8] 애플리케이션 바이너리 배포"
if [ -f "${REPO_DIR}/agent-app/${APP_BINARY}" ]; then
    install -o agent-admin -g agent-core -m 750 \
        "${REPO_DIR}/agent-app/${APP_BINARY}" "${AGENT_HOME}/${APP_BINARY}"
    echo "   ... ${AGENT_HOME}/${APP_BINARY}"
else
    echo "   [WARNING] ${REPO_DIR}/agent-app/${APP_BINARY} 없음 - 배포 생략" >&2
fi

echo "[7/8] monitor.sh 배포 (소유자 agent-dev / 그룹 agent-core / 750)"
install -o agent-dev -g agent-core -m 750 \
    "${REPO_DIR}/scripts/monitor.sh" "${AGENT_HOME}/bin/monitor.sh"

echo "[8/8] agent-admin crontab 등록 (매분 실행)"
current=$(crontab -u agent-admin -l 2>/dev/null || true)
if printf '%s\n' "${current}" | grep -Fqx "${CRON_LINE}"; then
    echo "   ... 이미 등록됨"
else
    # monitor.sh 를 부르는 기존 줄은 걷어내고 한 줄만 남긴다.
    printf '%s\n' "${current}" | grep -v 'bin/monitor.sh' | sed '/^$/d' > /tmp/agent-admin.cron
    printf '%s\n' "${CRON_LINE}" >> /tmp/agent-admin.cron
    crontab -u agent-admin /tmp/agent-admin.cron
    rm -f /tmp/agent-admin.cron
    echo "   ... 등록 완료"
fi
systemctl enable --now cron >/dev/null 2>&1 || true

echo
echo "=== 계정/그룹 ==="
id agent-admin; id agent-dev; id agent-test
echo
echo "=== 디렉터리 ==="
ls -ld "${AGENT_HOME}" "${AGENT_UPLOAD_DIR}" "${AGENT_KEY_PATH}" "${AGENT_LOG_DIR}" "${AGENT_HOME}/bin"
ls -l "${AGENT_KEY_PATH}" "${AGENT_HOME}/bin"
echo
echo "=== crontab (agent-admin) ==="
crontab -u agent-admin -l
echo
echo "=== Done ==="
