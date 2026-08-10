# 시스템 관제 자동화 스크립트 개발

> 리눅스 서버를 운영자 관점에서 직접 설계한 프로젝트입니다. SSH 하드닝과 방화벽 정책부터 역할 기반 계정·ACL 설계, 애플리케이션 실행 환경 고정, 그리고 프로세스·포트·리소스를 수집해 로그로 남기는 관제 스크립트(`monitor.sh`)와 cron 자동화까지 구성하고, 각 단계를 명령어 출력으로 검증했습니다.

---

## 프로젝트 개요

| 항목 | 내용 |
|------|------|
| **과제명** | 시스템 관제 자동화 스크립트 개발 |
| **실행 환경** | Ubuntu 24.04.4 LTS (WSL2, systemd 활성), x86_64, 8 vCPU, RAM 3,832 MB |
| **대상 애플리케이션** | `agent-app-linux-x86` (PyInstaller 패키징 Python 바이너리) |
| **실행 계정** | `agent-admin` (uid 1001, root 실행 불가) |
| **자동화 언어** | Bash |
| **최종 산출물** | 수행 내역서(이 문서) + `monitor.sh` + 재현 스크립트 + 증거 로그 9종 |

---

## 필수 증거 자료 체크리스트

과제가 요구하는 8개 항목을 모두 명령어 출력으로 남겼습니다. 모든 증거는 [`logs/`](./logs)에 원본 그대로 저장되어 있습니다.

| # | 확인 항목 | 결과 | 증거 |
|:-:|-----------|:----:|------|
| 1 | SSH 포트 변경(20022) 및 Root 원격 접속 차단 | 완료 | [01-ssh.txt](./logs/01-ssh.txt) |
| 2 | 방화벽 활성화 및 20022/tcp, 15034/tcp만 허용 | 완료 | [02-firewall.txt](./logs/02-firewall.txt) |
| 3 | 계정/그룹(agent-admin/dev/test, agent-common/core) 생성 | 완료 | [03-accounts.txt](./logs/03-accounts.txt) |
| 4 | 디렉토리 구조 및 권한(ACL 포함) | 완료 | [04-permissions.txt](./logs/04-permissions.txt) |
| 5 | 앱 Boot Sequence 5단계 [OK] 및 "Agent READY" | 완료 | [05-boot-sequence.txt](./logs/05-boot-sequence.txt) |
| 6 | monitor.sh 실행 결과(프로세스/포트/리소스/경고) | 완료 | [06-monitor-run.txt](./logs/06-monitor-run.txt) |
| 7 | `/var/log/agent-app/monitor.log` 누적 기록 | 완료 | [07-monitor-log.txt](./logs/07-monitor-log.txt) |
| 8 | crontab 매분 실행 등록 및 자동 실행 확인 | 완료 | [08-cron.txt](./logs/08-cron.txt) |
| + | 로그 보존 정책(10MB / 10개) 동작 검증 | 완료 | [09-log-rotation.txt](./logs/09-log-rotation.txt) |

---

## 1. 기본 보안 및 네트워크 설정

구성 스크립트: [`scripts/setup-security.sh`](./scripts/setup-security.sh)

### 1-1. SSH 하드닝

```bash
# 기존 Port / PermitRootLogin 줄을 전부 제거하고 한 줄씩만 다시 넣는다
sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+/d'        /etc/ssh/sshd_config
sed -i -E '/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]+/d'   /etc/ssh/sshd_config
printf 'Port 20022\nPermitRootLogin no\n' >> /etc/ssh/sshd_config

mkdir -p /run/sshd && sshd -t          # 문법 검사
systemctl daemon-reload && systemctl restart ssh.socket
```

```
$ sshd -T | grep -E '^(port|permitrootlogin) '
port 20022
permitrootlogin no

$ ss -tulnp | grep 20022
tcp LISTEN 0 4096 0.0.0.0:20022 0.0.0.0:*  users:(("systemd",pid=1,fd=94))
```

구현하면서 걸렸던 두 가지입니다.

