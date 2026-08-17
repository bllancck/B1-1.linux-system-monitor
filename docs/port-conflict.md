# TCP 15034 포트 충돌 확인과 복구

## 증상

앱을 실행했을 때 다음처럼 4단계 포트 검사에서 실패할 수 있다.

```text
[4/5] Checking Port Availability          [FAIL]
   >>> Port 15034 is already in use.
[5/5] Verifying Log Permission            [FAIL]
   >>> Skipped due to previous critical failure.

System Boot Failed. Process Terminated.
[FAIL] 부트 시퀀스 실패 - /tmp/agent-app.out 확인
```

이 메시지는 새로 실행한 앱이 TCP `15034`를 열려고 했지만, 이미 다른 프로세스가 사용 중이어서 포트를 열지 못했다는 뜻이다. 이전에 실행한 Agent가 아직 종료되지 않은 경우가 대표적인 원인이다.

## 1. 포트 사용 프로세스 확인

먼저 어떤 프로세스가 `15034`를 사용 중인지 확인한다.

```bash
sudo ss -ltnp | grep 15034
```

예시는 다음과 같다.

```text
LISTEN 0 128 0.0.0.0:15034 0.0.0.0:* users:(("agent-app-linux",pid=1234,fd=3))
```

여기서 확인할 값은 프로그램 이름 `agent-app-linux`와 `pid=1234`이다. PID의 자세한 정보가 필요하면 다음 명령을 사용한다.

```bash
ps -fp 1234
```

점유 프로세스가 Agent가 아니라면 무작정 종료하지 말고, 해당 프로그램의 역할과 중단 영향을 먼저 확인해야 한다.

## 2. 기존 Agent 정상 종료

점유 프로세스가 이전에 실행한 Agent라면 프로젝트가 제공하는 종료 명령을 사용한다.

```bash
sudo bash scripts/run-app.sh --stop
```

`run-app.sh`는 다음 순서로 앱을 종료한다.

1. 실행 중인 Agent PID를 찾는다.
2. 정상 종료 신호인 `SIGINT`를 보낸다.
3. 최대 10초 동안 종료를 기다린다.
4. 종료되지 않으면 `SIGTERM`을 보낸다.

앱이 사용 중인 파일과 자원을 정리할 시간을 주므로 처음부터 `kill -9`로 강제 종료하는 것보다 안전하다. 정상적으로 종료되면 다음과 같은 메시지가 표시된다.

```text
[INFO] 앱 종료 (PID: 1234)
```

## 3. 포트가 비었는지 확인

종료 후 포트를 다시 확인한다.

```bash
sudo ss -ltnp | grep 15034
```

아무것도 출력되지 않으면 현재 `15034`를 사용하는 프로세스가 없으므로 새 Agent가 포트를 사용할 수 있다.

## 4. Agent 다시 실행

포트가 비어 있는 것을 확인한 뒤 앱을 다시 실행한다.

```bash
sudo bash scripts/run-app.sh --detach
```

정상이라면 모든 부트 검사가 통과하고 마지막에 `Agent READY`가 표시된다.

```text
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]

All Boot Checks Passed!
Agent READY
```

## 빠른 복구 순서

점유 프로세스가 기존 Agent임을 확인했다면 다음 세 명령을 순서대로 실행한다.

```bash
sudo bash scripts/run-app.sh --stop
sudo ss -ltnp | grep 15034
sudo bash scripts/run-app.sh --detach
```

두 번째 명령에서 아무것도 출력되지 않는지 확인한 뒤 세 번째 명령을 실행한다.
