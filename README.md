# wsl-vmware-lab

Windows PC 한 대에서 **Terraform + Ansible로 시스템을 구성하고 시험하고 배포하는** 실습 기반입니다. WSL2 Ubuntu의 Terraform이 **VMware Workstation**에 VM을 1대 또는 여러 대 만들고, Ansible이 그 VM들에 **여러분의 플레이북**을 실행합니다. 들어 있는 Ubuntu VM 1대 + nginx 설치는 **예제이자 동작 확인용**입니다.

게스트 이미지는 **Ubuntu 클라우드 이미지(기본 24.04 noble)만 지원**합니다. 게스트가 VMware guestinfo로 자기 사용자 이름을 알려 주는데, 이때 이미지에 들어 있는 `open-vm-tools`가 필요하기 때문입니다(Debian 12 클라우드 이미지 등에는 없습니다).

블로그 연재의 첨부 스크립트를 한곳에 모았습니다.

- 0편: [WSL 업데이트·사양 설정·Ubuntu 설치, 재부팅 후 이어가기](https://naelonambul.tistory.com/210)
- 1편: [WSL2 SSH를 Windows 22번 포트로 포워딩하기](https://naelonambul.tistory.com/207)
- 2편: [VMware 실습 도구 설치와 베이스 VM API 등록](https://naelonambul.tistory.com/208)
- 3편: [Terraform으로 VM 만들고 Ansible로 Ubuntu 설정하기](https://naelonambul.tistory.com/209)

```
다른 PC --SSH:22--> Windows --(mirrored)--> WSL2 Ubuntu
WSL Terraform --> Windows vmrest http://127.0.0.1:8697/api --> VMware Workstation --> 테스트 VM
WSL Ansible --SSH--> 테스트 VM (nginx 설치, 페이지 배포, HTTP 확인)
```

## AI 에이전트 스킬 설치 (Claude Code / Codex)

이 저장소에는 실습을 대신 운영하는 스킬이 들어 있습니다. 같은 내용을 두 에이전트가 읽는 위치에 하나씩 둡니다.

| 에이전트 | 저장소 안 위치 | 설치 위치(모든 프로젝트) | 부르는 법 |
|---|---|---|---|
| Claude Code | `.claude/skills/vmware-wsl-lab` | `~/.claude/skills/vmware-wsl-lab` | `/vmware-wsl-lab` |
| Codex | `.agents/skills/vmware-wsl-lab` | `~/.agents/skills/vmware-wsl-lab` (`$skill-installer`로 설치하면 `~/.codex/skills/vmware-wsl-lab`) | `$vmware-wsl-lab` (또는 `/skills`) |

요청 내용이 스킬 설명과 맞으면 두 에이전트 모두 알아서 스킬을 씁니다. 저장소 폴더 안에서 에이전트를 실행하면 설치하지 않아도 스킬이 보입니다.

어느 에이전트든 이렇게 말하면 설치됩니다.

```text
https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md 를 읽고 설치해 줘
```

에이전트가 [INSTALL.md](INSTALL.md) 순서대로 진행합니다. 경로를 바꾸거나 설치하기 전에는 먼저 물어봅니다.
1. 실행 환경이 WSL인지 확인합니다.
2. 저장소를 찾거나, 없으면 Windows 사용자 폴더 아래에 받습니다.
3. 자기 에이전트의 설치 위치에 스킬을 복사합니다. 기존 스킬이 있으면 `.bak`으로 보관합니다.
4. `preflight.sh`로 점검합니다.

Codex는 스킬만 따로 설치할 수도 있습니다. 이 경우에도 저장소는 받아 둬야 합니다. 이렇게 설치하면 `~/.codex/skills/vmware-wsl-lab`(`$CODEX_HOME/skills`)에 들어가고, Codex는 이 위치도 읽습니다. 작업 폴더 밖에 쓰는 것이라 Codex가 쓰기 권한을 물을 수 있습니다. `~/.agents/skills`에 복사한 것과 중복 설치하지는 마세요(목록에 두 번 나옵니다).

```text
$skill-installer install https://github.com/naelonambul/wsl-vmware-lab/tree/main/.agents/skills/vmware-wsl-lab
```

vmrest 비밀번호는 묻지도, 읽지도 않습니다. `%USERPROFILE%\.env`는 직접 만드세요(아래 "vmrest 계정").

직접 설치하려면 WSL에서 아래 명령을 실행합니다. 에이전트를 Windows에서 쓰면 복사 위치를 `%USERPROFILE%\.claude\skills\`(Claude Code), `%USERPROFILE%\.agents\skills\`(Codex)로 바꾸세요.

```bash
# 저장소는 Windows 드라이브(사용자 폴더)에 둡니다. 베이스 VM 파일이 저장소 안에 만들어지기 때문입니다.
profile=$(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' </dev/null | tr -d '\r')
cd "$(wslpath -u "$profile")" && pwd    # 사용자 폴더가 출력되는지 확인한 뒤 다음 줄로
git clone https://github.com/naelonambul/wsl-vmware-lab.git
mkdir -p ~/.claude/skills && cp -r wsl-vmware-lab/.claude/skills/vmware-wsl-lab ~/.claude/skills/
mkdir -p ~/.agents/skills && cp -r wsl-vmware-lab/.agents/skills/vmware-wsl-lab ~/.agents/skills/   # Codex를 쓸 때
bash wsl-vmware-lab/preflight.sh
```

## 폴더 구성

| 경로 | 내용 |
|---|---|
| `download-ubuntu-image.sh` | Ubuntu 공식 OVA(`noble-server-cloudimg-amd64.ova`) 받기와 서명·체크섬 확인 |
| `preflight.sh` | 작업 전 점검: 환경 감지, 설정 유무, 도구, vmrest 상태(`--start-vmrest`로 켜기) |
| `lib/config.sh` | 모든 bash 스크립트가 불러오는 설정 로더 |
| `lab.env.example` | 설정 예시(가짜 값). `lab.env`로 복사해서 사용 |
| `*.sh`, `*.py` (최상위) | WSL에서 실행하는 본 스크립트 (2·3편) |
| `tcp-relay.ps1` | `guest-proxy.sh`가 호출하는 Windows SSH 중계 (3편) |
| `terraform/` | `main.tf`, `variables.tf` (provider `elsudano/vmworkstation` 2.0.1 고정) |
| `ansible/` | `configure-guest.yml`(nginx 예제), `check-lab.yml`(모든 VM 동작 확인) |
| `vms.tfvars.example` | 여러 VM 시스템용 VM 목록 예시. `vms.tfvars`로 복사해서 사용 |
| `windows/` | Windows에서 실행: SSH 포워딩(1편), vmrest 자동 실행(2편), 절전 방지 전원 설정(`configure-power.ps1`) |
| `extras/` | 진단·호환용 스크립트와 예전 NAT 방식 브리지. 실습에는 필요 없음 |
| `.claude/skills/vmware-wsl-lab/` | Claude Code용 설치·운영 스킬 (원본. 여기서 고침) |
| `.agents/skills/vmware-wsl-lab/` | Codex용 같은 스킬. `bash tools/sync-agent-skills.sh`로 복사하고, CI가 두 사본이 같은지 확인 |
| `INSTALL.md` | Claude가 읽고 따라 하는 스킬 설치 절차 |

## vmrest 계정: `%USERPROFILE%\.env`

vmrest에는 Windows·Ubuntu 로그인과 별개인 API 계정이 있습니다(`vmrest.exe -C`로 만듦). 스크립트가 쓸 이 계정은 **Windows 사용자 폴더의 `.env`**(`C:\Users\<사용자>\.env`)에 적습니다.

```
VMWS_USERNAME=<vmrest.exe -C 로 만든 계정>
VMWS_PASSWORD=<그 비밀번호>
```

- `VMWS_USER`라고 적어도 인식합니다. 다른 도구가 같은 `.env`에 자기 줄을 두어도 됩니다. 스크립트는 파일을 실행하지 않고 `VMWS_*` 줄만 읽습니다.
- 다른 파일을 쓰려면 `lab.env`에 `LAB_SECRETS_FILE=/mnt/c/...`를 지정합니다.
- 이 파일은 본인 Windows 계정만 읽게 두세요. `preflight.sh`가 다른 사용자도 읽을 수 있으면 경고합니다. 제한하려면 PowerShell에서 `icacls "$env:USERPROFILE\.env" /inheritance:r /grant:r "$($env:USERNAME):F"`를 실행합니다(cmd라면 `icacls %USERPROFILE%\.env /inheritance:r /grant:r %USERNAME%:F`). 실행 후 `icacls` 출력에 다른 계정 항목이 남아 있지 않은지 확인하세요.
- Windows 자격 증명 관리자도 시험했지만 쓰지 않습니다. 부팅 후 아무도 로그온하지 않은 상태에서 켜진 WSL에서는 자격 증명 관리자가 잠겨 있어 읽을 수 없었습니다.

## 개인 설정: `lab.env` (선택)

기본값을 바꿀 때만 만듭니다(계정은 넣지 않습니다).

```bash
cp lab.env.example lab.env
```

따로 지정하지 않으면 다음 기본값을 씁니다.

| 항목 | 기본값 | 변수 |
|---|---|---|
| VM 목록 | `vms.tfvars`가 있으면 그 목록, 없으면 아래 이름으로 1대 | `LAB_VMS_FILE` |
| Windows 쪽 VM 폴더 | VMware Workstation의 기본 VM 위치(편집 > 기본 설정 > 작업 공간, 기본값 `%USERPROFILE%\Documents\Virtual Machines`). vmrest는 Terraform이 요청한 경로와 상관없이 이 위치에 클론을 만들므로 둘이 같아야 함(preflight가 확인). 사용자 폴더 밖에 두려면 Workstation 설정을 먼저 바꾸고 vmrest를 다시 시작한 뒤 같은 값으로 지정. 바꿔도 이미 만든 VM은 옮겨지지 않음 | `LAB_VM_ROOT_WIN` |
| 기본 플레이북 | `ansible/configure-guest.yml` (nginx 예제) | `LAB_PLAYBOOK` |
| 게스트 VM 사용자 (VM 안) | 설정하지 않음. 이미지 기본 사용자(Ubuntu 이미지는 `ubuntu`)를 쓰고, 게스트가 부팅할 때마다 VMware guestinfo로 이름을 알려 줌 | 없음 |
| WSL 사용자 | 설정하지 않음. 이 PC에 SSH로 접속하는 계정(SSH config의 `User`)으로 스크립트를 실행하면 그 계정을 씀 | 없음 |
| 개인 파일(SSH 키, inventory, known_hosts) | `~/.config/wsl-vmware-lab/` | `LAB_PRIVATE_DIR` |
| VMware 설치 경로 | `/mnt/c/Program Files/VMware/VMware Workstation` | `VMWARE_DIR` |
| 베이스 / 클론 이름 (`vms.tfvars` 없을 때) | `ubuntu24-base` / `ubuntu24-demo` | `LAB_BASE_NAME` / `LAB_CLONE_NAME` |
| 클론 CPU / 메모리 (`vms.tfvars` 없을 때) | 2 / 2048 MB | `LAB_CLONE_CPUS` / `LAB_CLONE_MEMORY_MB` |
| 네트워크 | NAT `VMnet8`, 관리용 host-only `VMnet1` | `LAB_NAT_VNET` / `LAB_MGMT_VNET` |

Windows 스크립트는 설정 파일 대신 매개변수를 받습니다.

```powershell
# 관리자 PowerShell. 방화벽 허용 대역은 자신의 LAN으로 바꾼다
# Install: Windows 방화벽 규칙, (미러드) Hyper-V 방화벽 규칙, (NAT) portproxy. 값은 저장되어 이후 Refresh가 그대로 씀
.\windows\wsl2-ssh-forward.ps1 Install -AllowedRemoteAddress 192.168.0.0/24 -Distro Ubuntu-24.04
# InstallTask: 부팅 시 로그온 없이(S4U) + 로그온 때 실행되는 작업 2개를 만들고, sshd 유지 작업을 바로 실행
.\windows\wsl2-ssh-forward.ps1 InstallTask -AllowedRemoteAddress 192.168.0.0/24 -Distro Ubuntu-24.04
# vmrest 자동 실행(관리자 PowerShell). 저장소의 windows 폴더에서 실행하고 폴더를 옮기지 않는다
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-vmrest-task.ps1
```

`VMware vmrest API` 작업은 **Windows 부팅 때 로그온 없이** vmrest를 켭니다. 부팅 트리거, S4U(로그온 없이 해당 사용자로 실행, 비밀번호 저장 안 함), 시간 제한 없음, 실패 시 1분 간격 5회 재시작으로 등록됩니다. `start-vmrest.ps1`이 vmrest가 떠 있는 동안 계속 기다리기 때문에, vmrest가 죽으면 작업이 다시 켭니다. 작업보다 먼저 같은 사용자로 떠 있던 vmrest도 지켜보다가 죽으면 다시 켜고, 다른 사용자의 vmrest면 실패로 알립니다. 재시작 동작 자체는 아직 일부러 죽여서 시험해 보지 않았습니다. 다른 도구가 만든 vmrest 작업이 있으면 경고하니, 하나만 남기고 나머지는 사용 안 함으로 바꾸세요. 재부팅 후 아무도 로그온하지 않은 상태에서 vmrest가 응답(`401`)하는 것을 확인했습니다.

`start-vmrest.ps1`은 기본으로 `%ProgramFiles%\VMware\VMware Workstation\vmrest.exe`를 실행합니다. 다른 곳에 설치했다면 `install-vmrest-task.ps1 -VmrestPath <경로>`로 등록하면 작업에도 그 경로가 들어갑니다. 수동으로 한 번만 켤 때는 `-NoWait`를 붙입니다.

## 실행 순서 (WSL Ubuntu, 저장소 최상위)

WSL 계정은 `ubuntu`로 만드는 것을 권장합니다. Windows에서 `wsl --install -d Ubuntu-24.04`를 실행한 뒤, 첫 실행 화면에서 사용자 이름을 `ubuntu`로 입력하면 됩니다. 저장소는 VM 파일과 같이 Windows 드라이브(예: `/mnt/c/...`)에 두세요.

```bash
sudo bash setup-wsl-tools.sh                 # Terraform(HashiCorp apt), Ansible, 이미지 도구
bash download-ubuntu-image.sh               # 공식 OVA 받기 + 서명(gpgv)·체크섬 확인
bash extract-ubuntu-image.sh
bash prepare-cloud-init.sh
bash preflight.sh                            # vmrest 확인. 꺼져 있으면 --start-vmrest
bash prepare-base.sh                         # 1회만: 베이스 VMX 생성, API 등록, 첫 부팅
bash api-status.sh                           # 등록된 VM 목록
bash terraform-vm.sh on                      # 복제 -> cloud-init/NIC 준비 -> 전원 ON
ANSIBLE_TIMEOUT=60 bash configure-guest.sh   # nginx 설치, HTTP 확인 (두 번째 실행 changed=0)
bash terraform-vm.sh off
bash terraform-vm.sh destroy                 # 삭제 + seed ISO/빈 폴더 정리
```

## 내 시스템 올리기: 여러 VM + 내 플레이북

예제 대신 자기 시스템을 구성할 때는 VM 목록과 플레이북만 바꿉니다. 스크립트는 고치지 않습니다.

```bash
cp vms.tfvars.example vms.tfvars             # VM 이름, CPU, 메모리, Ansible 그룹 (git에 올라가지 않음)
bash terraform-vm.sh on                      # 목록대로 생성. 나중에 항목을 추가하면 새 VM만 만들고, 켜져 있는 VM은 그대로
ANSIBLE_TIMEOUT=60 bash configure-guest.sh ansible/check-lab.yml   # 모든 VM 접속·cloud-init·sudo 확인
ANSIBLE_TIMEOUT=60 bash configure-guest.sh ~/my-system/site.yml    # 내 플레이북 (다른 폴더에 둬도 됨)
bash check-power.sh                          # VM별 전원 상태
```

- `vms.tfvars`의 키가 VM 이름입니다. Windows 폴더 이름, 게스트 hostname, Ansible 호스트 이름이 모두 이 이름이 됩니다.
- `groups`에 적은 그룹이 Ansible 그룹이 되고, 모든 VM은 `lab` 그룹에도 들어갑니다. 플레이북에서 `hosts: web`, `hosts: db`처럼 씁니다.
- 목록에서 항목을 지우고 `on`을 실행하면 그 VM이 삭제되고, seed ISO, known_hosts 같은 관련 파일도 정리됩니다.
- `configure-guest.sh` 뒤에 붙인 옵션은 그대로 `ansible-playbook`에 넘어갑니다(예: `--limit web1`, `-e key=value`).

자세한 설명과 함정은 블로그 글과 [`.claude/skills/vmware-wsl-lab/reference/pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md)를 참고하세요.

## 작업 전 점검: `preflight.sh`

```bash
bash preflight.sh                 # 점검만 하고 아무것도 바꾸지 않음. vmrest가 응답하면 종료 코드 0
bash preflight.sh --start-vmrest  # vmrest가 꺼져 있으면 'VMware vmrest API' 작업을 시작하고 최대 30초 대기
```

실제로 감지한 값(저장소 위치, WSL 사용자·배포판, Windows 프로필, mirrored 여부)과 설정 파일 유무, 도구 설치 상태, vmrest 응답, 절전·최대 절전·덮개 닫기 전원 설정(읽기만 함)을 보여 줍니다. 비밀번호 값은 출력하지 않습니다. vmrest가 Windows에서는 실행 중인데 WSL에서 닿지 않으면, 새로 켜지 않고 endpoint와 네트워크 설정을 확인하라고 안내합니다.

## 주의

- **검증 범위:** 2026-11-06 한 PC(VMware Workstation 기설치, 미러드 네트워크, Windows·Hyper-V 방화벽 꺼짐)에서 이 저장소판으로 WSL 설치부터 베이스 VM, Terraform 복제, Ansible 2회(두 번째 `changed=0`), 정리, 재부팅 후 로그온 전 vmrest·SSH까지 확인했습니다. VMware가 없는 새 PC, NAT 모드, 방화벽이 켜진 PC는 아직 확인하지 않았습니다. 처음 쓸 때는 결과를 단계마다 확인하세요.
- **SSH는 부팅 때 시작:** `wsl2-ssh-forward.ps1 InstallTask`는 vmrest처럼 Windows 부팅 시 로그온 없이(S4U) WSL sshd를 켜고, 로그온 때도 한 번 더 실행합니다. 등록 직후에도 sshd 유지 작업을 바로 실행하고 22번이 열렸는지 확인합니다. sshd는 이 유지 작업 하나만 띄웁니다. 예전에 등록한 PC는 관리자 PowerShell에서 `InstallTask`를 다시 실행하세요.
- **절전하면 접속이 끊김:** Windows가 절전이나 최대 절전으로 들어가면 WSL SSH, vmrest, VM이 모두 멈춥니다. 다른 PC에서는 22번 포트 타임아웃으로 보여서 SSH 설정 문제와 헷갈리기 쉽습니다. 화면 끄기는 상관없습니다. `preflight.sh`가 전원 설정을 읽어 경고하고, 아래 스크립트로 바꿀 수 있습니다. 바꾸기 전 값은 `%LOCALAPPDATA%\wsl-vmware-lab\power-backup.json`에 저장되고 `-Action Restore`로 되돌립니다. 지금 쓰는 전원 계획에만 적용되며, 그룹 정책이 전원 설정을 관리하면 그쪽이 우선합니다.
  ```powershell
  cd <저장소>\windows
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure-power.ps1                  # 현재 값 보기(바꾸지 않음)
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure-power.ps1 -Action Apply    # 전원 연결 시: 절전·최대 절전 안 함, 덮개 닫아도 동작 없음
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure-power.ps1 -Action Apply -IncludeBattery   # 배터리일 때도 같게
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure-power.ps1 -Action Restore  # 원래 값으로
  ```
  `-WhatIf`를 붙이면 바꿀 내용만 보여 줍니다. 노트북을 실습 호스트로 쓰면 전원을 연결해 두세요.
- **올리면 안 되는 파일:** `lab.env`, `%USERPROFILE%\.env`, SSH 개인키, `*.tfstate`, `inventory.json`, VM 디스크·ISO는 `.gitignore`에 들어 있습니다. 커밋하지 마세요.
- **비공식 provider:** `elsudano/vmworkstation`은 HashiCorp나 Broadcom이 아닌 커뮤니티 provider입니다. 버전을 올리기 전에 스키마를 확인하세요(`terraform providers schema -json`).
- **진단 스크립트:** `extras/diagnose-terraform.sh`는 베이스 VM을 끄고 `power_state=off`를 적용합니다. 실행 전에 내용을 읽어 보세요.

## License

[MIT](LICENSE)