- **`Port`는 덮어쓰기가 아니라 누적 지시자입니다.** 기존 줄을 남긴 채 새 줄만 추가하면 22번과 20022번이 **동시에** 열립니다. 포트를 옮긴 의미가 사라지므로 기존 줄을 먼저 제거했습니다.
- **Ubuntu 22.04부터 sshd는 소켓 활성화로 뜹니다.** 리슨 소유자가 `sshd`가 아니라 `systemd`(pid=1)인 이유입니다. `ssh.socket`의 `ListenStream`은 제너레이터가 `sshd_config`를 읽어 만들어내므로, 포트를 바꾼 뒤 `systemctl daemon-reload` 없이 서비스만 재시작하면 여전히 22번을 듣습니다.

> [!NOTE]
> **왜 기본 보안인가.** 22번은 인터넷 전역 스캐너의 기본 표적이라 포트를 옮기는 것만으로 자동화된 무차별 대입 시도 대부분이 걸러집니다. 다만 이는 은닉이지 인증 강화가 아니므로, "root라는 이름을 이미 아는" 공격자에게 가장 값진 계정을 내주지 않도록 `PermitRootLogin no`를 함께 걸어야 합니다. 일반 계정 로그인 후 `sudo`를 거치게 하면 누가 무엇을 했는지도 감사 로그에 남습니다.

### 1-2. 방화벽(UFW)

```bash
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp        # SSH
ufw allow 15034/tcp        # APP
ufw --force enable
```

```
$ ufw status verbose
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
20022/tcp                  ALLOW IN    Anywhere
15034/tcp                  ALLOW IN    Anywhere
20022/tcp (v6)             ALLOW IN    Anywhere (v6)
15034/tcp (v6)             ALLOW IN    Anywhere (v6)
```

규칙을 더하기 전에 `default deny incoming`을 먼저 세우는 순서가 핵심입니다. 기본 정책이 allow인 상태에서 allow 규칙만 추가하면 아무것도 막지 못합니다. `--force reset`으로 시작해 매번 같은 결과가 나오도록 만들었습니다.

---

## 2. 계정 / 그룹 / 권한 체계

구성 스크립트: [`scripts/setup-agent.sh`](./scripts/setup-agent.sh)

### 2-1. 역할 분리

| 계정 | uid | 역할 | 소속 그룹 |
|------|:---:|------|-----------|
| `agent-admin` | 1001 | 운영/관리, cron 실행자 | `agent-common`, `agent-core` |
| `agent-dev` | 1002 | 개발/운영, `monitor.sh` 작성자 | `agent-common`, `agent-core` |
| `agent-test` | 1003 | QA/테스트 | `agent-common` |

| 그룹 | gid | 성격 | 구성원 |
|------|:---:|------|--------|
| `agent-common` | 1002 | 협업용 공유 영역 | admin, dev, test |
| `agent-core` | 1003 | 보안 영역 (최소 권한) | admin, dev |

### 2-2. 디렉토리와 권한

| 경로 | 소유자:그룹 | 모드 | ACL | 의도 |
|------|-------------|:----:|-----|------|
| `/home/agent-admin` | `agent-admin:agent-admin` | 750 | `g:agent-common:x` | 상위 통과만 허용 (목록 조회는 불가) |
| `$AGENT_HOME` | `agent-admin:agent-common` | 750 | – | 세 계정 모두 하위로 진입 가능 |
| `$AGENT_HOME/upload_files` | `agent-admin:agent-common` | 770 | `g:agent-common:rwx` (+default) | 공유 R/W |
| `$AGENT_HOME/api_keys` | `agent-admin:agent-core` | 770 | `g:agent-core:rwx` (+default) | 보안 R/W, test 차단 |
| `$AGENT_HOME/bin` | `agent-dev:agent-core` | 750 | – | 스크립트 작성자 소유 |
| `/var/log/agent-app` | `agent-admin:agent-core` | 770 | `g:agent-core:rwx` (+default) | 보안 R/W, test 차단 |
| `$AGENT_HOME/bin/monitor.sh` | `agent-dev:agent-core` | 750 | – | 작성자 dev, 실행자 admin |

