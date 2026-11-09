# wsl-vmware-lab

Windows PC 한 대에서 **Terraform + Ansible로 시스템을 구성하고 시험하는** 실습 기반입니다. WSL2 Ubuntu의 Terraform이 **VMware Workstation**에 VM을 1대 또는 여러 대 만들고, Ansible이 그 VM들에 **여러분의 플레이북**을 실행합니다. 들어 있는 Ubuntu VM 1대 + nginx는 예제이자 동작 확인용입니다.

```
다른 PC --SSH:22--> Windows (mirrored) --> WSL2 Ubuntu
WSL Terraform --> vmrest http://127.0.0.1:8697/api --> VMware Workstation --> 실습 VM
WSL Ansible --SSH--> 실습 VM
```

배경 설명은 블로그 연재에 있습니다(그 뒤로 저장소가 바뀌었으니, 다르면 이 README가 기준입니다): [0편](https://naelonambul.tistory.com/210) · [1편](https://naelonambul.tistory.com/207) · [2편](https://naelonambul.tistory.com/208) · [3편](https://naelonambul.tistory.com/209)

## 준비물

- Windows 11, WSL2 Ubuntu 24.04, **미러드 네트워크**(`%USERPROFILE%\.wslconfig`의 `[wsl2]`에 `networkingMode=mirrored`)
- **VMware Workstation Pro는 사람이 직접 설치합니다.** 공식 설치 파일은 Broadcom 계정으로만 받을 수 있어 자동화하지 않습니다. API 계정(Windows·Ubuntu 로그인과 별개)은 설치 2단계의 `./lab account`로 만듭니다.
- 게스트는 **Ubuntu 클라우드 이미지(24.04)만** 지원합니다. 게스트가 VMware guestinfo로 사용자 이름과 SSH 호스트 키를 알려 주는데, 여기에 이미지 안의 `open-vm-tools`가 필요합니다.
- 저장소는 Windows 드라이브(예: `C:\wsl-vmware-lab`, WSL에서 `/mnt/c/...`)에 둡니다. 베이스 VM 파일이 저장소 안에 만들어집니다.

## 설치

1. **저장소 받기 (WSL):** Windows 드라이브에 받습니다.
   ```bash
   cd /mnt/c && git clone https://github.com/naelonambul/wsl-vmware-lab.git && cd wsl-vmware-lab
   ```
2. **vmrest 계정 (WSL, 사람이 직접 입력):**
   ```bash
   ./lab account          # vmrest.exe -C 실행 → 같은 비밀번호를 한 번 더 받아 %USERPROFILE%\.env 작성·잠금
   ./lab account --lock   # (.env 권한만 다시 잠그기)
   ```
   - 공식 `vmrest.exe -C` 프롬프트에서 아이디와 비밀번호를 정합니다. 그 비밀번호를 한 번 더 입력하면 Windows 사용자 폴더의 `.env`에 `VMWS_USERNAME`·`VMWS_PASSWORD` 줄을 쓰고(다른 줄은 그대로), 본인·SYSTEM·Administrators만 열 수 있게 잠급니다.
   - 2단계의 부팅 작업이 있으면 vmrest를 다시 시작해 인증(HTTP 200)까지 확인합니다. 처음 설치라 작업이 아직 없으면 확인은 `./lab status`가 합니다.
   - 터미널에서만 동작합니다. 에이전트는 비밀번호를 대신 입력하지 않습니다.
3. **Windows 쪽 (관리자 PowerShell, 저장소의 `windows` 폴더에서, 한 번):**
   ```powershell
   .\setup.ps1 Install -AllowedRemoteAddress 192.168.1.0/24   # 허용 대역은 자신의 LAN으로
   .\setup.ps1 Status                                          # 읽기만 함
   .\setup.ps1 Remove                                          # 작업과 방화벽 규칙 제거 (전원 설정은 그대로)
   ```
   - 부팅 작업 2개를 만듭니다: `WSL2 SSH Service Start`(WSL 안의 sshd, WSL도 계속 켜 둠)와 `VMware vmrest API`(127.0.0.1:8697). 둘 다 **로그온 없이 부팅 때**(S4U) 시작하고, 끝나면 다시 시작합니다. `wsl.exe`, `vmrest.exe`를 직접 실행하므로 저장소를 옮겨도 됩니다.
   - TCP 22를 `-AllowedRemoteAddress`에서만 허용합니다(Windows 방화벽 + Hyper-V 방화벽).
   - 전원 연결 시 절전·최대 절전을 끄고 덮개를 닫아도 아무것도 하지 않게 합니다(`-IncludeBattery`: 배터리도, `-SkipPower`: 건드리지 않음). 절전하면 SSH·vmrest·VM이 모두 멈춥니다.
   - 22번과 8697번이 실제로 열린 뒤에만 준비 완료를 출력합니다. 예전 버전이 만든 작업과 `%ProgramFiles%\wsl-vmware-lab` 사본은 지웁니다.
4. **WSL 쪽:**
   ```bash
   ./lab setup     # 1회: 도구(없으면 sudo로 설치), 공식 이미지 받기·서명 확인, 베이스 VM 준비
   ./lab status    # 점검 (아무것도 바꾸지 않음)
   ```

AI 에이전트(Claude Code, Codex)에게 맡기려면 "https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md 를 읽고 설치해 줘"라고 말하면 됩니다. 저장소의 스킬(`.claude/skills/vmware-wsl-lab`, Codex용 사본 `.agents/skills/vmware-wsl-lab`)을 설치하고 `./lab status`로 점검합니다. vmrest 비밀번호는 묻지도 읽지도 않습니다.

## 사용: `./lab`

```bash
./lab account [--lock]            # vmrest 계정 + .env (사람이 입력) / 권한만 잠그기
./lab status [--start-vmrest]     # 점검: 도구, vmrest(루프백·인증), Windows 작업·전원, VM 전원
./lab status --plan [on|off]      # up/down이 바꿀 내용을 미리 보기 (읽기 전용)
./lab up [--allow-destroy]        # vms.tfvars의 VM 만들기(새 VM은 꺼서 준비한 뒤 켬) + 모두 켜기
./lab configure [PLAYBOOK] [옵션] # Ansible 실행. 기본은 nginx 예제, 옵션은 ansible-playbook에 그대로
./lab down                        # 전원만 끔
./lab destroy                     # 이 체크아웃의 VM 모두 삭제 + 관련 파일 정리
./lab cleanup                     # 중간에 끊긴 정리 이어서 하기
./lab setup --recreate            # 베이스를 새로 만들기 (베이스가 꺼져 있어야 함)
```

같은 체크아웃에서 `lab` 명령은 한 번에 하나만 실행됩니다(두 번째는 바로 멈춤).

### 내 시스템 올리기

```bash
cp vms.tfvars.example vms.tfvars           # VM 이름, CPU, 메모리, Ansible 그룹 (git에 올라가지 않음)
./lab up
./lab configure ansible/check-lab.yml      # 모든 VM 접속·cloud-init·sudo 확인
./lab configure ~/my-system/site.yml       # 내 플레이북 (다른 폴더에 둬도 됨)
```

- `vms.tfvars`의 키가 VM 이름입니다(Windows 폴더, 게스트 hostname, Ansible 호스트 이름). `groups`가 Ansible 그룹이 되고, 모든 VM은 `lab` 그룹에도 들어갑니다.
- 목록에 항목을 더하고 `up`하면 새 VM만 만들고, 켜져 있는 VM은 그대로 둡니다.

## 지켜 주는 것

- **지우기 전에 멈춤:** `up`은 VM을 삭제·교체해야 하면 이름을 보여 주고 멈춥니다. 정말 지울 때만 `--allow-destroy`를 붙입니다. `vms.tfvars`가 없어지거나 오타가 나도 기존 VM이 지워지지 않습니다. `down`은 전원 변경 말고 다른 변경이 있으면 거부합니다.
- **베이스 확인:** `up`/`down` 전에 베이스 이름(`LAB_BASE_NAME`)을 가진 VM이 정확히 하나이고 `base/ubuntu-base.vmx`인지 봅니다. 베이스를 다시 만들면(`setup --recreate`) 다음 `up`이 "베이스가 바뀌었다"며 멈추고, `up --allow-destroy`로 클론을 새 베이스에서 다시 만듭니다(클론 안의 내용은 사라짐).
- **엉뚱한 VM 막기:** 관리망(VMnet1)의 현재 DHCP 임대만 쓰고, 게스트가 guestinfo로 알려 준 SSH 호스트 키로만 접속합니다. 그 IP에 다른 VM이 있으면 접속하지 않습니다.
- **정리:** 지울 VM을 `terraform/cleanup-pending.json`에 적어 두고, 정리가 끝난 것만 뺍니다. 중간에 끊기면 다음 `up`·`destroy`·`cleanup`이 이어서 합니다.
- **vmrest:** 루프백(127.0.0.1)에서만 리슨하고, 인증 없이는 거부해야 `status`가 통과합니다.

## 설정: `lab.env` (선택)

기본값을 바꿀 때만 `cp lab.env.example lab.env`로 만듭니다(비밀번호는 넣지 않습니다). 주요 항목:

| 항목 | 기본값 | 변수 |
|---|---|---|
| VM 목록 | `vms.tfvars`, 없으면 아래 이름으로 1대 | `LAB_VMS_FILE` |
| 베이스 / 클론 이름 | `ubuntu24-base` / `ubuntu24-demo` | `LAB_BASE_NAME` / `LAB_CLONE_NAME` |
| 클론 VM 폴더 | Workstation의 기본 VM 위치(기본 `%USERPROFILE%\Documents\Virtual Machines`). vmrest가 이 위치에 클론을 만들므로 같아야 함 | `LAB_VM_ROOT_WIN` |
| 개인 파일(SSH 키, inventory, known_hosts) | `~/.config/wsl-vmware-lab/` | `LAB_PRIVATE_DIR` |
| 네트워크 | NAT `VMnet8`, 관리용 host-only `VMnet1` | `LAB_NAT_VNET` / `LAB_MGMT_VNET` |
| 게스트 준비 대기 | 300초 | `LAB_GUEST_WAIT_SECONDS` |

나머지 항목은 `lab.env.example`에 있습니다.

## 폴더

| 경로 | 내용 |
|---|---|
| `lab` | 유일한 진입점 |
| `lib/` | `lab`이 부르는 내부 스크립트(베이스 준비, 수명주기, 점검, 인벤토리, 정리) |
| `windows/` | `setup.ps1`(관리자 PowerShell), `tcp-relay.ps1`(게스트 SSH 중계) |
| `terraform/`, `ansible/` | provider `elsudano/vmworkstation` 2.0.1 고정 / 예제·점검 플레이북 |
| `.claude/skills/vmware-wsl-lab/` | 에이전트용 스킬(원본). `.agents/`는 `tools/sync-agent-skills.sh`로 복사한 Codex용 사본 |

## 주의

- **검증 범위:** 한 노트북(VMware 기설치, 미러드 네트워크, Windows 방화벽의 Private·Public 프로필 꺼짐)에서 설치부터 베이스, 복제, Ansible 2회(두 번째 `changed=0`), 정리, 재부팅 후 로그온 전 SSH·vmrest까지 확인했습니다(2026-11-09, `setup.ps1` 포함). VMware가 없는 새 PC와 방화벽이 켜진 PC는 아직 확인하지 않았습니다.
- **올리면 안 되는 파일:** `lab.env`, `.env`, SSH 개인키, `*.tfstate`, `inventory.json`, VM 디스크·ISO는 `.gitignore`에 있습니다.
- **비공식 provider:** `elsudano/vmworkstation`은 커뮤니티 provider입니다. 이름이 같은 VM이 있으면 첫 번째를 고르고, 베이스가 바뀌어도 스스로 클론을 다시 만들지 않습니다. 이 저장소가 그 둘을 대신 확인합니다. 버전을 올리기 전에 스키마를 확인하세요.
- **문제가 생기면:** [`pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md)에서 증상을 찾으세요.

## License

[MIT](LICENSE)
