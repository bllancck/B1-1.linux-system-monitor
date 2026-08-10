#!/bin/bash
#
# setup-security.sh - SSH 하드닝 + 방화벽(UFW) 구성
#
#   1. SSH 접속 포트를 20022 로 변경
#   2. Root 원격 로그인 차단
#   3. UFW 활성화, 인바운드는 20022/tcp(SSH)와 15034/tcp(APP)만 허용
#
# root 로 실행한다. 여러 번 실행해도 결과가 같도록(멱등) 작성했다.
#
set -euo pipefail

SSH_PORT=20022
APP_PORT=15034
SSHD_CONFIG=/etc/ssh/sshd_config

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] setup-security.sh 는 root 로 실행해야 한다." >&2
    exit 1
fi

echo "[1/4] sshd_config 백업 및 포트/Root 로그인 설정"
backup="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "${SSHD_CONFIG}" "${backup}"
echo "   ... 백업: ${backup}"

# Port 는 누적(여러 줄이면 여러 포트를 동시에 연다) 지시자라서, 기존 줄을 모두 지운 뒤
# 한 줄만 다시 넣어야 22번이 남아 있는 사고를 막을 수 있다.
sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+/d' "${SSHD_CONFIG}"
sed -i -E '/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]+/d' "${SSHD_CONFIG}"

cat >> "${SSHD_CONFIG}" <<EOF

# --- B1-1 기본 보안 설정 ---
Port ${SSH_PORT}
PermitRootLogin no
EOF

# sshd -t 는 권한 분리 디렉터리가 없으면 문법 검사조차 거부한다.
# 소켓 활성화로만 sshd 가 뜬 환경에서는 아직 만들어지지 않았을 수 있다.
mkdir -p /run/sshd
sshd -t
echo "   ... sshd -t 문법 검사 통과"

echo "[2/4] sshd 재시작"
# Ubuntu 22.04 부터 ssh 는 socket activation 으로 뜬다. ssh.socket 의 ListenStream 은
# sshd_config 를 읽어 generator 가 만들어내므로, 포트를 바꾸면 daemon-reload 가 필요하다.
systemctl daemon-reload
if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    systemctl restart ssh.socket
else
    systemctl restart ssh
fi
sleep 1

echo "[3/4] UFW 정책 구성"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow "${APP_PORT}/tcp" >/dev/null
ufw --force enable >/dev/null
systemctl enable --now ufw >/dev/null 2>&1 || true

echo "[4/4] 검증"
echo
echo "=== sshd 적용값 (sshd -T) ==="
sshd -T | grep -E '^(port|permitrootlogin) '
echo
echo "=== 포트 리슨 상태 ==="
ss -tulnp | grep -E ":(${SSH_PORT}|${APP_PORT})\b" || echo "(리슨 중인 대상 포트 없음)"
echo
echo "=== ufw status verbose ==="
ufw status verbose
echo
echo "=== Done ==="