> [!IMPORTANT]
> **하위 권한만 열어서는 접근이 되지 않습니다.** `$AGENT_HOME`이 `/home/agent-admin`(모드 750) 안에 있기 때문에, `upload_files`를 770으로 열어도 `agent-test`는 상위 디렉토리를 통과(`x`)하지 못해 `Permission denied`를 받습니다. 실제로 첫 구성에서 이 문제를 만났습니다.
>
> 홈을 755로 바꾸면 시스템의 모든 계정이 홈 내용을 들여다볼 수 있으므로, ACL로 `agent-common`에게 **실행 비트만** 부여했습니다. `r`을 주지 않았으므로 홈 디렉토리 목록 조회는 여전히 막힙니다. 필요한 권한만 최소로 여는 것이 ACL을 쓰는 이유입니다.
>
> ```bash
> setfacl -m g:agent-common:x /home/agent-admin
> ```

기본 ACL(`setfacl -d`)까지 건 이유는, 앞으로 만들어질 파일도 같은 그룹 권한을 자동으로 물려받게 하기 위해서입니다. 그렇지 않으면 새 파일마다 `chmod`를 반복해야 하고, 한 번 빠뜨리는 순간 협업이 깨집니다.

### 2-3. 권한 정책 실증

설계대로 동작하는지 계정을 바꿔가며 실제로 시도한 결과입니다. ([04-permissions.txt](./logs/04-permissions.txt))

| 시도 | 기대 | 결과 |
|------|------|------|
| `agent-test` → `upload_files`에 파일 생성 | 허용 | `-rw-rw----+ agent-test agent-test .../from-test.tmp` |
| `agent-test` → `api_keys` 목록 조회 | 차단 | `ls: cannot open directory ...: Permission denied` |
| `agent-test` → `monitor.log` 읽기 | 차단 | `cat: ...: Permission denied` |
| `agent-dev` → `secret.key` 읽기 | 허용 | `agent_api_key_test` |
| `agent-test` → `monitor.sh` 실행 | 차단 | `bash: ...: Permission denied` |

---

## 3. 애플리케이션 실행 환경 구성

### 3-1. 환경 변수

[`scripts/agent-env.sh`](./scripts/agent-env.sh)에 정의하고 `/etc/profile.d/agent-app.sh`로 배포했습니다.

```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys        # 파일이 아니라 디렉토리 (아래 참고)
export AGENT_LOG_DIR=/var/log/agent-app
export AGENT_APP_BIN=$AGENT_HOME/agent-app-linux-x86
```

**한 곳에 정의해 두 경로로 주입합니다.** 로그인 셸은 `/etc/profile`이 `profile.d`를 자동으로 읽고, cron은 최소 환경(`HOME`/`PATH`/`SHELL`)만 넘겨주므로 `monitor.sh`가 같은 파일을 직접 `source`합니다. 이렇게 고정해 두지 않으면 "내 셸에서는 되는데 cron에서는 실패한다"는 전형적인 사고가 납니다. 검증은 `su - agent-admin -c 'env | grep ^AGENT_'`로 했습니다.

### 3-2. 명세와 실제 바이너리의 차이 (실험으로 규명)

과제 명세는 `AGENT_KEY_PATH`를 키 **파일** 경로(`$AGENT_HOME/api_keys/t_secret.key`)로 안내하지만, 제공된 바이너리는 이 값을 키 **디렉토리**로 해석합니다. 명세대로 넣으면 부트 2단계에서 실패합니다.

| `AGENT_KEY_PATH` 값 | 부트 2단계 결과 |
|---------------------|-----------------|
| `$AGENT_HOME/api_keys/t_secret.key` (명세) | `[FAIL] Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys` |
| `$AGENT_HOME/api_keys` | `[OK] All required Envs correct` |

디렉토리 안에서 실제로 읽는 파일명도 `t_secret.key`가 아니라 **`secret.key`** 입니다.

| 키 파일 상태 | 부트 3단계 결과 |
|--------------|-----------------|
| `t_secret.key`만 존재 | `[FAIL] Missing File: secret.key` |
| `secret.key` 내용이 다름 | `[FAIL] Invalid Content in secret.key (Expected: 'agent_api_key_test', Found: ...)` |
| `secret.key` = `agent_api_key_test` | `[OK] Verified 'secret.key' with correct key string.` |

그래서 `setup-agent.sh`는 **같은 내용으로 두 파일을 모두 생성**합니다. `secret.key`는 앱이 실제로 읽는 파일이고, `t_secret.key`는 명세에 적힌 이름이라 함께 남겼습니다.

나머지 변수도 조합을 바꿔가며 확인했습니다.

