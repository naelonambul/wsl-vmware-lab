# wsl-vmware-lab

Windows PC에서 **WSL2 Ubuntu의 Terraform**으로 **VMware Workstation** VM을 만들고, **Ansible**로 그 VM 안의 Ubuntu를 설정하는 실습 스크립트 모음입니다.

블로그 연재의 첨부 스크립트를 한곳에 모았습니다. 개인 환경에 묶인 값은 설정 파일(`lab.env`)로 분리했습니다.

- 1편: [WSL2 SSH를 Windows 22번 포트로 포워딩하기](https://naelonambul.tistory.com/207)
- 2편: [VMware 실습 도구 설치와 베이스 VM API 등록](https://naelonambul.tistory.com/208)
- 3편: [Terraform으로 VM 만들고 Ansible로 Ubuntu 설정하기](https://naelonambul.tistory.com/209)

```
다른 PC --SSH:22--> Windows --(mirrored)--> WSL2 Ubuntu
WSL Terraform --> Windows vmrest http://127.0.0.1:8697/api --> VMware Workstation --> 테스트 VM
WSL Ansible --SSH--> 테스트 VM (nginx 설치, 페이지 배포, HTTP 확인)
```

## 폴더 구성

| 경로 | 내용 |
|---|---|
| `lib/config.sh` | 모든 bash 스크립트가 불러오는 설정 로더 |
| `lab.env.example` | 설정 예시(가짜 값). `lab.env`로 복사해서 사용 |
| `*.sh`, `*.py` (최상위) | WSL에서 실행하는 본 스크립트 (2·3편) |
| `tcp-relay.ps1` | `guest-proxy.sh`가 호출하는 Windows SSH 중계 (3편) |
| `terraform/` | `main.tf`, `variables.tf` (provider `elsudano/vmworkstation` 2.0.1 고정) |
| `ansible/` | `configure-guest.yml` |
| `windows/` | Windows에서 실행: SSH 포워딩(1편), vmrest 자동 실행(2편) |
| `extras/` | 진단·호환용 스크립트와 예전 NAT 방식 브리지. 실습에는 필요 없음 |
| `.claude/skills/vmware-wsl-lab/` | AI 에이전트(Claude Code 등)용 설치·운영 스킬 |

## 개인 설정: `lab.env`

블로그 원본은 작성자 PC의 경로와 사용자 이름이 스크립트 안에 들어 있었습니다. 이 저장소에서는 그런 값을 모두 설정으로 뺐습니다.

```bash
cp lab.env.example lab.env
# VMWS_USERNAME / VMWS_PASSWORD 를 vmrest.exe -C 로 만든 API 계정으로 바꾼다
```

비밀번호를 Windows 드라이브(`/mnt/c`)에 두고 싶지 않다면 WSL 쪽에 두고 경로만 알려 주세요.

```bash
mkdir -p ~/.config/wsl-vmware-lab
cp lab.env.example ~/.config/wsl-vmware-lab/lab.env
chmod 600 ~/.config/wsl-vmware-lab/lab.env
export LAB_ENV_FILE=~/.config/wsl-vmware-lab/lab.env   # ~/.bashrc 에 추가
```

따로 지정하지 않으면 다음 기본값을 씁니다.

| 항목 | 기본값 | 변수 |
|---|---|---|
| Windows 쪽 VM 경로 | 로그인한 Windows 사용자 프로필 기준 `%USERPROFILE%\Documents\Virtual Machines\<클론>\<클론>.vmx` | `LAB_CLONE_VMX_WIN` |
| WSL 계정 / 게스트 VM 사용자 | `ubuntu` | `LAB_GUEST_USER` |
| 개인 파일(SSH 키, inventory, known_hosts) | `~/.config/wsl-vmware-lab/` | `LAB_PRIVATE_DIR` |
| VMware 설치 경로 | `/mnt/c/Program Files/VMware/VMware Workstation` | `VMWARE_DIR` |
| 베이스 / 클론 이름 | `ubuntu24-base` / `ubuntu24-demo` | `LAB_BASE_NAME` / `LAB_CLONE_NAME` |
| 클론 CPU / 메모리 | 2 / 2048 MB | `LAB_CLONE_CPUS` / `LAB_CLONE_MEMORY_MB` |
| 네트워크 | NAT `VMnet8`, 관리용 host-only `VMnet1` | `LAB_NAT_VNET` / `LAB_MGMT_VNET` |

Windows 스크립트는 설정 파일 대신 매개변수를 받습니다.

```powershell
# 관리자 PowerShell. 방화벽 허용 대역은 자신의 LAN으로 바꾼다
.\windows\wsl2-ssh-forward.ps1 Install -AllowedRemoteAddress 192.168.0.0/24 -Distro Ubuntu-24.04
.\windows\wsl2-ssh-forward.ps1 InstallTask -AllowedRemoteAddress 192.168.0.0/24
# vmrest 자동 실행. 두 파일을 고정 폴더(예: C:\Scripts)에 두고 실행
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-vmrest-task.ps1
```

`start-vmrest.ps1`은 기본으로 `%ProgramFiles%\VMware\VMware Workstation\vmrest.exe`를 실행합니다. 다른 곳에 설치했다면 `-VmrestPath`로 지정합니다.

## 실행 순서 (WSL Ubuntu, 저장소 최상위)

WSL 계정은 `ubuntu`로 만드는 것을 권장합니다. Windows에서 `wsl --install -d Ubuntu-24.04`를 실행한 뒤, 첫 실행 화면에서 사용자 이름을 `ubuntu`로 입력하면 됩니다. 저장소는 VM 파일과 같이 Windows 드라이브(예: `/mnt/c/...`)에 두세요.

```bash
sudo bash setup-wsl-tools.sh                 # Terraform(HashiCorp apt), Ansible, 이미지 도구
# Ubuntu 24.04 Server OVA와 SHA256SUMS를 cloud-images.ubuntu.com 에서 받아 저장소 최상위에 둔다
sha256sum --ignore-missing -c SHA256SUMS
bash extract-ubuntu-image.sh
bash prepare-cloud-init.sh
bash prepare-base.sh                         # 1회만: 베이스 VMX 생성, API 등록, 첫 부팅
bash api-status.sh                           # vmrest 확인
bash terraform-vm.sh on                      # 복제 -> cloud-init/NIC 준비 -> 전원 ON
ANSIBLE_TIMEOUT=60 bash configure-guest.sh   # nginx 설치, HTTP 확인 (두 번째 실행 changed=0)
bash terraform-vm.sh off
bash terraform-vm.sh destroy                 # 삭제 + seed ISO/빈 폴더 정리
```

자세한 설명과 함정은 블로그 글과 [`.claude/skills/vmware-wsl-lab/reference/pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md)를 참고하세요.

## 블로그 원본과 달라진 점

- 하드코딩된 경로·사용자(`/mnt/c/Users/<작성자>/...`, `/home/<작성자>`, 게스트 사용자, VMX 경로, VM ID)를 `lab.env`와 자동 감지로 바꿨습니다.
- 게스트 사용자 기본값이 `ubuntu`입니다. Ubuntu 클라우드 이미지의 기본 사용자와 같아서, 이때는 cloud-init의 `default` 항목을 따로 넣지 않습니다.
- 개인 파일 폴더 이름이 `~/.config/vmware-workstation-demo` → `~/.config/wsl-vmware-lab`, SSH 키 이름이 `demo_ed25519` → `lab_ed25519`로 바뀌었습니다. 예전 `vmrest.env`도 `VMWS_CREDENTIALS_FILE`로 지정하면 계속 읽습니다.
- `api-status.sh`, `check-power.sh`, `terraform-vm.sh`의 `curl`은 비밀번호를 명령줄 인자 대신 표준입력으로 넘깁니다(`ps`에 노출되지 않도록).
- `check-power.sh`는 VM ID를 인자로 받거나 Terraform 출력에서 읽습니다.
- `wsl2-ssh-forward.ps1`의 방화벽 허용 대역, `start-vmrest.ps1`의 실행 파일 경로, `extras/` 브리지의 주소를 매개변수로 바꿨습니다.

## 주의

- **검증 범위:** 블로그의 검증 결과는 원본 스크립트로 얻은 것입니다. 이 저장소의 설정 분리판은 아직 실제 VMware 호스트에서 처음부터 끝까지 실행해 보지 않았습니다. 처음 쓸 때는 결과를 단계마다 확인하세요.
- **올리면 안 되는 파일:** `lab.env`, SSH 개인키, `*.tfstate`, `inventory.json`, VM 디스크·ISO는 `.gitignore`에 들어 있습니다. 커밋하지 마세요.
- **비공식 provider:** `elsudano/vmworkstation`은 HashiCorp나 Broadcom이 아닌 커뮤니티 provider입니다. 버전을 올리기 전에 스키마를 확인하세요(`terraform providers schema -json`).
- **진단 스크립트:** `extras/diagnose-terraform.sh`는 베이스 VM을 끄고 `power_state=off`를 적용합니다. 실행 전에 내용을 읽어 보세요.

## License

[MIT](LICENSE)
