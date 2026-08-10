#!/bin/bash
#
# monitor.sh - 시스템 관제 자동화 스크립트
#
#   배포 위치 : $AGENT_HOME/bin/monitor.sh
#   소유/권한 : agent-dev:agent-core 750 (실행은 agent-core 소속인 agent-admin 이 cron 으로)
#
#   1. Health Check  - 앱 프로세스와 15034 포트를 확인하고, 하나라도 비정상이면 exit 1
#   2. 상태 점검     - 방화벽 비활성이면 경고만 남기고 계속 진행
#   3. 자원 수집     - CPU / MEM / DISK(root) 사용률
#   4. 임계값 경고   - CPU>20% MEM>10% DISK>80%
#   5. 로그 기록     - $AGENT_LOG_DIR/monitor.log 에 한 줄 추가 (10MB / 10개 파일 유지)
#
set -uo pipefail

# ------------------------------------------------------------------
# 환경 변수
#
# cron 은 최소 환경(HOME/PATH/SHELL)만 넘겨주므로 환경 파일을 직접 읽는다.
# 다만 호출자가 명시적으로 넘긴 값이 있으면 그쪽을 우선한다(일회성 실행/테스트용).
# ------------------------------------------------------------------
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/profile.d/agent-app.sh}"
_caller_env=$(declare -p AGENT_HOME AGENT_PORT AGENT_LOG_DIR AGENT_APP_BIN 2>/dev/null || true)
# shellcheck disable=SC1090
[ -r "${AGENT_ENV_FILE}" ] && . "${AGENT_ENV_FILE}"
eval "${_caller_env}"

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
APP_NAME="${APP_NAME:-$(basename "${AGENT_APP_BIN:-agent-app-linux-x86}")}"

LOG_FILE="${AGENT_LOG_DIR}/monitor.log"
CRON_LOG="${AGENT_LOG_DIR}/cron.log"

# 임계값. 기본값은 과제 명세를 따르고, 검증할 때만 환경 변수로 덮어쓴다.
CPU_THRESHOLD="${CPU_THRESHOLD:-20}"      # %
MEM_THRESHOLD="${MEM_THRESHOLD:-10}"      # %
DISK_THRESHOLD="${DISK_THRESHOLD:-80}"    # %
CPU_SAMPLE_SEC="${CPU_SAMPLE_SEC:-1}"     # /proc/stat 두 번 샘플링하는 간격

LOG_MAX_BYTES=$((10 * 1024 * 1024))   # 파일 하나당 10MB
LOG_MAX_FILES=10                      # 현재 파일 + 아카이브 합계 10개

# ------------------------------------------------------------------
# 로그 보존: 10MB 를 넘으면 .1 ~ .9 로 밀어내고 가장 오래된 것을 버린다.
# cron 출력(cron.log)도 방치하면 계속 커지므로 같은 정책으로 관리한다.
# ------------------------------------------------------------------
rotate_if_needed() {
    local file="$1" size i
    [ -f "${file}" ] || return 0
    size=$(stat -c %s "${file}" 2>/dev/null) || return 0
    [ "${size}" -lt "${LOG_MAX_BYTES}" ] && return 0

    rm -f "${file}.$((LOG_MAX_FILES - 1))"
    for ((i = LOG_MAX_FILES - 2; i >= 1; i--)); do
        [ -f "${file}.${i}" ] && mv -f "${file}.${i}" "${file}.$((i + 1))"
    done
    mv -f "${file}" "${file}.1"
    : > "${file}"
    echo "[INFO] Rotated: ${file} (>= $((LOG_MAX_BYTES / 1024 / 1024))MB, keep ${LOG_MAX_FILES} files)"
}

write_log() {
    printf '%s\n' "$1" >> "${LOG_FILE}"
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# ------------------------------------------------------------------
# 자원 수집
# ------------------------------------------------------------------

# /proc/stat 의 누적 jiffies 를 두 번 읽어 구간 사용률을 구한다.
# top -bn1 의 첫 스냅샷은 부팅 이후 평균이라 순간 부하를 놓친다.
cpu_snapshot() {
    awk '/^cpu /{ idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total, idle }' /proc/stat
}

collect_cpu() {
    local t1 i1 t2 i2
    read -r t1 i1 < <(cpu_snapshot)
    sleep "${CPU_SAMPLE_SEC}"
    read -r t2 i2 < <(cpu_snapshot)
    awk -v t1="${t1}" -v i1="${i1}" -v t2="${t2}" -v i2="${i2}" 'BEGIN {
        dt = t2 - t1; di = i2 - i1
        if (dt <= 0) { print "0.0"; exit }
        u = (dt - di) / dt * 100
        if (u < 0) u = 0; if (u > 100) u = 100
        printf "%.1f", u
    }'
}

