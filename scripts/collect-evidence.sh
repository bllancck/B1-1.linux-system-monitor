#!/bin/bash
#
# collect-evidence.sh - 과제 제출용 증거 자료를 logs/ 아래에 수집한다.
#
# 앱을 띄우고 -> monitor.sh 를 돌리고 -> cron 자동 실행을 2분간 관찰하고 -> 앱을 내린다.
# 전체 4~5분 정도 걸린다. root 로 실행한다.
#
set -uo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT_DIR="${REPO_DIR}/logs"
ENV_FILE=/etc/profile.d/agent-app.sh
# shellcheck disable=SC1090
[ -r "${ENV_FILE}" ] && . "${ENV_FILE}"
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
MONITOR="${AGENT_HOME}/bin/monitor.sh"
SSH_PORT=20022

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] collect-evidence.sh 는 root 로 실행해야 한다." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"
say() { echo "### $*"; }

# ---------------------------------------------------------------- 1. SSH
say "1/9 SSH 설정"
{
    echo "$ grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config"
    grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
    echo
    echo "$ sshd -T | grep -E '^(port|permitrootlogin) '"
    sshd -T | grep -E '^(port|permitrootlogin) '
    echo
    echo "$ ss -tulnp | grep sshd"
    ss -tulnp | grep -E "sshd|:${SSH_PORT}\b"
    echo
    echo "$ systemctl status ssh.socket --no-pager"
    systemctl status ssh.socket --no-pager 2>&1 | sed -n '1,6p'
} > "${OUT_DIR}/01-ssh.txt" 2>&1

# ---------------------------------------------------------------- 2. 방화벽
say "2/9 방화벽"
{
    echo "$ ufw status verbose"
    ufw status verbose
    echo
    echo "$ ufw status numbered"
    ufw status numbered
} > "${OUT_DIR}/02-firewall.txt" 2>&1

# ---------------------------------------------------------------- 3. 계정/그룹
say "3/9 계정 / 그룹"
{
    for u in agent-admin agent-dev agent-test; do
        echo "$ id ${u}"; id "${u}"; echo
    done
    echo "$ getent group agent-common agent-core"
    getent group agent-common agent-core
    echo
    echo "$ getent passwd agent-admin agent-dev agent-test"
    getent passwd agent-admin agent-dev agent-test
} > "${OUT_DIR}/03-accounts.txt" 2>&1

# ---------------------------------------------------------------- 4. 디렉터리/권한
say "4/9 디렉터리 / 권한 / ACL"
{
    echo "$ ls -ld \$AGENT_HOME 및 하위"
    ls -ld "${AGENT_HOME}" "${AGENT_HOME}/upload_files" "${AGENT_HOME}/api_keys" \
           "${AGENT_HOME}/bin" "${AGENT_LOG_DIR}"
    echo
    echo "$ ls -l \$AGENT_HOME/api_keys \$AGENT_HOME/bin"
    ls -l "${AGENT_HOME}/api_keys" "${AGENT_HOME}/bin"
    echo
    for d in "${AGENT_HOME}/upload_files" "${AGENT_HOME}/api_keys" "${AGENT_LOG_DIR}"; do
        echo "$ getfacl ${d}"; getfacl "${d}"; echo
    done
    echo "=== 접근 통제 실증 (agent-test 는 agent-common 이지만 agent-core 는 아니다) ==="
    echo "$ su - agent-test -c 'touch \$AGENT_HOME/upload_files/from-test.tmp && ls -l ...'"
    su - agent-test -c "touch ${AGENT_HOME}/upload_files/from-test.tmp && ls -l ${AGENT_HOME}/upload_files/from-test.tmp" 2>&1 | sed 's/^/  -> /'
    echo "$ su - agent-test -c 'ls \$AGENT_HOME/api_keys'"
    su - agent-test -c "ls ${AGENT_HOME}/api_keys" 2>&1 | sed 's/^/  -> /'
    echo "$ su - agent-test -c 'cat \$AGENT_LOG_DIR/monitor.log'"
    su - agent-test -c "cat ${AGENT_LOG_DIR}/monitor.log" 2>&1 | sed -n '1,2p' | sed 's/^/  -> /'
    echo "$ su - agent-dev -c 'head -1 \$AGENT_HOME/api_keys/secret.key'"
    su - agent-dev -c "head -1 ${AGENT_HOME}/api_keys/secret.key" 2>&1 | sed 's/^/  -> /'
    rm -f "${AGENT_HOME}/upload_files/from-test.tmp"
    echo
    echo "$ env | grep AGENT_  (agent-admin 로그인 셸)"
    su - agent-admin -c 'env | grep ^AGENT_ | sort'
} > "${OUT_DIR}/04-permissions.txt" 2>&1

