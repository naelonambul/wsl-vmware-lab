# wsl-vmware-lab

[English](README.md) · **한국어**

Windows PC 한 대에서 **Terraform + Ansible로 시스템을 구성하고 시험하고 배포하는** 실습 기반입니다. WSL2 Ubuntu의 Terraform이 `elsudano/vmworkstation` provider와 `vmrest` REST API를 통해 **VMware Workstation**에 VM을 1대 또는 여러 대 만들고, Ansible이 SSH로 그 VM들에 **여러분의 플레이북**을 실행합니다. 기본으로 들어 있는 단일 Ubuntu VM + nginx 구성(`ubuntu24-demo`와 `ansible/configure-guest.yml`)은 예제이자 동작 확인(스모크 테스트)용입니다.

```
다른 PC --SSH:22--> Windows (mirrored) --> WSL2 Ubuntu sshd
WSL Terraform --> vmrest http://127.0.0.1:8697/api --> VMware Workstation --> 실습 VM
WSL Ansible --SSH--> 실습 VM (VMnet1 host-only 관리망; VMnet8 NAT)
```

배경 설명 글(글 발행 뒤로 저장소가 바뀌었으니, 내용이 다르면 **이 README가 기준**입니다):
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

3. **Windows 부팅 작업, 방화벽, 전원 설정 (관리자 PowerShell, `windows\` 폴더에서):**
   ```powershell
   .\setup.ps1 Install -AllowedRemoteAddress 192.168.1.0/24   # 자신의 LAN 대역으로 변경
   .\setup.ps1 Status                                          # 읽기 전용 점검 (관리자 권한 불필요)
   .\setup.ps1 Remove                                          # 작업과 방화벽 규칙 제거 (전원 설정은 그대로)
   ```
   `windows\setup.ps1` 옵션:
   - `-Action`: `Install`, `Status`(기본값), `Remove`
   - `-AllowedRemoteAddress <subnet>`: `Install`에 필수. TCP 22를 허용할 출발지 대역(예: `192.168.1.0/24`)
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
   - 예전 작업과 `%ProgramFiles%\wsl-vmware-lab` 아래의 예전 파일을 지우고, 두 작업을 시작한 뒤 WSL의 `22`번 포트와 Windows의 `127.0.0.1:8697`이 실제로 리슨할 때까지 기다렸다가 준비 완료를 출력합니다.

4. **베이스 VM 준비 및 호스트 점검 (WSL):**
   ```bash
   ./lab setup     # 1회: 부족한 WSL 도구를 sudo로 설치하고, Ubuntu 이미지 서명을 확인해 베이스 VM 준비
   ./lab status    # 환경, vmrest, Windows 작업·전원, VM을 읽기 전용으로 점검
   ```
   - `terraform`, `ansible-playbook`, `qemu-img`, `cloud-localds`, `gpgv`, `ubuntu-cloudimage-keyring` 가운데 없는 것이 있으면 `./lab setup`이 먼저 `sudo bash lib/wsl-tools.sh`를 실행합니다(WSL 비밀번호를 묻습니다). 이어서 `LAB_IMAGE` 클라우드 이미지를 내려받아 확인하고(위 표 참고), 이미지를 `base/ubuntu-base.vmdk`로 변환하고, `~/.config/wsl-vmware-lab/lab_ed25519`를 만들고, `base/ubuntu-base.vmx`(`ubuntu24-base`)를 작성·등록한 뒤 `base/ubuntu-base.prepared`를 기록합니다. 베이스는 부팅하지 않으므로 클론마다 첫 부팅이 이미지의 첫 부팅입니다.
   - `./lab status`는 아무것도 바꾸지 않고 호스트 설정, `vmrest` 루프백 리스너와 인증 정보, Windows 부팅 작업과 전원 설정, 실습 VM들의 전원 상태를 점검합니다.

### AI 에이전트로 설치하기

Claude Code나 OpenAI Codex에게 저장소 설치나 점검을 맡기려면 에이전트에게 다음과 같이 말합니다:

> Read https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md and install it.

에이전트는 [`INSTALL.md`](INSTALL.md)에 따라 Windows 드라이브에서 저장소를 찾거나 클론하고, `.claude/skills/vmware-wsl-lab`(또는 동일한 Codex용 사본 `.agents/skills/vmware-wsl-lab`)에서 `vmware-wsl-lab` 스킬을 설치한 뒤 `./lab status`를 실행합니다. 에이전트는 `vmrest` 비밀번호를 묻거나 읽거나 출력하거나 입력하지 않습니다.

## `./lab` 명령 안내

```bash
./lab account [--lock]         # vmrest API 계정 + 시크릿 파일 (1회; --lock: 권한만 잠그기)
./lab setup [--recreate]       # WSL 도구, Ubuntu 이미지, cloud-init 시드, 베이스 VM 준비 (1회)
./lab status [--start-vmrest | --plan [on|off]]   # 점검; --plan: up/down이 바꿀 내용을 미리 보기
./lab up [--allow-destroy]     # vms.tfvars의 새 VM 만들기 + 모두 켜기
./lab down                     # 기존 VM 전원 끄기
./lab configure [PLAYBOOK] [ansible-playbook options]
./lab destroy [-auto-approve]  # 이 체크아웃의 VM 모두 삭제
./lab cleanup                  # 중단된 삭제 작업이 남긴 정리 다시 시도
```

체크아웃당 한 번에 하나의 `lab` 명령만 실행됩니다(`.lab.lock`에 `flock` 사용). 동시에 두 번째 명령을 실행하면 바로 종료됩니다.

### 내 시스템 올리기

```bash
cp vms.tfvars.example vms.tfvars           # VM 이름, CPU, memory_mb, Ansible 그룹 정의 (git에 올라가지 않음)
./lab up
./lab configure ansible/check-lab.yml      # 모든 VM의 SSH, cloud-init, 비밀번호 없는 sudo, OS 팩트 확인
./lab configure ~/my-system/site.yml       # 내 플레이북 실행 (저장소 밖 다른 폴더에 둬도 됨)
```

- `vms.tfvars`의 `vms = { ... }` 안 각 키가 VM 이름입니다(`^[a-z0-9][a-z0-9-]{0,62}$`, 영문 소문자·숫자·`-`만 사용, 베이스 이름 `<image>-base`와 같을 수 없음). 이 이름이 Windows 폴더 및 VMX 경로(`<LAB_VM_ROOT_WIN>\<name>\<name>.vmx`), 게스트 호스트 이름, Ansible 호스트 이름이 됩니다.
- 생략한 필드는 `processors = 2`, `memory_mb = 2048`, `groups = ["demo"]` 기본값을 씁니다.
- `groups`의 그룹 이름은 `^[a-z_][a-z0-9_]*$` 형식이어야 합니다. 모든 VM은 지정한 `groups`에 들어가며, 항상 `lab` 그룹에도 추가됩니다(`ansible/check-lab.yml`은 `lab`에서, 기본 `ansible/configure-guest.yml`은 `demo`에서 실행됩니다).
- `vms.tfvars`에 항목을 더하고 `./lab up`을 실행하면 이미 켜져 있는 VM은 그대로 둔 채 새 VM만 만들고 준비합니다(꺼진 상태로 만든 뒤 부트스트랩하고 전원을 켭니다).

## 지켜 주는 것

- **의도하지 않은 VM 삭제 거부:** `./lab up`은 적용 전에 `terraform plan -json`을 검사합니다. 삭제되거나 교체될 VM이 하나라도 있으면 `--allow-destroy`를 붙이지 않는 한 VM 이름을 보여 주고 멈춥니다. `vms.tfvars`가 없어지거나 오타가 나도 기존 VM은 지워지지 않습니다. `./lab down`은 state에 이미 있는 VM만 대상으로 삼으며, 전원 변경 외의 다른 변경이 있는 플랜은 거부합니다.
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
| `LAB_BASE_DIR` | `<repo>/base` | 베이스마다 `<image>/` 폴더(`base.vmx`, `base.vmdk`, `base.prepared`)를 두는 폴더 |
| `LAB_IMAGE` | `ubuntu-24.04` | `vms.tfvars`에 `image`가 없는 VM의 게스트 이미지: `ubuntu-24.04`, `ubuntu-22.04`, `debian-13` |
| `LAB_UBUNTU_IMAGE_URL` | `https://cloud-images.ubuntu.com/<noble 또는 jammy>/current` | 선택한 Ubuntu 이미지와 `SHA256SUMS`를 받을 폴더(미러) |
| `LAB_VM_ROOT_WIN` | `%USERPROFILE%\Documents\Virtual Machines` | 클론을 두는 Windows 폴더(`<root>\<name>\<name>.vmx`). Workstation의 기본 VM 위치와 같아야 함 |
| `LAB_VMS_FILE` | `<repo>/vms.tfvars` | 다중 VM 정의 파일. 없으면(명시적으로 지정하지 않은 경우) 아래 단일 데모 VM으로 대체 |
| `LAB_CLONE_NAME` | `ubuntu24-demo` | `vms.tfvars`가 없을 때 쓰는 단일 기본 VM 이름 |
| `LAB_CLONE_CPUS` | `2` | 단일 기본 VM의 vCPU 수 |
| `LAB_CLONE_MEMORY_MB` | `2048` | 단일 기본 VM의 메모리(MB) |
| `LAB_PLAYBOOK` | `<repo>/ansible/configure-guest.yml` | 플레이북을 지정하지 않았을 때 `./lab configure`가 실행하는 기본 플레이북 |
| `LAB_GUEST_WAIT_SECONDS` | `300` | 모든 VM이 IP, 사용자, 호스트 키를 알려 줄 때까지 `./lab configure`가 기다리는 최대 시간(초) |

## 폴더 구조

| 경로 | 내용 |
|---|---|
| `lab` | WSL에서 실행하는 단일 CLI 진입점 |
| `lib/` | `lab`이 부르는 내부 스크립트(`config.sh`, `account.sh`, `wsl-tools.sh`, `base.sh`, `cloud-config.sh`, `register-vm.py`, `check-base.py`, `preflight.sh`, `diagnose.sh`, `lifecycle.sh`, `bootstrap-guest.sh`, `cleanup-guest.py`, `configure.sh`, `guest-inventory.py`, `guest-proxy.sh`) |
| `windows/` | `setup.ps1`(관리자 PowerShell 설치·점검·제거)과 `tcp-relay.ps1`(WSL에서 게스트로 바로 SSH 연결이 안 될 때 Windows를 거치는 stdio TCP 중계) |
| `terraform/` | `elsudano/vmworkstation` `2.0.1`을 고정한 Terraform 설정(`main.tf`, `variables.tf`) |
| `ansible/` | 기본 nginx 동작 확인 플레이북(`configure-guest.yml`)과 전체 VM 준비 상태 점검 플레이북(`check-lab.yml`) |
| `lab.env.example`, `vms.tfvars.example` | `lab.env`와 `vms.tfvars` 템플릿 |
| `INSTALL.md` | Claude Code와 Codex용 에이전트 설치 안내서 |
| `.claude/skills/vmware-wsl-lab/` | `vmware-wsl-lab` 에이전트 스킬 원본(`SKILL.md`, `reference/`). `.agents/skills/vmware-wsl-lab/`은 `tools/sync-agent-skills.sh`로 복사한 Codex용 사본 |

## 주의

- **검증 범위:** 2026-11-09 노트북 1대(VMware Workstation Pro 기설치, WSL2 미러드 네트워크, Windows 방화벽의 Private·Public 프로필 꺼짐)에서 확인했습니다: `windows\setup.ps1 Install`, 베이스 VM까지 만드는 `./lab setup`, `./lab up`으로 클론 생성, `./lab configure` 2회(두 번째 `changed=0`), `./lab configure ansible/check-lab.yml`, 파일 정리까지 포함한 `./lab destroy`, 재부팅 후 로그온 전 WSL `sshd`와 `vmrest` 기동. 부팅하지 않는 베이스와 고정 호스트 키, `lab` 사용자 방식도 같은 날 `./lab setup --recreate`, `up`, `configure` 2회, `check-lab.yml`, `down`/`up`으로 확인했고, 게스트에서 `open-vm-tools`를 끄고 `vmware-rpctool`을 치운 뒤에도 다시 확인했습니다. `LAB_IMAGE`의 세 이미지(`ubuntu-24.04`, `ubuntu-22.04`, `debian-13`)도 같은 날 각각 `setup --recreate`, `up`, `configure` 2회, `check-lab.yml`, `down`/`up`, `destroy`를 통과했습니다. **아직 확인하지 않은 환경:** VMware Workstation이 없는 새 PC와 Windows 방화벽 프로필이 켜진 PC.
- **올리면 안 되는 파일:** `lab.env`, `*.env`, `vmrest.env`, `*.tfvars`(`vms.tfvars`), SSH 키(`*_ed25519*`), `inventory.json`, `known_hosts*`, `*.tfstate*`, `cleanup-pending.json`, VM 디스크·이미지·ISO(`base/`, `cloud-init/`, `*.ova`, `*.vmdk`, `*.vmx`, `*.iso`)는 `.gitignore`에 들어 있으며 버전 관리에 올라가면 안 됩니다.
- **비공식 Terraform provider:** `elsudano/vmworkstation`(`2.0.1`)은 커뮤니티 provider입니다. 베이스 VM을 `displayName`으로 찾아 첫 번째 항목을 고르고, 베이스 VM을 다시 만들어도 스스로 클론을 교체하지 않습니다. 이 저장소가 그 둘을 대신 확인합니다(`lib/check-base.py`와 `terraform_data.vm_base`). provider 버전을 올리기 전에 스키마를 확인하세요.
- **문제가 생기면:** 알려진 증상과 해결 방법은 [`.claude/skills/vmware-wsl-lab/reference/pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md)에서 찾으세요.

## License

[MIT](LICENSE)