| 조건 | 결과 |
|------|------|
| `AGENT_PORT` 미설정 | `[FAIL] Missing Env: AGENT_PORT` — 필수 |
| `AGENT_LOG_DIR` 미설정 | `[OK]` — 기본값 `/var/log/agent-app` 사용. 명시 지정이 권장됨 |
| root로 실행 | `[FAIL] Error: Running as 'root' is forbidden.` — 1단계에서 차단 |

### 3-3. 부트 시퀀스

```
$ /home/agent-admin/agent-app/agent-app-linux-x86      # agent-admin 계정
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1001)
[2/5] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/5] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]
   ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY

$ ss -tulnp | grep 15034
tcp LISTEN 0 1 0.0.0.0:15034 0.0.0.0:*  users:(("agent-app-linux",pid=22736,fd=4))

$ ps -o pid,ppid,user,comm,args -p $(pgrep -x agent-app-linux | paste -sd,)
    PID    PPID USER     COMMAND         COMMAND
  22731   22525 agent-a+ agent-app-linux .../agent-app-linux-x86     <- 부트로더 부모
  22736   22731 agent-a+ agent-app-linux .../agent-app-linux-x86     <- 실제 워커 (포트 소유)
```

앱은 PyInstaller 바이너리라 **부트로더 부모 → 실제 워커 자식** 2단 구조로 뜨고, 포트를 실제로 여는 쪽은 자식입니다. 이 사실은 `monitor.sh`의 PID 판정에도 영향을 줍니다(4-2절).

---

## 4. 시스템 관제 자동화 스크립트 (`monitor.sh`)

소스: [`scripts/monitor.sh`](./scripts/monitor.sh) → 배포 위치 `$AGENT_HOME/bin/monitor.sh` (`agent-dev:agent-core`, 750)

```
$ su - agent-admin -c '$AGENT_HOME/bin/monitor.sh'
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app-linux-x86'... [OK] (PID: 22731)
Checking port 15034... [OK]

[RESOURCE MONITORING]
CPU Usage  : 0.1%
MEM Usage  : 13.8%
DISK Used  : 1%

[WARNING] MEM threshold exceeded (13.8% > 10%)

[INFO] Log appended: /var/log/agent-app/monitor.log
```

### 4-1. 동작 흐름

| 단계 | 내용 | 실패 시 |
|------|------|---------|
| Health Check | 앱 프로세스 존재, TCP 15034 LISTEN | **`exit 1`** (즉시 종료) |
| 상태 점검 | 방화벽 활성 여부 | `[WARNING]` 출력 후 계속 진행 |
| 자원 수집 | CPU / MEM / DISK(root) 사용률 | – |
| 임계값 경고 | CPU>20%, MEM>10%, DISK>80% | `[WARNING]` 출력 후 계속 진행 |
| 로그 기록 | `monitor.log`에 한 줄 추가 | – |

"실패 시 종료"와 "경고만"을 나눈 기준은 **뒤 단계의 의미가 남아 있는가**입니다. 앱이 죽었으면 그 시점의 CPU·메모리 수치는 앱과 무관한 값이라 기록할 가치가 없지만, 방화벽이 꺼진 것은 관제 자체를 무의미하게 만들지 않으므로 알리고 계속 진행합니다.

### 4-2. 구현에서 다룬 문제들

**감시 대상 PID 선정 — `pgrep -f`는 래퍼까지 잡습니다.**
`pgrep -f agent-app-linux-x86`은 cmdline 전체를 훑기 때문에 앱을 실행한 `su`나 `bash -c` 래퍼까지 함께 걸립니다. 커널이 `comm`을 15자로 자른다는 점을 이용해, 잘린 이름과 정확히 일치하는 프로세스만 고르도록 `pgrep -x`를 씁니다. 그다음 PyInstaller 2단 구조에서 대표 PID는 **부모**(PPID가 이 집합에 없는 프로세스)로 잡습니다.

```bash
app_pids() { pgrep -x "${APP_NAME:0:15}"; }
```

**CPU 사용률 — `top -bn1`의 첫 스냅샷은 부팅 이후 평균입니다.**
1회 실행하는 스크립트에서 `top -bn1`을 쓰면 지금 부하가 아니라 누적 평균을 읽게 되어 순간 스파이크를 놓칩니다. `/proc/stat`의 누적 jiffies를 1초 간격으로 두 번 읽어 **구간 사용률**을 직접 계산했습니다.

