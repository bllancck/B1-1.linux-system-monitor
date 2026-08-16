# Linux 서버 보안 및 관제 자동화

리눅스 서버의 <b>보안 설정, 사용자 권한 관리, 애플리케이션 실행, 상태 점검</b>을 자동화한 프로젝트입니다. SSH와 방화벽을 구성하고 계정별 접근 권한을 나눈 뒤, 앱의 프로세스·포트·CPU·메모리·디스크 사용량을 매분 확인해 로그로 남깁니다.

> <b>서버 보호 → 사용자별 권한 분리 → 앱 실행 → 1분마다 상태 점검 → 로그 자동 정리</b>

[빠른 실행](#빠른-실행) · [구성과 배포](#구성과-배포) · [검증](#검증) · [핵심 설계 결정](#핵심-설계-결정)

---

## 프로젝트 한눈에 보기

| 순서 | 자동화한 일 | 결과 |
|:----:|-------------|------|
| 1 | <b>서버 보호</b> | SSH 접속 포트를 `20022`로 변경하고 Root 로그인을 막습니다. 방화벽은 SSH와 앱 포트만 엽니다. |
| 2 | <b>권한 분리</b> | 운영자·개발자·테스트 계정을 나누고, 각 계정이 필요한 파일에만 접근하도록 제한합니다. |
| 3 | <b>앱 실행</b> | 실행 환경을 한 곳에서 관리하고, Root가 아닌 `agent-admin` 계정으로 앱을 실행합니다. |
| 4 | <b>상태 점검</b> | 앱 프로세스와 포트를 확인하고 CPU·메모리·디스크 사용률이 기준을 넘으면 경고합니다. |
| 5 | <b>자동 관리</b> | 1분마다 상태를 점검하고, 로그가 커지면 오래된 파일부터 자동으로 정리합니다. |

모든 과정은 Bash 스크립트로 다시 실행할 수 있으며, 정상 동작과 실패 상황을 [9개의 원본 로그](./logs)로 검증했습니다.

### 실행 환경

- **검증 환경:** Ubuntu 24.04.4 LTS (WSL2, systemd) · x86_64 · Bash · UFW · cron · POSIX ACL
- **권장 환경:** Ubuntu 22.04 LTS 이상 · systemd 활성화 · x86_64
- **비권장 환경:** Docker 컨테이너 · systemd가 비활성화된 WSL · macOS · Git Bash
- **미검증 환경:** Debian 계열의 다른 배포판 · ARM64

> x86_64와 ARM64용 앱 바이너리를 모두 제공하지만, 현재 배포·실행·검증 스크립트는 x86_64 바이너리를 기준으로 작성되어 있습니다. ARM64 환경에서는 스크립트의 바이너리 설정을 변경해야 합니다.

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
> `setup-security.sh`를 실행하면 기존 방화벽 규칙을 지우고 이 프로젝트에 필요한 규칙으로 다시 설정하며, SSH 접속 포트를 `20022`로 변경합니다. SSH로 원격 접속 중이라면 연결이 끊기거나 다시 접속하지 못할 수 있으므로, 클라우드 웹 콘솔처럼 <b>SSH 없이 서버에 접속할 방법</b>을 준비한 뒤 실행하세요. 기존 SSH 설정 파일은 자동으로 백업됩니다.

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

출력 마지막에 <b><code>Agent READY</code></b>가 표시되면 정상입니다.

#### 3. 관제 동작 확인

관제 스크립트를 한 번 직접 실행해 프로세스·포트·자원 사용량을 확인합니다.

```bash
sudo su - agent-admin -c '$AGENT_HOME/bin/monitor.sh'
```

프로세스와 포트에 <b><code>[OK]</code></b>가 표시되고, 마지막에 <b><code>Log appended</code></b>가 나오면 정상입니다. 이후 cron이 같은 점검을 1분마다 자동 실행합니다.

### 필요할 때 사용하는 명령

<b>실시간 관제 로그 확인</b>

```bash
sudo tail -f /var/log/agent-app/monitor.log
```

<b>전체 검증 결과 다시 수집</b> — 약 3분이 걸리며 `logs/*.txt`를 갱신합니다.

```bash
sudo bash scripts/collect-evidence.sh
```

<b>백그라운드 앱 종료</b>

```bash
sudo bash scripts/run-app.sh --stop
```

---

## 구성과 배포

### 구성 요소와 역할

| 저장소 경로 | 역할 |
|-------------|------|
| [`setup-security.sh`](./scripts/setup-security.sh) | SSH 접속 설정과 방화벽 정책 구성 |
| [`setup-agent.sh`](./scripts/setup-agent.sh) | 계정·권한·환경 변수·앱·관제 스크립트·cron 배포 |
| [`agent-env.sh`](./scripts/agent-env.sh) | 앱이 사용할 경로와 포트 정의 |
| [`run-app.sh`](./scripts/run-app.sh) | `agent-admin` 계정으로 앱 실행·종료 |
| [`monitor.sh`](./scripts/monitor.sh) | 앱 상태와 서버 자원을 점검하고 로그 기록 |
| [`collect-evidence.sh`](./scripts/collect-evidence.sh) | 전체 검증 과정을 실행하고 결과 수집 |
| [`agent-app/`](./agent-app) | 제공된 x86·ARM64 애플리케이션 바이너리 보관 |
| [`logs/`](./logs) | 검증 과정에서 수집한 실행 기록 보관 |

### 실행 흐름

```text
보안 설정 → 계정·앱 배포 → 앱 실행 → cron이 monitor.sh를 매분 실행 → 로그 기록·정리
```

### 서버 배포 경로

스크립트를 실행하면 저장소의 설정과 파일이 다음 경로에 적용됩니다.

| 서버 경로 | 내용 |
|-----------|------|
| `/etc/ssh/sshd_config` | SSH 포트와 Root 로그인 정책 |
| `/etc/profile.d/agent-app.sh` | `AGENT_*` 환경 변수 |
| `/home/agent-admin/agent-app/` | 앱, 업로드·키·스크립트 디렉토리 |
| `/home/agent-admin/agent-app/bin/monitor.sh` | 배포된 관제 스크립트 |
| `/var/log/agent-app/monitor.log` | 관제 로그 |
| `/var/log/agent-app/cron.log` | cron 실행 결과 |
| `/var/spool/cron/crontabs/agent-admin` | 매분 관제 실행 설정 |

### 보안과 권한 정책

#### 서버 접속 정책

| 대상 | 설정 | 결과 |
|------|------|------|
| SSH | 포트 `20022`, Root 로그인 금지 | 변경된 포트로 일반 계정만 접속 가능 |
| 방화벽 | 들어오는 연결은 기본 차단 | SSH `20022`와 앱 `15034` 포트만 접속 가능 |

#### 사용자와 그룹

사용자를 역할에 따라 나누고, 공유 영역과 보호 영역에 필요한 그룹만 부여했습니다.

| 계정 | 역할 | `agent-common`<br>(공유 영역) | `agent-core`<br>(보호 영역) |
|------|------|:----------------------------:|:--------------------------:|
| `agent-admin` | 앱 운영, cron 실행 | 소속 | 소속 |
| `agent-dev` | 관제 스크립트 작성·수정 | 소속 | 소속 |
| `agent-test` | 업로드 기능 테스트 | 소속 | — |

`agent-common`은 세 계정이 함께 쓰는 업로드 영역에, `agent-core`는 admin과 dev만 사용하는 키·스크립트·로그 영역에 적용됩니다.

#### 주요 디렉토리 권한

| 경로 | 소유자:그룹 | 모드 | 추가 ACL | 용도 |
|------|-------------|:----:|----------|------|
| `/home/agent-admin` | `agent-admin:agent-admin` | 750 | `agent-common:x` | 앱 경로로 이동하기 위한 상위 디렉토리 |
| `$AGENT_HOME` | `agent-admin:agent-common` | 750 | — | 앱 관련 파일의 기준 경로 |
| `$AGENT_HOME/upload_files` | `agent-admin:agent-common` | 770 | `agent-common:rwx` 및 기본 ACL | 세 계정의 공유 파일 영역 |
| `$AGENT_HOME/api_keys` | `agent-admin:agent-core` | 770 | `agent-core:rwx` 및 기본 ACL | 키 파일 보관 |
| `$AGENT_HOME/bin`과 `monitor.sh` | `agent-dev:agent-core` | 750 | — | 관제 스크립트 보관·실행 |
| `/var/log/agent-app` | `agent-admin:agent-core` | 770 | `agent-core:rwx` 및 기본 ACL | 관제 및 cron 로그 보관 |

`750`은 소유자만 수정할 수 있고 그룹은 읽기·실행만 가능하며, `770`은 소유자와 그룹 모두 읽기·쓰기·실행이 가능하다는 뜻입니다. 두 모드 모두 그 외 계정의 접근은 차단합니다.

<details>
<summary><b>계정별로 가능한 작업 보기</b></summary>

| 경로 | admin | dev | test |
|------|:-----:|:---:|:----:|
| `/home/agent-admin` | 조회·이동·수정 | 통과만 가능 | 통과만 가능 |
| `$AGENT_HOME` | 조회·이동·수정 | 조회·이동 | 조회·이동 |
| `$AGENT_HOME/upload_files` | 읽기·쓰기 | 읽기·쓰기 | 읽기·쓰기 |
| `$AGENT_HOME/api_keys` | 읽기·쓰기 | 읽기·쓰기 | 접근 불가 |
| `$AGENT_HOME/bin/monitor.sh` | 읽기·실행 | 읽기·쓰기·실행 | 접근 불가 |
| `/var/log/agent-app` | 읽기·쓰기 | 읽기·쓰기 | 접근 불가 |

</details>

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

사용자가 로그인해 앱을 실행하면 `/etc/profile.d/agent-app.sh`에서 환경 변수를 불러옵니다. cron으로 자동 실행할 때는 로그인 과정이 없으므로 `monitor.sh`가 같은 파일을 직접 불러옵니다. 따라서 수동 실행과 자동 실행에서 동일한 설정을 사용합니다.

### 관제 정책

| 단계 | 확인 내용 | 비정상일 때 | 이유 및 설명 |
|------|-----------|-------------|--------------|
| 상태 확인<br>(Health Check) | 앱 프로세스 실행 여부와 TCP `15034` 포트 | 실패 로그를 남기고 `exit 1` | 앱이 실행 중이고 접속을 받을 준비가 되었는지 확인합니다. 앱이 꺼져 있으면 이후 자원 측정은 의미가 없어 즉시 종료합니다. |
| 방화벽 점검 | UFW 활성 상태 | 경고 후 계속 진행 | 필요한 포트만 허용하는 보안 정책이 유지되는지 확인합니다. 방화벽이 꺼져 있어도 앱 상태는 계속 확인할 수 있으므로 관제를 중단하지 않습니다. |
| 자원 수집 | CPU·메모리·루트 디스크 사용률 | 측정값 출력 | 서버의 과부하나 저장 공간 부족을 판단하는 데 필요한 현재 사용량을 수집합니다. |
| 임계값 판정 | CPU > 20%, MEM > 10%, DISK > 80% | 경고 후 계속 진행 | 기준을 넘은 항목을 즉시 알아볼 수 있도록 경고하되, 다음 측정과 로그 기록은 계속합니다. |
| 로그 기록 | PID와 자원 사용률 | `monitor.log`에 한 줄 추가 | 시간에 따른 사용량 변화를 확인하고 문제가 발생한 시점을 추적할 수 있도록 기록을 남깁니다. |

---

## 검증

핵심 기능은 실제 환경에서 정상 동작과 실패 상황을 모두 확인했습니다. README에는 검증 범위만 요약하고, 전체 명령어 출력은 [`logs/`](./logs)에 분리했습니다.

| 검증 범위 | 확인 내용 | 실행 기록 |
|-----------|-----------|-----------|
| 서버 보안 | SSH 포트 변경, Root 로그인 차단, 방화벽 허용 포트 제한 | [SSH](./logs/01-ssh.txt) · [방화벽](./logs/02-firewall.txt) |
| 접근 제어 | 계정·그룹 생성, 공유 영역 접근, 보호 영역 차단 | [계정·그룹](./logs/03-accounts.txt) · [권한](./logs/04-permissions.txt) |
| 앱 실행 | 부트 검사 5단계 통과, `Agent READY`, TCP `15034` 연결 대기 | [앱 부트](./logs/05-boot-sequence.txt) |
| 시스템 관제 | 프로세스·포트·자원 측정, 임계값 경고, 실패 처리, 로그 누적 | [관제 실행](./logs/06-monitor-run.txt) · [관제 로그](./logs/07-monitor-log.txt) |
| 자동 실행과 로그 관리 | cron 매분 실행, 10MB 기준 최대 10개 로그 보존 | [cron](./logs/08-cron.txt) · [로그 보존](./logs/09-log-rotation.txt) |

전체 검증은 다음 명령으로 다시 실행할 수 있습니다. 앱 실행, 관제, cron 동작 확인, 앱 종료까지 약 3분이 걸립니다.

```bash
sudo bash scripts/collect-evidence.sh
```

---

## 핵심 설계 결정

완성 결과보다 구현 이유가 중요한 내용만 남겼습니다.

<details>
<summary><b>1. SSH 설정을 추가하지 않고 기존 지시자를 제거한 이유</b></summary>

`Port`는 마지막 값으로 덮어쓰는 설정이 아니라 여러 포트를 동시에 여는 누적 지시자입니다. 기존 `Port 22`를 남기고 `Port 20022`만 추가하면 두 포트가 모두 열립니다. 또한 포트 변경은 자동 스캔 노출을 줄일 뿐 인증 자체를 강화하지 않으므로, 기존 `Port`와 `PermitRootLogin` 지시자를 제거한 뒤 `Port 20022`와 최고 권한 계정의 직접 인증을 막는 `PermitRootLogin no`를 한 번씩만 기록했습니다.

이 Ubuntu 환경에서는 `systemd`가 SSH 연결을 먼저 받습니다. 따라서 `sshd_config`에서 포트를 바꿔도 `systemd`가 이전 포트 설정을 계속 사용할 수 있습니다. 설정 문법을 검사한 뒤 `systemctl daemon-reload`로 변경 내용을 다시 읽고, `ssh.socket`을 재시작해 새 포트를 적용했습니다.

</details>

<details>
<summary><b>2. 필요한 계정만 홈 디렉토리를 통과하도록 ACL을 사용한 이유</b></summary>

Linux에서는 대상 디렉토리뿐 아니라 그 위의 모든 디렉토리에 통과 권한 `x`가 있어야 접근할 수 있습니다. 따라서 `upload_files`의 권한만 열어서는 `agent-test`가 접근할 수 없습니다.

| 설정 방법 | 결과 |
|-----------|------|
| `upload_files`만 770으로 설정 | 상위 경로인 `/home/agent-admin`을 통과하지 못해 접근 실패 |
| `/home/agent-admin`을 755로 변경 | 접근은 가능하지만 프로젝트와 관계없는 시스템 계정도 홈 목록을 볼 수 있음 |
| `agent-common`에 ACL `x`만 부여 | 프로젝트 계정만 홈 목록을 보지 않고 하위 경로로 통과 가능 |

그래서 홈 디렉토리의 기존 권한은 유지하고 `agent-common`에 통과 권한만 추가했습니다.

```bash
setfacl -m g:agent-common:x /home/agent-admin
```

`upload_files`, `api_keys`, 로그 디렉토리에는 기본 ACL도 설정했습니다. 기본 ACL은 디렉토리 안에 새로 만들어지는 파일과 하위 디렉토리에 적용할 권한 템플릿입니다. 기존 파일에는 소급 적용되지 않지만, 이후 생성되는 항목은 각 디렉토리에 지정된 그룹 권한을 자동으로 이어받으므로 매번 권한을 다시 설정할 필요가 없습니다.

</details>

<details>
<summary><b>3. cron에서는 환경 파일을 읽고, 테스트할 때는 임시 값을 먼저 사용한 이유</b></summary>

`cron`은 사용자가 직접 로그인해서 실행하는 환경과 달리, 앱 경로나 포트 같은 환경 변수를 자동으로 불러오지 못합니다. 그래서 `monitor.sh`가 환경 파일을 직접 읽도록 하여, **직접 실행할 때와 cron으로 자동 실행할 때 같은 설정을 사용하도록 했습니다.**

반면 테스트할 때는 실제 운영 설정을 수정하지 않고도 로그 위치나 경고 기준 등을 잠시 바꿔 확인할 수 있어야 합니다. 이를 위해 실행할 때 임시 값을 전달하면 그 값을 가장 먼저 사용하도록 했습니다.

따라서 설정은 **실행할 때 전달한 값 → 환경 파일의 값 → 스크립트 기본값** 순서로 적용됩니다. 예를 들어 아래 명령처럼 임시 로그 디렉토리를 지정하면, 기존 운영 로그에는 영향을 주지 않고 경고와 로그 정리 기능을 테스트할 수 있습니다.

```bash
AGENT_LOG_DIR=/tmp/rotate-demo DISK_THRESHOLD=0 monitor.sh
```

</details>

<details>
<summary><b>4. 별도 logrotate 없이 스크립트에서 로그를 관리한 이유</b></summary>

`monitor.sh`는 `cron`에 의해 매분 실행되기 때문에, 실행 결과가 로그 파일에 계속 쌓입니다. 로그를 그대로 두면 `monitor.log`와 `cron.log`의 크기가 계속 커져 디스크 공간을 많이 차지할 수 있습니다.

이를 막기 위해 `monitor.sh`가 실행될 때마다 로그 크기를 확인하고, 일정 기준을 넘으면 오래된 로그를 정리하도록 했습니다. `monitor.sh` 자체가 매분 실행되므로 로그 정리를 위한 별도의 `logrotate` 일정도 추가할 필요가 없습니다.

즉, **모니터링 과정에서 만들어지는 로그가 무한정 쌓여 디스크를 차지하지 않도록, 로그 관리 기능을 `monitor.sh` 안에 함께 넣었습니다.**

</details>

---

## 주의 사항

- 앱은 Root 실행을 거부하므로 `agent-admin` 계정으로 실행해야 합니다.
- `AGENT_KEY_PATH`는 키 파일이 아니라 키 디렉토리를 가리켜야 합니다. 앱이 이 경로 아래에서 `secret.key`를 찾기 때문입니다.
- 앱을 중복 기동하면 TCP `15034` 포트 점유 검사에서 실패합니다.
- 앱이 내려간 동안에도 cron은 매분 실행되며 `[FAIL]` 로그를 남깁니다. 로그 크기는 보존 정책으로 제한됩니다.
- 이 프로젝트의 계정·그룹·ACL·로그 디렉토리는 [B1-2](../B1-2.linux-troubleshooting)에서도 재사용합니다.