# 캐시/버퍼는 회수 가능하므로 MemAvailable 기준으로 "실제 부족분"을 본다.
collect_mem() {
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
         END { if (t > 0) printf "%.1f", (t - a) / t * 100; else printf "0.0" }' /proc/meminfo
}

collect_disk() {
    df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

# ufw status 는 root 전용이라 cron(agent-admin)에서는 쓸 수 없다.
# 일반 계정이 읽을 수 있는 설정 파일과 유닛 상태로 대체 판정한다.
firewall_active() {
    if [ "$(id -u)" -eq 0 ] && command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | grep -qi 'Status: active' && return 0
        return 1
    fi
    grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null \
        && systemctl is-active --quiet ufw 2>/dev/null
}

# 실수 비교는 test 로 못 하므로 awk 에 맡긴다.
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# 감시 대상 PID 목록.
#
# pgrep -f 로 cmdline 을 훑으면 앱을 감싼 su/bash 래퍼까지 함께 잡힌다.
# 커널의 comm 은 15자로 잘리므로, 잘린 이름으로 정확히 일치하는 프로세스만 고른다.
app_pids() {
    pgrep -x "${APP_NAME:0:15}" 2>/dev/null
}

# ------------------------------------------------------------------
# 1. Health Check (실패 시 종료)
# ------------------------------------------------------------------
mkdir -p "${AGENT_LOG_DIR}" 2>/dev/null
rotate_if_needed "${LOG_FILE}"
rotate_if_needed "${CRON_LOG}"

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

mapfile -t APP_PIDS < <(app_pids)
if [ "${#APP_PIDS[@]}" -eq 0 ]; then
    echo "Checking process '${APP_NAME}'... [FAIL] Process not running"
    write_log "[$(timestamp)] [FAIL] process '${APP_NAME}' not running"
    exit 1
fi

# PyInstaller 바이너리는 "부트로더 부모 -> 실제 워커 자식" 2단으로 뜬다.
# 대표 PID 는 부모(= PPID 가 이 집합에 없는 프로세스)로 잡는다.
#
# /proc/<pid>/stat 의 comm 필드는 괄호로 감싸여 있고 공백을 포함할 수 있어서,
# 필드 번호로 바로 세면 어긋난다. 닫는 괄호까지 잘라낸 뒤 세는 것이 안전하다.
APP_PID="${APP_PIDS[0]}"
for pid in "${APP_PIDS[@]}"; do
    stat_rest=$(cat "/proc/${pid}/stat" 2>/dev/null) || continue
    ppid=$(awk '{ print $2 }' <<< "${stat_rest#*) }")
    if ! printf '%s\n' "${APP_PIDS[@]}" | grep -qx "${ppid}"; then
        APP_PID="${pid}"
        break
    fi
done
echo "Checking process '${APP_NAME}'... [OK] (PID: ${APP_PID})"

if ! ss -tuln 2>/dev/null | grep -q ":${AGENT_PORT}\b"; then
    echo "Checking port ${AGENT_PORT}... [FAIL] Port not listening"
    write_log "[$(timestamp)] [FAIL] port ${AGENT_PORT} not listening (PID:${APP_PID})"
    exit 1
fi
echo "Checking port ${AGENT_PORT}... [OK]"
echo

# ------------------------------------------------------------------
# 2. 상태 점검 (경고만)
# ------------------------------------------------------------------
if ! firewall_active; then
    echo "[WARNING] Firewall (UFW) is not active!"
    echo
fi

# ------------------------------------------------------------------
# 3. 자원 수집
# ------------------------------------------------------------------
CPU_USAGE=$(collect_cpu)
MEM_USAGE=$(collect_mem)
DISK_USED=$(collect_disk)

echo "[RESOURCE MONITORING]"
echo "CPU Usage  : ${CPU_USAGE}%"
echo "MEM Usage  : ${MEM_USAGE}%"
echo "DISK Used  : ${DISK_USED}%"
echo

# ------------------------------------------------------------------
# 4. 임계값 경고 (경고만)
# ------------------------------------------------------------------
gt "${CPU_USAGE}"  "${CPU_THRESHOLD}"  && echo "[WARNING] CPU threshold exceeded (${CPU_USAGE}% > ${CPU_THRESHOLD}%)"
gt "${MEM_USAGE}"  "${MEM_THRESHOLD}"  && echo "[WARNING] MEM threshold exceeded (${MEM_USAGE}% > ${MEM_THRESHOLD}%)"
gt "${DISK_USED}"  "${DISK_THRESHOLD}" && echo "[WARNING] DISK threshold exceeded (${DISK_USED}% > ${DISK_THRESHOLD}%)"

# ------------------------------------------------------------------
# 5. 로그 기록
# ------------------------------------------------------------------
write_log "[$(timestamp)] PID:${APP_PID} CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USED}%"
echo
echo "[INFO] Log appended: ${LOG_FILE}"
exit 0