**메모리 사용률 — 캐시를 사용 중으로 세지 않습니다.**
`free`의 used 대신 `MemAvailable` 기준으로 `(MemTotal - MemAvailable) / MemTotal`을 씁니다. 페이지 캐시와 버퍼는 필요할 때 회수되는 메모리라 사용 중으로 세면 상시 90%대가 찍혀 임계값이 무의미해집니다.

**방화벽 점검 — `ufw status`는 root 전용입니다.**
cron 실행자는 `agent-admin`이므로 `ufw status`가 `ERROR: You need to be root`로 실패합니다. cron에는 tty가 없어 `sudo`도 쓸 수 없습니다. 일반 계정이 읽을 수 있는 두 근거로 대체 판정했습니다.

```bash
grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf && systemctl is-active --quiet ufw
```

**실수 비교 — `[ ]`로는 소수점을 비교할 수 없습니다.**
`[ "15.7" -gt 10 ]`은 정수가 아니라며 실패합니다. 소수점을 버리고 정수 비교하면 경계값에서 판정이 틀어지므로, 비교를 `awk`에 맡겼습니다.

```bash
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
```

**환경 변수 우선순위 — cron 환경과 테스트를 동시에 만족시키기.**
`monitor.sh`는 cron의 최소 환경을 보완하려고 환경 파일을 직접 읽지만, 그러면 호출자가 넘긴 값이 덮어써져 테스트가 불가능해집니다. 호출 시점의 값을 먼저 떠 두고 파일을 읽은 뒤 되돌리는 방식으로 **호출자 우선**을 만들었습니다.

```bash
_caller_env=$(declare -p AGENT_HOME AGENT_PORT AGENT_LOG_DIR AGENT_APP_BIN 2>/dev/null || true)
[ -r "${AGENT_ENV_FILE}" ] && . "${AGENT_ENV_FILE}"
eval "${_caller_env}"
```

덕분에 `AGENT_LOG_DIR=/tmp/rotate-demo monitor.sh`처럼 실제 로그를 건드리지 않고 로테이션을 검증할 수 있습니다.

### 4-3. 임계값 경고 검증

세 분기를 모두 실제로 발동시켜 확인했습니다. ([06-monitor-run.txt](./logs/06-monitor-run.txt))

| 분기 | 검증 방법 | 출력 |
|------|-----------|------|
| CPU > 20% | 전 코어에 busy loop 주입 | `[WARNING] CPU threshold exceeded (100.0% > 20%)` |
| MEM > 10% | 평상시 사용률이 이미 초과 | `[WARNING] MEM threshold exceeded (13.8% > 10%)` |
| DISK > 80% | 사용률 1%라 임계값을 0%로 낮춰 분기 확인 | `[WARNING] DISK threshold exceeded (1% > 0%)` |
| Health Check 실패 | `APP_NAME=no-such-app` 주입 | `[FAIL] Process not running` → `exit 1` |

### 4-4. 로그 포맷

```
[2026-08-10 17:22:18] PID:22731 CPU:4.7% MEM:15.7% DISK_USED:1%
[2026-08-10 17:23:02] PID:22731 CPU:3.7% MEM:20.0% DISK_USED:1%
[2026-08-10 17:24:02] PID:22731 CPU:4.1% MEM:15.5% DISK_USED:1%
```

Health Check에서 걸린 경우에도 침묵하지 않고 사유를 남깁니다. 로그가 비어 있으면 "관제가 안 돈 것"과 "앱이 죽은 것"을 구분할 수 없기 때문입니다.

```
[2026-08-10 17:22:10] [FAIL] process 'no-such-app' not running
```

---

## 5. 자동 실행 (cron)

```bash
$ crontab -u agent-admin -l
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1
```

`monitor.sh`는 `agent-dev` 소유 750이고 그룹이 `agent-core`입니다. `agent-admin`이 `agent-core`에 속하므로 그룹 권한으로 실행되고, `agent-core`가 아닌 `agent-test`는 실행 자체가 막힙니다. **작성자와 실행자를 분리하면서도 실행은 되게** 만드는 것이 이 조합의 목적입니다.