# ---------------------------------------------------------------- 5. 앱 부트
say "5/9 애플리케이션 부트 시퀀스"
bash "${REPO_DIR}/scripts/run-app.sh" --stop >/dev/null 2>&1
sleep 1
{
    echo "$ whoami (실행 계정)"
    echo "agent-admin  # root 실행은 앱이 거부한다"
    echo
    echo "$ \$AGENT_HOME/agent-app-linux-x86"
    bash "${REPO_DIR}/scripts/run-app.sh" --detach
    echo
    echo "$ ss -tulnp | grep ${AGENT_PORT}"
    ss -tulnp | grep ":${AGENT_PORT}\b"
    echo
    echo "$ ps -o pid,ppid,user,comm,args -p \$(pgrep -x agent-app-linux | paste -sd,)"
    ps -o pid,ppid,user,comm,args -p "$(pgrep -x agent-app-linux | paste -sd,)" 2>&1
} > "${OUT_DIR}/05-boot-sequence.txt" 2>&1
grep -q 'Agent READY' "${OUT_DIR}/05-boot-sequence.txt" \
    && echo "    ... Agent READY 확인" \
    || echo "    [WARNING] Agent READY 미확인"

# ---------------------------------------------------------------- 6. monitor.sh 수동 실행
say "6/9 monitor.sh 수동 실행"
{
    echo "$ ls -l \$AGENT_HOME/bin/monitor.sh"
    ls -l "${MONITOR}"
    echo
    echo "$ su - agent-admin -c '\$AGENT_HOME/bin/monitor.sh'   # cron 실행 계정과 동일"
    su - agent-admin -c "${MONITOR}"
    echo "(exit code: $?)"
    echo
    echo "=== 권한 정책 검증: agent-test 는 agent-core 가 아니므로 실행 불가 ==="
    echo "$ su - agent-test -c '\$AGENT_HOME/bin/monitor.sh'"
    su - agent-test -c "${MONITOR}" 2>&1 | sed 's/^/  -> /'
    echo
    echo "=== Health Check 실패 시 exit 1 검증 (존재하지 않는 프로세스명 주입) ==="
    echo "$ APP_NAME=no-such-app su - agent-admin -c '...monitor.sh'"
    su - agent-admin -c "APP_NAME=no-such-app ${MONITOR}"
    echo "(exit code: $?)"
    echo
    echo "=== CPU 임계값 경고 검증 (전 코어에 인위적 부하 주입) ==="
    for _ in $(seq "$(nproc)"); do ( timeout 6 bash -c 'while :; do :; done' & ) ; done
    sleep 1
    su - agent-admin -c "${MONITOR}" | sed -n '/RESOURCE/,$p'
    wait 2>/dev/null
    sleep 5
    echo
    echo "=== DISK 임계값 경고 검증 (현재 사용률 1% -> 임계값을 0% 로 낮춰 분기 확인) ==="
    su - agent-admin -c "DISK_THRESHOLD=0 ${MONITOR}" | sed -n '/RESOURCE/,$p'
} > "${OUT_DIR}/06-monitor-run.txt" 2>&1

# ---------------------------------------------------------------- 7. monitor.log
say "7/9 monitor.log 누적"
{
    echo "$ ls -lh \$AGENT_LOG_DIR"
    ls -lh "${AGENT_LOG_DIR}"
    echo
    echo "$ tail -n 10 \$AGENT_LOG_DIR/monitor.log"
    tail -n 10 "${AGENT_LOG_DIR}/monitor.log"
} > "${OUT_DIR}/07-monitor-log.txt" 2>&1

