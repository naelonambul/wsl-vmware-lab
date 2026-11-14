# wsl-vmware-lab

[English](README.md) · **한국어**

Windows PC 한 대에서 **Terraform + Ansible로 시스템을 구성하고 시험하고 배포하는** 실습 기반입니다. WSL2 Ubuntu의 Terraform이 `elsudano/vmworkstation` provider와 `vmrest` REST API를 통해 **VMware Workstation**에 VM을 1대 또는 여러 대 만들고, Ansible이 SSH로 그 VM들에 **여러분의 플레이북**을 실행합니다. 기본으로 들어 있는 단일 Ubuntu VM + nginx 구성(`ubuntu24-demo`와 `ansible/configure-guest.yml`)은 예제이자 동작 확인(스모크 테스트)용입니다.

```
다른 PC --SSH:22--> Windows (mirrored) --> WSL2 Ubuntu sshd
WSL Terraform --> vmrest http://127.0.0.1:8697/api --> VMware Workstation --> 실습 VM
WSL Ansible --SSH--> 실습 VM (VMnet1 host-only 관리망; VMnet8 NAT)
```

배경 설명 글(글 발행 뒤로 저장소가 바뀌었으니, 내용이 다르면 **현재 스크립트와 이 README가 기준**입니다):
- 한국어 연재: [0편 — WSL](https://naelonambul.tistory.com/210) · [1편 — VMware + vmrest 계정](https://naelonambul.tistory.com/211) · [2편 — SSH + 부팅 작업 (`setup.ps1`)](https://naelonambul.tistory.com/207) · [3편 — 베이스 VM (`./lab setup`)](https://naelonambul.tistory.com/208) · [4편 — Terraform/Ansible (`./lab`)](https://naelonambul.tistory.com/209)
- 영문 완결판: [Complete Guide](https://naelonambul.tistory.com/212)

## 준비물

- **Windows 11**, **WSL2 Ubuntu 24.04**(`Ubuntu-24.04`), **미러드 네트워크**(`%USERPROFILE%\.wslconfig`의 `[wsl2]` 아래 `networkingMode=mirrored`).
- **VMware Workstation Pro는 사람이 직접 설치합니다.** 공식 설치 파일은 Broadcom 계정이 필요해 자동화하지 않습니다. API 계정(Windows·Ubuntu 로그인과 별개)은 설치 2단계의 `./lab account`로 만듭니다.
- **게스트 이미지(`LAB_IMAGE`):** `./lab setup`이 내려받아 확인하는 공식 클라우드 이미지입니다. 게스트에는 cloud-init, SSH 서버, sudo, python3만 있으면 되고 VMware Tools는 필요 없습니다. 게스트 사용자(`lab`)와 클론마다의 SSH 호스트 키를 첫 부팅 전에 WSL에서 cloud-init으로 넣습니다.

  | `LAB_IMAGE` | 이미지 | 확인 방법 |
  |---|---|---|
  | `ubuntu-24.04`(기본값) | `noble-server-cloudimg-amd64.ova` | Ubuntu가 서명한 `SHA256SUMS`(gpgv) |
  | `ubuntu-22.04` | `jammy-server-cloudimg-amd64.ova` | 위와 같음 |
  | `debian-13` | `debian-13-generic-amd64.qcow2` | HTTPS로 받은 `SHA512SUMS`만 확인(Debian은 클라우드 이미지에 서명하지 않음) |

  `LAB_IMAGE`는 기본값이고, `vms.tfvars`에서 VM마다 `image`를 따로 줄 수 있어 한 시스템 안에서 섞어 쓸 수 있습니다(예: web은 Ubuntu, db는 Debian). `./lab setup`은 쓰이는 이미지마다 베이스를 하나씩 준비합니다(`base/<image>/`, VM 이름 `<image>-base`). VM의 이미지를 바꾸면 그 VM만 다시 만듭니다(`./lab up --allow-destroy`). 예제 nginx 플레이북은 apt를 씁니다.
- **저장소는 Windows 드라이브에 둡니다**(예: `C:\wsl-vmware-lab`, WSL에서 `/mnt/c/wsl-vmware-lab`). 베이스 VM 파일(`base/<image>/base.vmx`, `base.vmdk`)이 저장소 안에 만들어지므로 VMware Workstation이 Windows 경로에서 열 수 있어야 합니다.

## 설치

1. **Windows 드라이브에 저장소 클론 (WSL):**
   ```bash
   cd /mnt/c && git clone https://github.com/naelonambul/wsl-vmware-lab.git && cd wsl-vmware-lab
   ```

2. **`vmrest` API 계정 만들기 (WSL, 대화형 터미널):**
   ```bash
   ./lab account          # vmrest.exe -C 실행, %USERPROFILE%\.env 작성, ACL 잠금
   ./lab account --lock   # %USERPROFILE%\.env 권한만 다시 잠그기
   ```
   - 기존 `%USERPROFILE%\vmrest.cfg`가 있으면 먼저 백업한 뒤 공식 `vmrest.exe -C`를 실행해 API 아이디와 비밀번호를 정하게 합니다.
   - `vmrest.cfg`에서 `username=`을 읽고 같은 비밀번호를 한 번 더 입력받아, `%USERPROFILE%\.env`(`LAB_SECRETS_FILE`)의 다른 줄은 그대로 둔 채 `VMWS_USERNAME`과 `VMWS_PASSWORD`를 씁니다.
   - `%USERPROFILE%\.env`의 NTFS 권한(상속 해제)을 잠가 본인 Windows 계정, `SYSTEM`, `Administrators`만 읽을 수 있게 합니다.
   - `VMware vmrest API` 부팅 작업이 이미 있으면 `vmrest`를 다시 시작해 인증된 `GET /vms`가 HTTP `200`을 반환하는지 확인합니다. 3단계 전의 첫 설치에서는 4단계의 `./lab status`가 이 확인을 합니다.
   - 사람이 직접 대화형 터미널에서 실행해야 합니다. AI 에이전트는 비밀번호를 묻거나 읽거나 입력하지 않습니다.

3. **Windows 부팅 작업, 방화벽, 전원, VMware 브리지 설정 (관리자 PowerShell, `windows\` 폴더에서):**
   ```powershell
   .\setup.cmd Install                                         # LAN 대역은 기본 경로에서 자동 감지
   .\setup.cmd Status                                          # 읽기 전용 점검 (관리자 권한 불필요)
   .\setup.cmd Remove                                          # 작업과 방화벽 규칙 제거 (전원 설정은 그대로)
   ```
   `setup.cmd`는 같은 인자로 `setup.ps1`을 실행하면서 그 한 번만 PowerShell 실행 정책을 우회합니다(Windows는 기본적으로 `.ps1` 스크립트를 막음). 시스템 설정은 바꾸지 않습니다. `windows\setup.ps1` 옵션:
   - `-Action`: `Install`, `Status`(기본값), `Network`(조회 전용), `Remove`
   - `-AllowedRemoteAddress <subnet>`: TCP 22를 허용할 출발지 대역. 기본값은 기본 경로가 나가는 어댑터의 LAN, 즉 다른 PC가 이 PC에 접속하는 네트워크입니다(미러드 모드라 WSL도 같은 네트워크). 예: `192.168.1.0/24`. `Status`가 보여 줍니다
   - `-Distro <name>`: WSL 배포판 이름(기본값 `Ubuntu-24.04`)
   - `-VmrestPath <path>`: `vmrest.exe` 경로(기본값 `$env:ProgramFiles\VMware\VMware Workstation\vmrest.exe`)
   - `-IncludeBattery`: 배터리 전원에서도 절전, 최대 절전, 덮개 닫기 동작을 끔
   - `-SkipPower`: Windows 전원 설정을 건드리지 않음

   `Install`이 하는 일:
   - `%USERPROFILE%\.wslconfig`의 WSL 미러드 네트워크 설정을 확인하고, `vmrest.exe`가 있는지, Windows OpenSSH Server가 22번 포트를 잡고 있지 않은지 확인합니다.
   - 부팅 때 실행되는 부팅 작업 2개를 등록합니다(`AtStartup`, Windows 로그온이 필요 없는 S4U 로그온, 1분 간격 `RestartCount 5`, 실행 시간 제한 없음):
     - `WSL2 SSH Service Start`(부팅 때 및 로그온 때): `wsl.exe -d <Distro> -u root`로 `ssh.socket`/`ssh.service`를 멈추고 `/usr/sbin/sshd -D -e`를 포그라운드로 실행해 WSL을 계속 켜 둡니다.
     - `VMware vmrest API`(부팅 때): `127.0.0.1:8697`에서 리슨하는 `vmrest.exe`를 실행합니다.
     - 두 작업 모두 시스템 바이너리(`wsl.exe`, `vmrest.exe`)를 직접 실행하므로 저장소를 옮겨도 깨지지 않습니다.
   - Windows 방화벽(`WSL2 SSH 22`)과 WSL용 Hyper-V 방화벽(`WSL-SSH-Inbound-TCP22-LAN`)에서 `-AllowedRemoteAddress`로부터 들어오는 인바운드 TCP 22를 허용합니다.
   - `-SkipPower`를 주지 않으면 AC 전원(`-IncludeBattery`를 주면 배터리 전원도 포함)에서 절전과 최대 절전을 끄고 덮개를 닫아도 아무것도 하지 않게 설정합니다.
   - VMware 브리지 프로토콜을 실제 물리 어댑터(이더넷, Wi-Fi)에만 남깁니다. WSL 미러드 모드가 만드는 Hyper-V `vEthernet` 어댑터를 VMware VMnet0의 "자동" 브리지가 고르면 `lan = true` VM이 LAN에 닿지 못하기 때문입니다.
   - 예전 작업과 `%ProgramFiles%\wsl-vmware-lab` 아래의 예전 파일을 지우고, 두 작업을 시작한 뒤 WSL의 `22`번 포트와 Windows의 `127.0.0.1:8697`이 실제로 리슨할 때까지 기다렸다가 준비 완료를 출력합니다.

4. **베이스 VM 준비 및 호스트 점검 (WSL):**
   ```bash
   ./lab network   # setup 전에 VMware 역할과 브리지 정보 확인
   bash lib/preflight.sh # Terraform 설치 전에도 가능한 호스트 전용 사전 검사
   ./lab setup     # 1회: 부족한 WSL 도구를 sudo로 설치하고, Ubuntu 이미지 서명을 확인해 베이스 VM 준비
   ./lab status    # 환경, vmrest, Windows 작업·전원, VM을 읽기 전용으로 점검
   ```
   - `terraform`, `ansible-playbook`, `qemu-img`, `cloud-localds`, `gpgv`, `ubuntu-cloudimage-keyring` 가운데 없는 것이 있으면 `./lab setup`이 먼저 `sudo bash lib/wsl-tools.sh`를 실행합니다(WSL 비밀번호를 묻습니다). 이어서 `LAB_IMAGE` 클라우드 이미지를 내려받아 확인하고(위 표 참고), 이미지를 `base/<image>/base.vmdk`로 변환하고, `~/.config/wsl-vmware-lab/lab_ed25519`를 만들고, `base/<image>/base.vmx`(`<image>-base`)를 작성·등록한 뒤 `base/<image>/base.prepared`를 기록합니다. 베이스는 부팅하지 않으므로 클론마다 첫 부팅이 이미지의 첫 부팅입니다.
   - 공개 `./lab` 명령에는 호스트 전용 하위 명령이 없습니다. 최초 setup 전에는 WSL에서 `bash lib/preflight.sh`를 실행하고 종료값 0을 확인하세요. Terraform을 실행하지 않고 호스트·vmrest 조건을 점검하며 부족한 도구는 경고합니다. JSON 대신 텍스트를 출력합니다. 이어서 위 순서대로 setup과 전체 status를 실행하세요.
   - Status는 진단 명령입니다. 종료값 0 / `ok: true`만으로 모든 VM이 정상임을 판단하지 마세요. `data.vms`의 전원·LAN 정보와 `warnings`를 읽으세요. `vm_power_unknown`, `lan_vnet_mismatch` 경고는 해당 VM을 표시합니다.
   - `./lab status`는 호스트 설정, `vmrest` 루프백 리스너와 인증 정보, Windows 부팅 작업과 전원 설정, 실습 VM들의 전원 상태를 점검합니다. Terraform/provider를 자동 초기화하며 이 초기화는 `changed`를 설정하지 않습니다.

### AI 에이전트로 설치하기

Claude Code나 OpenAI Codex에게 저장소 설치나 점검을 맡기려면 에이전트에게 다음과 같이 말합니다:

> Read https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md and install it.

에이전트는 [`INSTALL.md`](INSTALL.md)에 따라 Windows 드라이브에서 저장소를 찾거나 클론하고, `.claude/skills/vmware-wsl-lab`(또는 동일한 Codex용 사본 `.agents/skills/vmware-wsl-lab`)에서 `vmware-wsl-lab` 스킬을 설치한 뒤 `./lab status`를 실행합니다. 에이전트는 `vmrest` 비밀번호를 묻거나 읽거나 출력하거나 입력하지 않습니다.

## `./lab` 명령 안내

```bash
./lab account [--lock]         # vmrest API 계정 + 시크릿 파일 (1회; --lock: 권한만 잠그기)
./lab setup [--recreate]       # WSL 도구, Ubuntu 이미지, cloud-init 시드, 베이스 VM 준비 (1회)
./lab status [--start-vmrest]   # 점검; 선택적으로 vmrest 시작
./lab up [--all | <vm>...] [--allow-destroy] [--dry-run]  # 꺼진 상태로 준비, 선택한 VM만 켜기
./lab down (--all | <vm>...) [--hard] [--dry-run]  # 정상 종료, 명시적 강제 종료
./lab configure [PLAYBOOK] [ansible-playbook options]
./lab destroy --confirm=<names> [--dry-run]  # state의 전체 VM 이름을 쉼표로 구분
./lab cleanup                  # 중단된 삭제 작업이 남긴 정리 다시 시도
./lab network                  # Windows/VMX 네트워크 정보 조회; vmrest 불필요
./lab describe --json          # 명령 인자, JSON 응답, 오류 코드 안내
```

모든 명령은 **stdout**에 JSON 응답 하나를 쓰며 사람이 읽는 로그와 Terraform·Ansible 진단은 **stderr**로 보냅니다. `./lab describe --json`의 안내는 `data` 안에 들어 있습니다.

```json
{"ok":true,"command":"up","dry_run":true,"changed":false,"data":{},"warnings":[],"error":null}
```

위는 응답 구조 예시이며 `data`는 명령마다 다릅니다. `error`가 null일 때만 `ok`가 true입니다. 오류에는 `code`, `message`, `hint`, `details`가, 경고에는 `code`, `message`, `vm`이 들어 있습니다. `changed`는 변경을 시도했다는 뜻이며 부분 변경이나 실패도 가능하므로 성공 증거가 아닙니다. stderr는 진단용으로 보관하되 시크릿이 모두 가려진 기록으로 취급하지 마세요.

`./lab up --dry-run`, `./lab down --all --dry-run`, `./lab destroy --dry-run`은 apply, 게스트 SSH, 정리, 저널 쓰기, state 복원 없이 계획과 안전 검사를 미리 봅니다. Terraform/provider를 자동 초기화하고 비공개 임시 파일을 사용하며, 이 작업은 `changed`를 설정하지 않습니다. 인증 정보와 연결 가능한 vmrest가 필요합니다. up/down에는 준비된 베이스도 필요합니다. 대기 중인 정리·복원은 보고만 합니다. destroy 미리 보기에는 확인 인자가 필요 없지만 주면 일치해야 합니다. 실제 destroy는 state의 전체 VM 이름을 중복 없이 쉼표로 구분해 확인해야 합니다(순서 무관). 대화형 확인이나 Terraform 인자 전달은 없습니다. 빈 state에서는 확인 인자 없이 성공하며 아무것도 삭제하지 않습니다.

| 오류 코드 | 종료값 | 다음 조치 |
|---|---|---|
| `usage_error` | 2 | 안내에 따라 인자를 수정합니다. |
| `config_error` | 2 | lab.env / vms.tfvars를 수정하고 불명확하면 묻습니다. |
| `unknown_vm` | 2 | 표시된 유효한 VM 이름을 씁니다. |
| `secrets_missing` | 3 | 변수 이름만으로 기존 파일을 찾고, 없으면 사용자가 ./lab account를 실행합니다. |
| `vmrest_auth` | 3 | 사용자가 인증 정보를 고치거나 ./lab account를 실행합니다. |
| `needs_user` | 3 | 터미널, sudo, 관리자 PowerShell이 필요한 명령을 사용자에게 전달합니다. |
| `lock_held` | 4 | 다른 작업을 기다렸다 재시도하며 잠금을 지우지 않습니다. |
| `vmrest_unreachable` | 4 | 사전 검사 단계에서 사용자에게 vmrest 시작을 요청한 뒤 재시도합니다. |
| `plan_destroy_refused` | 5 | VM 목록을 검토하고 --allow-destroy / --confirm 전에 삭제 의사를 확인합니다. |
| `config_change_requires_off` | 5 | 편집을 되돌리고 VM을 종료한 뒤 편집을 복원하고 up을 실행합니다. |
| `lan_vnet_mismatch` | 5 | 실제 연결과 설정을 비교하고 사용자와 오프라인 VMX 수정을 결정합니다. |
| `vm_power_unknown` | 5 | ./lab status를 확인하고 자동 복구 없이 보고합니다. |
| `guest_not_ready` | 1 | VM별 원인과 pitfalls 참고 문서를 읽고 자동 재시도하지 않습니다. |
| `runtime_error` | 1 (SIGINT: 130; SIGTERM: 143) | stderr와 ./lab status를 읽고 부분 변경된 분산 시스템의 복구 전에 묻습니다. |

성공 종료값은 0이며 분류되지 않은 실패는 `runtime_error`가 됩니다. 중단된 실행도 `runtime_error`를 출력하며 SIGINT는 130, SIGTERM은 143으로 종료합니다.

Setup, up, down, destroy, cleanup, configure는 체크아웃 잠금(`.lab.lock`에 `flock`)을 잡습니다. 잠금이 필요한 다른 명령은 `lock_held`로 종료됩니다. Status, network, describe, account는 이 잠금을 잡지 않습니다.

전원 이외의 모든 VM 속성의 in-place 변경은 VM을 꺼야 합니다(CPU/메모리에 한정되지 않음). `./lab down <vm>` 전에 편집을 되돌리고, 종료 후 복원한 다음 `./lab up <vm>`을 실행하세요. 꺼진 상태에서 설정을 적용한 뒤 별도 계획으로 켭니다. 전원만 바꾸는 작업은 허용됩니다.

### 내 시스템 올리기

```bash
cp vms.tfvars.example vms.tfvars           # VM 이름, CPU, memory_mb, Ansible 그룹 정의 (git에 올라가지 않음)
./lab network                    # 실제 VMware 네트워크 역할 먼저 확인
./lab up                         # 생성과 부트스트랩 후 꺼진 상태 유지
./lab up --all                   # 또는 필요한 순서대로 ./lab up <vm>
./lab configure ansible/check-lab.yml      # 켜진 VM의 SSH, cloud-init, 비밀번호 없는 sudo, OS 팩트 확인
./lab configure ~/my-system/site.yml       # 내 플레이북 실행 (저장소 밖 다른 폴더에 둬도 됨)
```

- `vms.tfvars`의 `vms = { ... }` 안 각 키가 VM 이름입니다(`^[a-z0-9][a-z0-9-]{0,62}$`, 영문 소문자·숫자·`-`만 사용, 베이스 이름 `<image>-base`와 같을 수 없음). 이 이름이 Windows 폴더 및 VMX 경로(`<LAB_VM_ROOT_WIN>\<name>\<name>.vmx`), 게스트 호스트 이름, Ansible 호스트 이름이 됩니다.
- 생략한 필드는 `processors = 2`, `memory_mb = 2048`, `groups = ["demo"]` 기본값을 씁니다.
- `groups`의 그룹 이름은 `^[a-z_][a-z0-9_]*$` 형식이어야 합니다. 모든 VM은 지정한 `groups`에 들어가며, 항상 `lab` 그룹에도 추가됩니다(`ansible/check-lab.yml`은 `lab`에서, 기본 `ansible/configure-guest.yml`은 `demo`에서 실행됩니다).
- **LAN NIC(선택):** `lan = true`를 주면 LAN NIC(기본은 VMnet0 브리지, `LAB_LAN_VNET`으로 사용자 지정 VMnet 선택)가 붙고, 게스트 안에서 `lan0`이라는 이름으로 공유기 DHCP에서 주소를 받습니다(실제 LAN 주소는 조회해서 사용). `lan_ip = "192.0.2.240/24"`는 문서용 고정 주소 예시입니다(실제 LAN 대역의 공유기 DHCP 범위 밖 주소로 바꾸세요). 이 PC의 LAN 대역(기본 경로에서 감지, `./lab status`에 표시) 밖의 주소이거나 이미 응답하는 주소면 `./lab up`이 거부합니다. `lan0`은 기본 경로와 DNS를 바꾸지 않으므로 인터넷은 계속 NAT로 나갑니다. 플레이북에서는 `ansible_lan0.ipv4.address`로 읽습니다(`check-lab.yml`이 보여 줍니다). 같은 LAN의 여러 PC에 있는 VM들이 이 주소로 서로 통신할 수 있습니다. `lan`/`lan_ip`를 바꾸면 그 VM을 다시 만듭니다(`./lab up --allow-destroy`). Hyper-V 어댑터가 있는 PC에서는 VMware의 VMnet0이 실제 네트워크 어댑터에 브리지되는지 확인하세요(Virtual Network Editor).
- `vms.tfvars`에 항목을 더하고 `./lab up`을 실행하면 기존 VM의 전원은 유지하고 새 VM은 꺼진 상태로 만들어 부트스트랩합니다. `./lab up <vm>...`은 선택한 VM만, `./lab up --all`은 모두 켭니다. 여러 이름을 한 번에 주면 시작 순서는 보장되지 않으므로 순서가 필요하면 따로 호출하세요.

## 지켜 주는 것

- **의도하지 않은 VM 삭제 거부:** `./lab up`은 적용 전에 `terraform plan -json`을 검사합니다. 삭제되거나 교체될 VM이 하나라도 있으면 `--allow-destroy`를 붙이지 않는 한 VM 이름을 보여 주고 멈춥니다. `vms.tfvars`가 없어지거나 오타가 나도 기존 VM은 지워지지 않습니다. `./lab down --all` 또는 `./lab down <vm>...`은 기존 VM을 정상 종료하며 삭제·교체와 전원 이외의 모든 VM 속성 변경을 먼저 거부합니다. vmrest가 선택한 VM 모두의 꺼짐을 확인해야 성공합니다. 연결되지 않는 VM은 계속 켜져 있습니다. 기본 대기 시간은 120초(`LAB_DOWN_WAIT_SECONDS`, 서비스 종료 90초와 여유 30초 예산)이며 `--hard`는 명시적인 강제 종료입니다. 인자 없는 `down`은 오류입니다.
- **베이스 VM 확인:** `up`이나 `down` 전에 `lib/check-base.py`가 쓰이는 이미지마다 `vmrest`에 등록된 VM 중 `displayName`이 `<image>-base`이고 `base/<image>/base.vmx`를 가리키는 VM이 정확히 하나인지 확인합니다. 그리고 베이스마다 VM ID와 `base.prepared`의 SHA-256 해시를 Terraform에 넘기고, Terraform은 이를 클론마다 기록합니다(`terraform_data.vm_base`). 베이스를 다시 만들거나(`./lab setup --recreate`) VM의 이미지를 바꾸면 해당 클론이 교체 대상으로 표시되며, `./lab up --allow-destroy`로 확인해 줄 때까지 `./lab up`이 멈춥니다(클론을 교체하면 디스크 내용이 지워집니다).
- **현재 DHCP 임대 + 부팅 전에 고정한 호스트 키:** 새 클론마다 `lib/bootstrap-guest.sh`가 WSL에서 `ssh-ed25519` 호스트 키를 만들어 클론의 cloud-init 시드(`ssh_keys`, 기존 키는 삭제)에 넣고, 클론이 처음 부팅하기 전에 `known_hosts-<id>`를 씁니다. `lib/guest-inventory.py`는 각 VM의 관리 NIC MAC(`ethernet1.generatedAddress`)을 `vmnetdhcp.leases`에서 `LAB_MGMT_VNET`의 만료되지 않은 활성 임대(IP별 마지막 항목 사용)와만 대조하고, 그 고정 키로 `lab` 사용자 SSH 접속이 성공해야 준비된 것으로 봅니다(`StrictHostKeyChecking=yes`, `HostKeyAlias`). 다른 VM이 IP를 재사용하더라도 Ansible이 엉뚱한 VM에 접속하지 않습니다. 클론 디스크 옆의 시드 ISO에는 부팅 뒤 디스크에 들어가는 것과 같은 개인키가 들어 있습니다.
- **이어서 실행할 수 있는 정리 기록:** Terraform이 VM을 삭제하거나 교체하기 전에 `lib/cleanup-guest.py`가 대상을 `terraform/cleanup-pending.json`에 적어 둡니다. VM이 state에서 빠지고(`.vmx`와 `.vmdk`도 사라진 뒤) 나면 정리 과정에서 `cloud-init-<id>.iso`, 남은 `.vmxf`, `known_hosts-<id>`, `seed-<id>/`, 빈 클론 폴더를 지웁니다. 항목은 정리가 끝날 때까지 기록에 남아 있으며 다음 `up`, `destroy`, `./lab cleanup`이 자동으로 이어서 시도합니다.
- **루프백과 인증이 적용된 `vmrest`:** `./lab status`는 `VMWS_ENDPOINT`가 루프백(`127.0.0.1`, `localhost`, `[::1]`)을 가리키는지, Windows `8697` 포트가 루프백에서만 리슨하는지, 인증 없는 `GET /vms`가 HTTP `401`을 반환하는지, 인증된 `GET /vms`가 HTTP `200`을 반환하는지 확인합니다.

## 설정: `lab.env` (선택)

기본값을 바꿀 때만 `lab.env.example`을 `lab.env`로 복사해 만듭니다(`cp lab.env.example lab.env`. `lab.env`에는 절대 비밀번호를 넣지 않습니다).

| 변수 | 기본값 | 용도 |
|---|---|---|
| `LAB_ENV_FILE` | `<repo>/lab.env` | 선택 설정 파일 경로(`lab.env` 안이 아니라 환경 변수로 설정) |
| `LAB_SECRETS_FILE` | `%USERPROFILE%\.env` | `VMWS_USERNAME`(또는 `VMWS_USER`)과 `VMWS_PASSWORD`를 담는 시크릿 파일 |
| `VMWS_ENDPOINT` | `http://127.0.0.1:8697/api` | 루프백 `vmrest` API URL |
| `LAB_PRIVATE_DIR` | `$HOME/.config/wsl-vmware-lab` | SSH 키, `inventory.json`, `known_hosts-<id>`, `seed-<id>/`를 두는 WSL 폴더 |
| `LAB_SSH_KEY` | `$LAB_PRIVATE_DIR/lab_ed25519` | 게스트에 넣는 Ed25519 SSH 개인키 |
| `LAB_INVENTORY` | `$LAB_PRIVATE_DIR/inventory.json` | 생성된 Ansible 인벤토리 파일 |
| `VMWARE_DIR` | `/mnt/c/Program Files/VMware/VMware Workstation` | VMware Workstation 폴더(`vmrun.exe`, `vmrest.exe`) |
| `LAB_DHCP_LEASES` | `/mnt/c/ProgramData/VMware/vmnetdhcp.leases` | VMware DHCP 임대 파일 |
| `LAB_DHCP_CONF` | `/mnt/c/ProgramData/VMware/vmnetdhcp.conf` | VMware DHCP 설정 파일 |
| `LAB_NAT_VNET` | `VMnet8` | NAT 가상 네트워크(`ethernet0`) |
| `LAB_MGMT_VNET` | `VMnet1` | Host-only 관리용 가상 네트워크(`ethernet1`) |
| `LAB_LAN_VNET` | 빈 값(실제 `VMnet0`) | LAN NIC: 빈 값/VMnet0 = 브리지, VMnet1–19 = 사용자 지정; NAT·관리 VMnet과 달라야 함 |
| `LAB_BASE_DIR` | `<repo>/base` | 베이스마다 `<image>/` 폴더(`base.vmx`, `base.vmdk`, `base.prepared`)를 두는 폴더 |
| `LAB_IMAGE` | `ubuntu-24.04` | `vms.tfvars`에 `image`가 없는 VM의 게스트 이미지: `ubuntu-24.04`, `ubuntu-22.04`, `debian-13` |
| `LAB_UBUNTU_IMAGE_URL` | `https://cloud-images.ubuntu.com/<noble 또는 jammy>/current` | 선택한 Ubuntu 이미지와 `SHA256SUMS`를 받을 폴더(미러) |
| `LAB_VM_ROOT_WIN` | `%USERPROFILE%\Documents\Virtual Machines` | 클론을 두는 Windows 폴더(`<root>\<name>\<name>.vmx`). Workstation의 기본 VM 위치와 같아야 함 |
| `LAB_VMS_FILE` | `<repo>/vms.tfvars` | 다중 VM 정의 파일. 없으면(명시적으로 지정하지 않은 경우) 아래 단일 데모 VM으로 대체 |
| `LAB_CLONE_NAME` | `ubuntu24-demo` | `vms.tfvars`가 없을 때 쓰는 단일 기본 VM 이름 |
| `LAB_CLONE_CPUS` | `2` | 단일 기본 VM의 vCPU 수 |
| `LAB_CLONE_MEMORY_MB` | `2048` | 단일 기본 VM의 메모리(MB) |
| `LAB_PLAYBOOK` | `<repo>/ansible/configure-guest.yml` | 플레이북을 지정하지 않았을 때 `./lab configure`가 실행하는 기본 플레이북 |
| `LAB_GUEST_WAIT_SECONDS` | `300` | configure 시작 시 고정한 켜진 VM 집합의 준비 대기 시간(초) |
| `LAB_DOWN_WAIT_SECONDS` | `120` | 정상 종료 전원 확인 대기 시간(초); 5초마다 확인 |

## 네트워크와 실행 중 인벤토리

setup이나 모든 up 전에 `./lab network`를 실행하고 [네트워크 참고 문서](.claude/skills/vmware-wsl-lab/reference/network.md)를 읽으세요. VMnet 번호로 역할을 단정하지 마세요. NAT·관리·LAN 연결, DHCP/NAT/포워딩, 물리 어댑터와 브리지 바인딩을 확인하세요. 바인딩은 Automatic이 고른 어댑터의 증거가 아닙니다. 불명확하면 LAN 활성화 전에 묻습니다. Network는 setup 전에도 인증 정보나 vmrest 없이 동작하며 기존 state가 있으면 Terraform으로 읽습니다.

`LAB_LAN_VNET` 변경은 클론을 다시 만들지 않습니다. 기존 LAN 연결이 다르면 모든 up이 거부됩니다. 사용자가 수정을 선택하면 LAN MAC을 유지하는 문서의 오프라인 VMX 절차를 따릅니다. `LAB_NAT_VNET` 변경은 베이스 재생성과 클론 재생성이 필요하므로 먼저 데이터 손실을 검토하세요.

Configure의 인벤토리와 그룹에는 켜진 VM만 들어갑니다. 최초의 켜진 VM 집합은 준비 재시도 중 고정됩니다. 꺼진 VM은 제외하고, 전원 불명/API 오류는 실패하며 실행 중인 호스트가 0개여도 실패합니다. `configure --limit db`는 기본 플레이북을 사용하고 limit를 그대로 전달하지만 모든 켜진 VM의 준비 상태를 확인합니다. 지속적인 클러스터 토폴로지는 프로젝트 변수에 정의하세요.

복제, master/worker, 멤버십, 쿼럼 서비스를 설정하거나 시작하기 전에 정확한 버전의 공식 문서 출처와 준비 확인 쿼리를 포함한 부트스트랩·종료·재시작 순서를 기록하세요. [분산 시스템 참고 문서](.claude/skills/vmware-wsl-lab/reference/distributed-systems.md)에 따라 필요한 패키지 자동 시작을 막고 되돌릴 수 없는 초기화의 반복을 방지하며 단계별로 `./lab up <vm>` / `./lab down <vm>`을 호출하세요. apply가 일부만 성공했다면 status를 확인하고 복구 전에 묻습니다.

## 기존 체크아웃 업그레이드

이번 업그레이드는 state 마이그레이션이 필요 없습니다. 리소스 주소와 교체 트리거는 같고 전원 변수는 state에 저장되지 않습니다. `vms.tfvars`와 `lab.env` 형식도 유지됩니다. 인자 없는 up은 준비만 하며 전체 시작은 `./lab up --all`입니다. Down에는 `--all`이나 이름이, destroy에는 `--confirm=<names>`가 필요합니다. 첫 apply 전에 `./lab up --dry-run`을 검토하세요. 전원 동작 변경 전 리비전 `b97feef`를 체크아웃해 롤백하면 해당 리비전의 up은 모든 VM을 켭니다.

## 개발자 검증

오프라인 테스트는 **Linux 전용**입니다(WSL Ubuntu 또는 CI `ubuntu-latest`). Windows Git Bash/MSYS에서는 절대 실행하지 마세요. 시간·프로세스 제한, fixture 격리, fork 반복 방지 방법과 명령은 [tests/README.md](tests/README.md)를 보세요.

현재 CLI의 실제 호스트 검증은 수동으로 진행합니다. Virtual Network Editor(조회만)와 네트워크 정보를 비교하고, 혼합 전원 상태, 생성 전용 up, 선택 시작과 교체, 정상 종료, JSON 결과, 중단 복구, 교체 없는 업그레이드를 확인하세요. 여러 PC에서는 호스트별로 state·비공개 폴더·VM 이름을 격리하고 버전별 서비스 순서를 문서화하며 전체 종료·재시작 뒤 멤버십과 새 쓰기/읽기를 확인하세요. 재부팅은 승인받은 경우에만 검증합니다. 호스트별 증거는 비공개로 보관하고 실제 실행한 검사만 보고하세요.

## 폴더 구조

| 경로 | 내용 |
|---|---|
| `lab` | WSL에서 실행하는 단일 CLI 진입점 |
| `lib/` | `lab`이 부르는 내부 스크립트(`config.sh`, `account.sh`, `wsl-tools.sh`, `base.sh`, `cloud-config.sh`, `register-vm.py`, `check-base.py`, `preflight.sh`, `network.sh`, `describe.json`, `envelope.py`, `power-map.py`, `lifecycle.sh`, `bootstrap-guest.sh`, `cleanup-guest.py`, `configure.sh`, `guest-inventory.py`, `guest-proxy.sh`, `config-functions.sh`, `runner-functions.sh`, `preflight-functions.sh`, `network-inspect.py`, `plan-inspect.py`, `bootstrap-records.py`, `diagnose.sh`) |
| `windows/` | `setup.ps1`(PowerShell 설치·점검·네트워크 조회·제거)과 `tcp-relay.ps1`(WSL에서 게스트로 바로 SSH 연결이 안 될 때 Windows를 거치는 stdio TCP 중계) |
| `terraform/` | `elsudano/vmworkstation` `2.0.1`을 고정한 Terraform 설정(`main.tf`, `variables.tf`) |
| `ansible/` | 기본 nginx 동작 확인 플레이북(`configure-guest.yml`)과 켜진 VM 준비 상태 점검 플레이북(`check-lab.yml`) |
| `lab.env.example`, `vms.tfvars.example` | `lab.env`와 `vms.tfvars` 템플릿 |
| `INSTALL.md` | Claude Code와 Codex용 에이전트 설치 안내서 |
| `.claude/skills/vmware-wsl-lab/` | `vmware-wsl-lab` 에이전트 스킬 원본(`SKILL.md`, `reference/`). `.agents/skills/vmware-wsl-lab/`은 `tools/sync-agent-skills.sh`로 복사한 Codex용 사본 |

## 주의

- **검증 범위:** 이전 단일 호스트 검증은 현재 CLI 도입 전 기록입니다. 새 네트워크·전원·JSON·업그레이드 동작은 개발자 절의 실제 호스트 검증이 필요합니다. 여러 PC의 시스템, Wi-Fi 브리지, VMware 신규 설치, Windows 방화벽 프로필이 켜진 환경도 이 문서에서 검증하지 않았습니다.
- **올리면 안 되는 파일:** `lab.env`, `*.env`, `vmrest.env`, `*.tfvars`(`vms.tfvars`), SSH 키(`*_ed25519*`), `inventory.json`, `known_hosts*`, `*.tfstate*`, `cleanup-pending.json`, VM 디스크·이미지·ISO(`base/`, `cloud-init/`, `*.ova`, `*.vmdk`, `*.vmx`, `*.iso`)는 `.gitignore`에 들어 있으며 버전 관리에 올라가면 안 됩니다.
- **비공식 Terraform provider:** `elsudano/vmworkstation`(`2.0.1`)은 커뮤니티 provider입니다. 베이스 VM을 `displayName`으로 찾아 첫 번째 항목을 고르고, 베이스 VM을 다시 만들어도 스스로 클론을 교체하지 않습니다. 이 저장소가 그 둘을 대신 확인합니다(`lib/check-base.py`와 `terraform_data.vm_base`). provider 버전을 올리기 전에 스키마를 확인하세요.
- **문제가 생기면:** 알려진 증상과 해결 방법은 [`.claude/skills/vmware-wsl-lab/reference/pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md)에서 찾으세요.

## License

[MIT](LICENSE)