2분 30초를 기다려 자동 누적을 확인했습니다. ([08-cron.txt](./logs/08-cron.txt))

```
2026-08-10 17:22:19    4 lines
2026-08-10 17:24:36    6 lines  (+2)

$ journalctl -u cron | grep agent-admin
CRON[22987]: (agent-admin) CMD (/home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1)
```

---

## 6. 로그 보존 정책

`monitor.sh`가 실행될 때마다 대상 파일 크기를 먼저 확인하고, **10MB를 넘으면 `.1`~`.9`로 밀어낸 뒤 가장 오래된 것을 버려 총 10개를 유지**합니다. logrotate 대신 스크립트 안에 넣은 이유는, 관제 스크립트 자체가 매분 도는 유일한 진입점이라 별도 스케줄러를 추가하지 않아도 되고 실행 계정 권한 안에서 완결되기 때문입니다.

cron이 남기는 `cron.log`도 같은 정책으로 함께 관리합니다. 실제로 이전 구성에서 앱이 내려간 채 cron만 매분 돌아 `cron.log`가 950KB까지 불어난 적이 있는데, 관제 로그만 관리하고 그 옆의 출력 파일을 방치하면 결국 같은 디스크를 채우게 됩니다.

검증 결과입니다. 아카이브 9개가 이미 쌓이고 현재 파일이 10MB를 넘긴 상황을 만든 뒤 실행했습니다. ([09-log-rotation.txt](./logs/09-log-rotation.txt))

| | 실행 전 | 실행 후 |
|---|---|---|
| `monitor.log` | 11 MB | 64 B (새 파일) |
| `monitor.log.1` | `archive-1` | 11 MB (직전 현재 파일) |
| `monitor.log.9` | `archive-9` | `archive-8` (한 칸씩 밀림) |
| 총 파일 수 | 10 | **10** (가장 오래된 `archive-9` 삭제) |

---

## 재현 방법

```bash
# 1. SSH 하드닝 + 방화벽    (root)
sudo bash scripts/setup-security.sh

# 2. 계정/그룹/디렉토리/ACL/환경변수/앱/monitor.sh/cron    (root)
sudo bash scripts/setup-agent.sh

# 3. 앱 실행 (agent-admin 으로 내려가 실행, 종료는 Ctrl+C)
sudo bash scripts/run-app.sh

# 4. 관제 스크립트 수동 실행
sudo su - agent-admin -c '$AGENT_HOME/bin/monitor.sh'

# 5. 증거 자료 일괄 수집 (앱 기동 -> 관제 -> cron 2분 관찰 -> 앱 종료, 약 3분)
sudo bash scripts/collect-evidence.sh
```

두 setup 스크립트는 멱등하게 작성해 몇 번을 다시 실행해도 같은 상태로 수렴합니다.

---

## 디렉토리 구조

```
B1-1.linux-system-monitor/
├── scripts/
│   ├── setup-security.sh      # SSH 포트 20022 + Root 차단 + UFW 정책
│   ├── setup-agent.sh         # 계정/그룹/디렉토리/ACL/키/환경변수/앱/cron
│   ├── agent-env.sh           # 환경 변수 정의 (-> /etc/profile.d/agent-app.sh)
│   ├── monitor.sh             # ★ 시스템 관제 자동화 스크립트 (제출 대상)
│   ├── run-app.sh             # 앱 실행/종료 헬퍼 (agent-admin 으로 실행)
│   └── collect-evidence.sh    # 증거 자료 일괄 수집
├── logs/
│   ├── 01-ssh.txt             # SSH 포트/Root 차단/리슨 상태
│   ├── 02-firewall.txt        # UFW 정책
│   ├── 03-accounts.txt        # 계정/그룹
│   ├── 04-permissions.txt     # 디렉토리 권한/ACL/접근 통제 실증
│   ├── 05-boot-sequence.txt   # 부트 5단계 + Agent READY + LISTEN
│   ├── 06-monitor-run.txt     # monitor.sh 실행 결과 및 경고 분기 검증
│   ├── 07-monitor-log.txt     # monitor.log 누적
│   ├── 08-cron.txt            # crontab 등록 및 자동 실행 확인
│   └── 09-log-rotation.txt    # 로그 보존 정책 동작 검증
├── agent-app/                 # 제공된 애플리케이션 바이너리
└── README.md                  # 요구사항 수행 내역서 (이 문서)
```