# ---------------------------------------------------------------- 8. cron
say "8/9 cron 자동 실행 관찰 (약 2분 30초)"
before_lines=$(wc -l < "${AGENT_LOG_DIR}/monitor.log")
before_time=$(date '+%Y-%m-%d %H:%M:%S')
sleep 150
after_lines=$(wc -l < "${AGENT_LOG_DIR}/monitor.log")
after_time=$(date '+%Y-%m-%d %H:%M:%S')
{
    echo "$ crontab -u agent-admin -l"
    crontab -u agent-admin -l | grep -v '^#'
    echo
    echo "$ systemctl is-active cron"
    systemctl is-active cron
    echo
    echo "=== 대기 전후 monitor.log 라인 수 ==="
    printf '%-22s %s\n' "${before_time}" "${before_lines} lines"
    printf '%-22s %s\n' "${after_time}"  "${after_lines} lines  (+$((after_lines - before_lines)))"
    echo
    echo "$ tail -n 5 \$AGENT_LOG_DIR/monitor.log"
    tail -n 5 "${AGENT_LOG_DIR}/monitor.log"
    echo
    echo "$ journalctl -u cron --since '3 min ago' | grep agent-admin"
    journalctl -u cron --since '3 min ago' 2>/dev/null | grep agent-admin | tail -n 5
} > "${OUT_DIR}/08-cron.txt" 2>&1

# ---------------------------------------------------------------- 9. 로그 로테이션
say "9/9 로그 보존 정책 검증"
demo=/tmp/rotate-demo
rm -rf "${demo}"; mkdir -p "${demo}"
# 이미 아카이브 9개가 쌓여 있고 현재 파일이 10MB 를 넘긴 상황을 만든다.
for i in $(seq 1 9); do echo "archive-${i}" > "${demo}/monitor.log.${i}"; done
head -c $((10 * 1024 * 1024 + 1024)) /dev/zero | tr '\0' 'x' > "${demo}/monitor.log"
echo "OLDEST-CURRENT" >> "${demo}/monitor.log"
chmod -R 777 "${demo}"
{
    echo "정책: 파일 하나가 10MB 를 넘으면 .1~.9 로 밀어내고 총 10개만 유지한다."
    echo
    echo "=== 실행 전 ==="
    ls -lh "${demo}"
    echo
    echo "$ AGENT_LOG_DIR=${demo} su - agent-admin -c '...monitor.sh'"
    su - agent-admin -c "AGENT_LOG_DIR=${demo} ${MONITOR}" | sed -n '1,12p'
    echo
    echo "=== 실행 후 ==="
    ls -lh "${demo}"
    echo
    echo "파일 개수: $(find "${demo}" -maxdepth 1 -type f | wc -l) 개"
    echo "가장 오래된 아카이브(.9) 내용: $(head -c 40 "${demo}/monitor.log.9")"
    echo "새 monitor.log 내용:"
    cat "${demo}/monitor.log"
} > "${OUT_DIR}/09-log-rotation.txt" 2>&1
rm -rf "${demo}"

# ---------------------------------------------------------------- 정리
say "앱 종료"
bash "${REPO_DIR}/scripts/run-app.sh" --stop
# 프로세스가 사라진 뒤에도 커널이 리슨 소켓을 정리하는 데 잠깐 걸린다.
sleep 3
{
    echo "$ ss -tuln | grep ${AGENT_PORT}"
    ss -tuln | grep ":${AGENT_PORT}\b" || echo "(LISTEN 없음 - 앱 종료 확인)"
    echo
    echo "$ su - agent-admin -c '\$AGENT_HOME/bin/monitor.sh'; echo \$?"
    su - agent-admin -c "${MONITOR}"
    echo "(exit code: $?)"
} >> "${OUT_DIR}/06-monitor-run.txt" 2>&1

# WSL 콘솔이 끼워 넣는 경고는 증거와 무관하므로 걷어낸다.
sed -i '/screen size is bogus/d' "${OUT_DIR}"/*.txt

echo
echo "=== 수집 완료: ${OUT_DIR} ==="
ls -l "${OUT_DIR}"
