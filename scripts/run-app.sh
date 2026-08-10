#!/bin/bash
#
# run-app.sh - 제공된 agent-app 을 agent-admin 계정으로 실행한다.
#
#   bash run-app.sh            앞단(foreground) 실행. 종료는 Ctrl+C.
#   bash run-app.sh --detach   뒷단 실행 후 "Agent READY" 까지 대기. 증거 수집용.
#   bash run-app.sh --stop     뒷단 실행 중인 앱 종료.
#
# root 로 호출하면 agent-admin 으로 내려간다(앱은 root 실행을 거부한다).
#
set -uo pipefail

ENV_FILE=/etc/profile.d/agent-app.sh
# shellcheck disable=SC1090
[ -r "${ENV_FILE}" ] && . "${ENV_FILE}"
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_APP_BIN="${AGENT_APP_BIN:-${AGENT_HOME}/agent-app-linux-x86}"
APP_USER=agent-admin
OUT_FILE="${OUT_FILE:-/tmp/agent-app.out}"
READY_TIMEOUT=30

mode="${1:-}"
app_pids() { pgrep -x "$(basename "${AGENT_APP_BIN}" | cut -c1-15)" 2>/dev/null; }

if [ "${mode}" = "--stop" ]; then
    pids=$(app_pids)
    if [ -z "${pids}" ]; then
        echo "[INFO] 실행 중인 앱이 없다."
        exit 0
    fi
    # 앱은 Ctrl+C(SIGINT)로 끄는 것이 정상 절차다.
    kill -INT ${pids} 2>/dev/null
    for _ in $(seq 10); do
        sleep 1
        [ -z "$(app_pids)" ] && break
    done
    [ -n "$(app_pids)" ] && kill -TERM $(app_pids) 2>/dev/null
    echo "[INFO] 앱 종료 (PID: $(echo ${pids} | tr '\n' ' '))"
    exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    runner=(su - "${APP_USER}" -c)
else
    runner=(bash -lc)
fi

if [ "${mode}" = "--detach" ]; then
    : > "${OUT_FILE}"
    chmod 666 "${OUT_FILE}"
    "${runner[@]}" "setsid nohup ${AGENT_APP_BIN} >> ${OUT_FILE} 2>&1 < /dev/null &" >/dev/null 2>&1

    for _ in $(seq "${READY_TIMEOUT}"); do
        grep -q 'Agent READY' "${OUT_FILE}" 2>/dev/null && break
        grep -q 'System Boot Failed' "${OUT_FILE}" 2>/dev/null && break
        sleep 1
    done

    sed -n '1,20p' "${OUT_FILE}"
    if grep -q 'Agent READY' "${OUT_FILE}"; then
        echo
        echo "[INFO] PID: $(app_pids | tr '\n' ' ')"
        exit 0
    fi
    echo "[FAIL] 부트 시퀀스 실패 - ${OUT_FILE} 확인" >&2
    exit 1
fi

exec "${runner[@]}" "${AGENT_APP_BIN}"