---

## 배포 대상 시스템 경로

| 경로 | 내용 |
|------|------|
| `/etc/ssh/sshd_config` | `Port 20022`, `PermitRootLogin no` |
| `/etc/profile.d/agent-app.sh` | `AGENT_*` 환경 변수 |
| `/home/agent-admin/agent-app/` | `AGENT_HOME` (앱 바이너리, `upload_files`, `api_keys`, `bin`) |
| `/home/agent-admin/agent-app/bin/monitor.sh` | 관제 스크립트 (`agent-dev:agent-core`, 750) |
| `/var/log/agent-app/monitor.log` | 관제 로그 (10MB / 10개 유지) |
| `/var/spool/cron/crontabs/agent-admin` | 매분 실행 등록 |

---

## 학습 정리

| 과제 목표 | 확인한 내용 |
|-----------|-------------|
| SSH 포트 변경과 Root 차단이 왜 기본 보안인가 | 포트 이동은 자동 스캐너를 걸러내는 은닉이고, Root 차단은 "이름이 이미 알려진 최고 권한 계정"을 원격 인증 대상에서 제외하는 조치. 둘은 대체재가 아니라 보완재. `Port`가 누적 지시자라는 점, 소켓 활성화 환경에서 `daemon-reload`가 필요하다는 점을 실패로 확인 |
| 필요 포트만 허용하는 방화벽 구성과 검증 | 기본 정책(deny incoming)을 먼저 세운 뒤 예외를 더하는 순서가 핵심. `ufw status verbose`로 기본 정책과 개별 규칙을 함께 확인해야 "규칙은 있는데 다 열려 있는" 상태를 잡아낼 수 있음 |
| 공유 디렉토리와 보안 디렉토리를 나누는 이유 | 협업(`agent-common`)과 최소 권한(`agent-core`)을 그룹으로 분리하고, 상위 디렉토리 통과 권한은 ACL로 `x`만 최소 부여. 하위 권한만 열어서는 접근이 되지 않는다는 것을 `Permission denied`로 직접 확인. 기본 ACL로 이후 생성 파일까지 정책을 상속 |
| 환경 변수로 실행 환경을 고정하는 이유와 검증 | 정의는 한 곳(`agent-env.sh`), 주입은 두 경로(로그인 셸 `profile.d` / cron은 스크립트가 직접 source). 앱이 `AGENT_KEY_PATH`를 명세와 다르게 해석한다는 사실도 환경 변수 조합 실험으로 규명 |
| 쉘 스크립트로 상태를 수집하고 로그로 추적하는 흐름 | Health Check(치명적) 와 경고(비치명적)를 종료 여부로 구분. `/proc/stat` 구간 계산, `MemAvailable` 기준, `pgrep -x`로 래퍼 배제 등 "지표를 정확히 재는 것" 자체가 관제의 절반임을 확인 |
| cron 주기 실행과 로그 보존 정책의 필요성 | cron은 tty도 환경 변수도 없다는 전제로 스크립트를 짜야 함(`sudo ufw` 불가). 보존 정책이 없으면 관제가 오히려 디스크를 채우는 장애 원인이 된다는 것을 950KB까지 불어난 `cron.log`로 확인 |

---

## 주의 사항

- **root 실행 금지** — 앱은 부트 1단계에서 실행 계정을 검사합니다. `agent-admin`으로만 실행합니다
- **`AGENT_KEY_PATH`는 디렉토리** — 명세의 파일 경로를 그대로 넣으면 부트 2단계에서 실패합니다 (3-2절)
- **포트 15034 단독 점유** — 앱을 중복 기동하면 부트 4단계(Port Availability)에서 실패합니다
- **cron 자동 실행 중** — `monitor.sh`가 매분 도는 상태이므로, 앱이 내려가 있으면 `monitor.log`에 `[FAIL]` 라인이 계속 쌓입니다. 정상 동작이며 보존 정책이 크기를 제한합니다
- **B1-2와 환경 공유** — 계정·그룹·ACL·로그 디렉토리는 [B1-2](../B1-2.linux-troubleshooting)에서 그대로 재사용합니다
