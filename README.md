# Linux 서버 보안 및 관제 자동화

리눅스 서버의 **보안 설정, 사용자 권한 관리, 애플리케이션 실행, 상태 점검**을 자동화한 프로젝트입니다. SSH와 방화벽을 구성하고 계정별 접근 권한을 나눈 뒤, 앱의 프로세스·포트·CPU·메모리·디스크 사용량을 매분 확인해 로그로 남깁니다.

> **서버 보호 → 사용자별 권한 분리 → 앱 실행 → 1분마다 상태 점검 → 로그 자동 정리**

[빠른 실행](#빠른-실행) · [구성 요소와 동작](#구성-요소와-동작) · [검증 결과](#검증-결과) · [핵심 설계 결정](#핵심-설계-결정)

---

## 프로젝트 한눈에 보기

| 순서 | 자동화한 일 | 결과 |
|:----:|-------------|------|
| 1 | **서버 보호** | SSH 접속 포트를 `20022`로 변경하고 Root 로그인을 막습니다. 방화벽은 SSH와 앱 포트만 엽니다. |
| 2 | **권한 분리** | 운영자·개발자·테스트 계정을 나누고, 각 계정이 필요한 파일에만 접근하도록 제한합니다. |
| 3 | **앱 실행** | 실행 환경을 한 곳에서 관리하고, Root가 아닌 `agent-admin` 계정으로 앱을 실행합니다. |
| 4 | **상태 점검** | 앱 프로세스와 포트를 확인하고 CPU·메모리·디스크 사용률이 기준을 넘으면 경고합니다. |
| 5 | **자동 관리** | 1분마다 상태를 점검하고, 로그가 커지면 오래된 파일부터 자동으로 정리합니다. |

모든 과정은 Bash 스크립트로 다시 실행할 수 있으며, 정상 동작과 실패 상황을 [9개의 원본 로그](./logs)로 검증했습니다.

**실행 환경:** Ubuntu 24.04.4 LTS (WSL2, systemd) · x86_64 · Bash · UFW · cron · POSIX ACL

---

## 관제 결과 예시

```text
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

---

## 빠른 실행

> [!CAUTION]
> `setup-security.sh`를 실행하면 기존 방화벽 규칙을 지우고 이 프로젝트에 필요한 규칙으로 다시 설정하며, SSH 접속 포트를 `20022`로 변경합니다. SSH로 원격 접속 중이라면 연결이 끊기거나 다시 접속하지 못할 수 있으므로, 클라우드 웹 콘솔처럼 **SSH 없이 서버에 접속할 방법**을 준비한 뒤 실행하세요. 기존 SSH 설정 파일은 자동으로 백업됩니다.

### 필수 실행: 3단계

#### 1. 서버 보안과 앱 실행 환경 구성

SSH·방화벽을 먼저 설정한 뒤 계정·권한·환경 변수·앱·cron을 배포합니다.

```bash
sudo bash scripts/setup-security.sh
sudo bash scripts/setup-agent.sh
```

> 이미 설정을 마친 뒤 다시 실행해도 계정이나 방화벽 규칙이 중복으로 추가되지 않으며, 기존 설정이 같은 상태로 유지됩니다.

#### 2. 애플리케이션 실행

`agent-admin` 계정으로 앱을 백그라운드에서 실행합니다.

```bash
sudo bash scripts/run-app.sh --detach
```

출력 마지막에 **`Agent READY`**가 표시되면 정상입니다.

#### 3. 관제 동작 확인

관제 스크립트를 한 번 직접 실행해 프로세스·포트·자원 사용량을 확인합니다.

```bash
sudo su - agent-admin -c '$AGENT_HOME/bin/monitor.sh'
```

프로세스와 포트에 **`[OK]`**가 표시되고, 마지막에 **`Log appended`**가 나오면 정상입니다. 이후 cron이 같은 점검을 1분마다 자동 실행합니다.

### 필요할 때 사용하는 명령

**실시간 관제 로그 확인**

```bash
sudo tail -f /var/log/agent-app/monitor.log
```

**전체 검증 결과 다시 수집** — 약 3분이 걸리며 `logs/*.txt`를 갱신합니다.

```bash
sudo bash scripts/collect-evidence.sh
```

**백그라운드 앱 종료**

```bash
sudo bash scripts/run-app.sh --stop
```

---

## 구성 요소와 동작

| 파일 | 역할 |
|------|------|
| [`setup-security.sh`](./scripts/setup-security.sh) | SSH 접속 설정과 방화벽 정책 구성 |
| [`setup-agent.sh`](./scripts/setup-agent.sh) | 계정·권한·환경 변수·앱·관제 스크립트·cron 배포 |
| [`agent-env.sh`](./scripts/agent-env.sh) | 앱이 사용할 경로와 포트 정의 |
| [`run-app.sh`](./scripts/run-app.sh) | `agent-admin` 계정으로 앱 실행·종료 |
| [`monitor.sh`](./scripts/monitor.sh) | 앱 상태와 서버 자원을 점검하고 로그 기록 |
| [`collect-evidence.sh`](./scripts/collect-evidence.sh) | 전체 검증 과정을 실행하고 결과 수집 |

```text
보안 설정 → 계정·앱 배포 → 앱 실행 → cron이 monitor.sh를 매분 실행 → 로그 기록·정리
```

### 보안과 권한 정책

| 대상 | 정책 | 목적 |
|------|------|------|
| SSH | `Port 20022`, `PermitRootLogin no` | 기본 스캔 노출을 줄이고 최고 권한 계정의 직접 로그인을 차단 |
| UFW | incoming 기본 차단, `20022/tcp`·`15034/tcp`만 허용 | 필요한 진입점만 명시적으로 개방 |
| `agent-admin` | 운영·관리, 앱과 cron 실행 | 서비스 실행 주체 |
| `agent-dev` | `monitor.sh` 소유·수정 | 작성자와 실행자 분리 |
| `agent-test` | 공유 업로드 영역만 접근 | 보안 파일·로그·관제 스크립트 접근 차단 |

주요 디렉토리 권한은 다음과 같습니다.

| 경로 | 소유자:그룹 | 모드 | 접근 정책 |
|------|-------------|:----:|-----------|
| `/home/agent-admin` | `agent-admin:agent-admin` | 750 | `agent-common`에 ACL `x`만 부여 |
| `$AGENT_HOME/upload_files` | `agent-admin:agent-common` | 770 | admin·dev·test 공유 R/W, 기본 ACL 상속 |
| `$AGENT_HOME/api_keys` | `agent-admin:agent-core` | 770 | admin·dev만 R/W, test 차단 |
| `$AGENT_HOME/bin` | `agent-dev:agent-core` | 750 | dev 소유, admin 실행 |
| `/var/log/agent-app` | `agent-admin:agent-core` | 770 | admin·dev만 R/W, test 차단 |

### 애플리케이션 환경

환경 변수는 [`scripts/agent-env.sh`](./scripts/agent-env.sh) 한 곳에서 관리하고 `/etc/profile.d/agent-app.sh`로 배포합니다.

| 변수 | 값 |
|------|----|
| `AGENT_HOME` | `/home/agent-admin/agent-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` |
| `AGENT_LOG_DIR` | `/var/log/agent-app` |
| `AGENT_APP_BIN` | `$AGENT_HOME/agent-app-linux-x86` |

로그인 셸은 `profile.d`를 통해, 최소 환경만 제공하는 cron은 `monitor.sh`가 환경 파일을 직접 읽는 방식으로 같은 값을 사용합니다.

### 관제 정책

| 단계 | 확인 내용 | 비정상일 때 |
|------|-----------|-------------|
| Health Check | 앱 프로세스와 TCP `15034` LISTEN | 실패 로그를 남기고 `exit 1` |
| 방화벽 점검 | UFW 활성 상태 | 경고 후 계속 진행 |
| 자원 수집 | CPU·메모리·루트 디스크 사용률 | 측정값 출력 |
| 임계값 판정 | CPU > 20%, MEM > 10%, DISK > 80% | 경고 후 계속 진행 |
| 로그 기록 | PID와 자원 사용률 | `monitor.log`에 한 줄 추가 |

Health Check는 이후 측정의 전제이므로 실패 시 종료합니다. 방화벽이나 자원 임계값은 앱 상태를 관찰할 가치가 여전히 남아 있어 경고만 기록합니다.

---

## 검증 결과

과제의 필수 항목과 추가 보존 정책을 모두 실제 명령어 출력으로 확인했습니다. 링크된 파일에는 요약되지 않은 원본 출력이 들어 있습니다.

| # | 확인 항목 | 결과 | 원본 증거 |
|:-:|-----------|:----:|-----------|
| 1 | SSH 포트 변경과 Root 원격 접속 차단 | 완료 | [01-ssh.txt](./logs/01-ssh.txt) |
| 2 | UFW 활성화와 허용 포트 제한 | 완료 | [02-firewall.txt](./logs/02-firewall.txt) |
| 3 | 계정·그룹 생성 | 완료 | [03-accounts.txt](./logs/03-accounts.txt) |
| 4 | 디렉토리 권한·ACL·접근 차단 | 완료 | [04-permissions.txt](./logs/04-permissions.txt) |
| 5 | 앱 Boot Sequence 5단계와 `Agent READY` | 완료 | [05-boot-sequence.txt](./logs/05-boot-sequence.txt) |
| 6 | 관제 실행과 모든 경고 분기 | 완료 | [06-monitor-run.txt](./logs/06-monitor-run.txt) |
| 7 | `monitor.log` 누적 | 완료 | [07-monitor-log.txt](./logs/07-monitor-log.txt) |
| 8 | crontab 등록과 자동 실행 | 완료 | [08-cron.txt](./logs/08-cron.txt) |
| + | 10MB·10개 로그 보존 | 완료 | [09-log-rotation.txt](./logs/09-log-rotation.txt) |

### 주요 검증 요약

<details>
<summary><strong>앱 부트와 포트 LISTEN</strong></summary>

```text
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]
All Boot Checks Passed!
Agent READY

tcp LISTEN 0 1 0.0.0.0:15034 0.0.0.0:*
```

</details>

<details>
<summary><strong>접근 제어 실증</strong></summary>

| 시도 | 기대 | 결과 |
|------|:----:|------|
| `agent-test`가 `upload_files`에 파일 생성 | 허용 | 생성 성공, 기본 ACL 상속 |
| `agent-test`가 `api_keys` 조회 | 차단 | `Permission denied` |
| `agent-test`가 `monitor.log` 읽기 | 차단 | `Permission denied` |
| `agent-dev`가 `secret.key` 읽기 | 허용 | 읽기 성공 |
| `agent-test`가 `monitor.sh` 실행 | 차단 | `Permission denied` |

</details>

<details>
<summary><strong>관제 경고와 실패 분기</strong></summary>

| 분기 | 검증 방법 | 확인 결과 |
|------|-----------|-----------|
| CPU > 20% | 전 코어에 busy loop 주입 | CPU 경고 발생 |
| MEM > 10% | 평상시 사용률로 확인 | 메모리 경고 발생 |
| DISK > 80% | 테스트 시 임계값을 0%로 주입 | 디스크 경고 발생 |
| 프로세스 없음 | `APP_NAME=no-such-app` 주입 | 실패 로그 후 `exit 1` |

</details>

<details>
<summary><strong>cron과 로그 보존</strong></summary>

`agent-admin`의 crontab에 아래 항목을 등록하고, 2분 30초 동안 로그가 두 번 추가되는 것을 확인했습니다.

```cron
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1
```

로그가 10MB를 넘으면 현재 파일을 `.1`로 옮기고 기존 아카이브를 한 칸씩 밀어 `.9`까지 유지합니다.

| 항목 | 실행 전 | 실행 후 |
|------|---------|---------|
| `monitor.log` | 11MB | 새 로그 파일 |
| `monitor.log.1` | `archive-1` | 직전 11MB 파일 |
| `monitor.log.9` | `archive-9` | `archive-8` |
| 총 파일 수 | 10 | **10** |

</details>

---

## 핵심 설계 결정

완성 결과보다 구현 이유가 중요한 내용만 남겼습니다. 세부 명령어와 전체 출력은 각 스크립트와 [`logs/`](./logs)에서 확인할 수 있습니다.

<details>
<summary><strong>1. SSH 설정을 추가하지 않고 기존 지시자를 제거한 이유</strong></summary>

`Port`는 마지막 값으로 단순 덮어쓰기 되는 설정이 아니라 여러 포트를 동시에 열 수 있는 누적 지시자입니다. 기존 `Port 22`를 남기고 `Port 20022`만 추가하면 두 포트가 모두 열리므로, 기존 `Port`와 `PermitRootLogin` 줄을 제거한 뒤 원하는 값을 한 번만 기록했습니다.

Ubuntu의 소켓 활성화 환경에서는 `systemd`가 SSH 포트를 먼저 엽니다. `sshd_config`를 바꾼 뒤 `systemctl daemon-reload` 없이 서비스만 재시작하면 이전 포트를 계속 들을 수 있어, 문법 검사 후 데몬 설정을 다시 읽고 `ssh.socket`을 재시작합니다.

포트 변경은 자동 스캔 노출을 줄이는 조치이지 인증 강화 자체는 아닙니다. 따라서 최고 권한 계정의 직접 인증을 막는 `PermitRootLogin no`를 함께 적용했습니다.

</details>

<details>
<summary><strong>2. 홈 디렉토리를 755로 열지 않고 ACL을 사용한 이유</strong></summary>

`upload_files`를 770으로 설정해도 상위 경로인 `/home/agent-admin`을 통과할 수 없으면 `agent-test`는 접근하지 못합니다. 홈을 755로 열면 모든 시스템 계정이 목록을 읽을 수 있으므로, `agent-common`에 통과 권한 `x`만 추가했습니다.

```bash
setfacl -m g:agent-common:x /home/agent-admin
```

공유·보안 디렉토리에는 기본 ACL도 설정했습니다. 이후 생성되는 파일이 자동으로 그룹 정책을 상속하므로 파일마다 권한을 다시 수정하는 누락 위험을 줄입니다.

</details>

<details>
<summary><strong>3. 명세와 바이너리의 키 경로 해석 차이를 함께 수용한 이유</strong></summary>

과제 명세는 `AGENT_KEY_PATH`를 `$AGENT_HOME/api_keys/t_secret.key`로 안내하지만, 제공된 바이너리는 이 값을 파일이 아닌 **디렉토리 경로**로 검사하고 그 안의 **`secret.key`**를 읽습니다.

| 설정 | 앱의 실제 반응 |
|------|----------------|
| `$AGENT_HOME/api_keys/t_secret.key` | `Key Path Mismatch` |
| `$AGENT_HOME/api_keys` | 환경 변수 검사 통과 |
| `t_secret.key`만 생성 | `Missing File: secret.key` |
| 올바른 `secret.key` 생성 | 키 파일 검사 통과 |

실행에는 `$AGENT_HOME/api_keys/secret.key`를 사용하되, 명세와의 추적성을 위해 같은 내용의 `t_secret.key`도 함께 생성합니다.

</details>

<details>
<summary><strong>4. 관제 지표와 PID를 직접 판정한 이유</strong></summary>

- **PID:** `pgrep -f`는 앱을 감싼 `su`와 `bash`까지 찾습니다. 커널의 15자 `comm` 이름과 정확히 일치하는 `pgrep -x`로 앱만 선택하고, PyInstaller의 부모·워커 2단 구조에서는 부모 프로세스를 대표 PID로 기록합니다.
- **CPU:** `top -bn1`의 첫 값 대신 `/proc/stat`을 1초 간격으로 두 번 읽어 해당 구간의 사용률을 계산합니다.
- **메모리:** 회수 가능한 캐시를 사용량으로 과대 계산하지 않도록 `(MemTotal - MemAvailable) / MemTotal`을 사용합니다.
- **방화벽:** cron 실행자인 일반 계정은 `ufw status`를 실행할 수 없어 `/etc/ufw/ufw.conf`와 systemd 서비스 상태를 함께 확인합니다.
- **소수 비교:** 셸의 정수 비교 대신 `awk`를 사용해 `15.7 > 10` 같은 임계값을 정확히 판정합니다.

</details>

<details>
<summary><strong>5. cron 환경과 테스트용 환경 변수 주입을 모두 지원한 이유</strong></summary>

cron에는 로그인 셸의 `AGENT_*` 변수가 전달되지 않으므로 `monitor.sh`가 환경 파일을 직접 읽습니다. 다만 무조건 덮어쓰면 테스트 값을 주입할 수 없기 때문에 **호출자가 지정한 값 → 환경 파일 값 → 스크립트 기본값** 순으로 우선순위를 정했습니다.

이 구조 덕분에 실제 운영 로그를 건드리지 않고 다음처럼 분기와 로테이션을 검증할 수 있습니다.

```bash
AGENT_LOG_DIR=/tmp/rotate-demo DISK_THRESHOLD=0 monitor.sh
```

</details>

<details>
<summary><strong>6. logrotate 대신 스크립트에서 보존 정책을 적용한 이유</strong></summary>

`monitor.sh`는 매분 실행되는 고정 진입점이므로 별도 스케줄을 추가하지 않고도 실행 전 로그 크기를 확인할 수 있습니다. 관제 결과인 `monitor.log`뿐 아니라 표준 출력이 쌓이는 `cron.log`에도 같은 정책을 적용해, 관제 기능 자체가 디스크를 채우는 일을 막았습니다.

</details>

---

## 저장소 구조

```text
B1-1.linux-system-monitor/
├── scripts/
│   ├── setup-security.sh      # SSH 하드닝·UFW 구성
│   ├── setup-agent.sh         # 계정·권한·환경·앱·cron 구성
│   ├── agent-env.sh           # AGENT_* 환경 변수 정의
│   ├── monitor.sh             # 시스템 관제 스크립트
│   ├── run-app.sh             # 앱 실행·종료
│   └── collect-evidence.sh    # 증거 자료 일괄 수집
├── logs/                      # 검증 원본 9종
├── agent-app/                 # 제공된 x86·ARM64 바이너리
└── README.md
```

## 배포 경로

| 경로 | 내용 |
|------|------|
| `/etc/ssh/sshd_config` | SSH 포트와 Root 로그인 정책 |
| `/etc/profile.d/agent-app.sh` | `AGENT_*` 환경 변수 |
| `/home/agent-admin/agent-app/` | 앱, 업로드·키·스크립트 디렉토리 |
| `/home/agent-admin/agent-app/bin/monitor.sh` | 배포된 관제 스크립트 |
| `/var/log/agent-app/monitor.log` | 관제 로그 |
| `/var/log/agent-app/cron.log` | cron 표준 출력 |
| `/var/spool/cron/crontabs/agent-admin` | 매분 실행 설정 |

## 주의 사항

- 앱은 Root 실행을 거부하므로 `agent-admin` 계정으로 실행해야 합니다.
- `AGENT_KEY_PATH`는 키 파일이 아니라 키 디렉토리를 가리켜야 합니다.
- 앱을 중복 기동하면 TCP `15034` 포트 점유 검사에서 실패합니다.
- 앱이 내려간 동안에도 cron은 매분 실행되며 `[FAIL]` 로그를 남깁니다. 로그 크기는 보존 정책으로 제한됩니다.
- 이 프로젝트의 계정·그룹·ACL·로그 디렉토리는 [B1-2](../B1-2.linux-troubleshooting)에서도 재사용합니다.
