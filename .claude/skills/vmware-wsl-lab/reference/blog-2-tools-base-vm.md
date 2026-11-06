# Blog part 2: tools, vmrest and base VM registration

Summary of https://naelonambul.tistory.com/208 ("[WSL 자동화 2편] VMware 실습 도구 설치와 베이스 VM API 등록"). Re-read the post if exact wording matters.

Repository differences from the post: the vmrest account goes in `%USERPROFILE%\.env` instead of `~/.config/vmware-workstation-demo/vmrest.env` (still read if `VMWS_CREDENTIALS_FILE` points to it); the vmrest task starts at boot without logon (S4U) instead of at logon; the guest user is the image's default user, reported via VMware guestinfo; Windows scripts live in `windows/`; diagnostics live in `extras/`.

## Contents
- Environment and ports
- Step 1: WSL mirrored mode
- Step 2: tools in WSL
- Step 3: vmrest account and auto-start (repository: at boot)
- Step 4: base image
- Step 5: base VM creation and registration
- Pitfalls from the post

## Environment and ports

- Windows 11, WSL `Ubuntu-24.04`, VMware Workstation Pro 26
- Terraform 1.17.1, Ansible 2.16.3 (versions stated by the post)
- Provider `elsudano/vmworkstation` 2.0.1 (community provider)
- Base: Ubuntu 24.04 Server cloud image (no desktop); test VM 2 vCPU / 2 GB RAM
- Ports: 22 = WSL SSH (part 1); 8697 = vmrest, bound to `127.0.0.1` only

## Step 1: mirrored mode (Windows)

Add under `[wsl2]` in `%UserProfile%\.wslconfig` (not `.wslconfig.txt`), keeping existing memory/processors lines:

```ini
networkingMode=mirrored
```

```powershell
wsl --shutdown
.\wsl2-ssh-forward.ps1 Refresh
```

In mirrored mode WSL `127.0.0.1` is Windows loopback, so vmrest is reachable directly. Existing SSH sessions drop; re-check SSH from another PC.

## Step 2: tools (WSL)

```bash
sudo bash setup-wsl-tools.sh
```

Installs Terraform from the HashiCorp signed apt repo (not Ubuntu's), plus `ansible`, `python3`, `qemu-utils`, `cloud-image-utils`, `genisoimage`, `openssh-client`.

```bash
terraform version
ansible --version
python3 --version
qemu-img --version
cloud-localds --help
```

## Step 3: vmrest

```bash
# interactive account setup - the user types credentials themselves
"/mnt/c/Program Files/VMware/VMware Workstation/vmrest.exe" -C
# manual run
"/mnt/c/Program Files/VMware/VMware Workstation/vmrest.exe" -p 8697
```

Health: unauthenticated `http://127.0.0.1:8697/api/vms` returning **HTTP 401** means the server is up.

Auto-start (Windows; the post used a logon task, the repository registers a boot/S4U task): keep `start-vmrest.ps1` and `install-vmrest-task.ps1` together in a fixed folder (e.g. `C:\Scripts\`) and do not move them after registering.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-vmrest-task.ps1
Unregister-ScheduledTask -TaskName "VMware vmrest API" -Confirm:$false   # remove
```

- Task name `VMware vmrest API`; logs `%LOCALAPPDATA%\WSL-VMware`.
- `start-vmrest.ps1` skips if already running; edit its install path if different.

## Step 4: base image (WSL, project folder)

Download the Ubuntu 24.04 Server OVA and `SHA256SUMS` from the official Ubuntu cloud image site.

```bash
sha256sum --ignore-missing -c SHA256SUMS   # integrity
bash extract-ubuntu-image.sh               # OVA -> VMDK
```

In this repository use `bash download-ubuntu-image.sh` instead of the first line: Ubuntu now publishes `noble-server-cloudimg-amd64.ova`, so a file saved under the blog's name is not matched by `SHA256SUMS` (`no file was verified`). The script also verifies the `SHA256SUMS.gpg` signature.

```bash
bash download-ubuntu-image.sh
bash extract-ubuntu-image.sh
bash prepare-cloud-init.sh                 # first-boot config
```

Put only the SSH **public** key into cloud-init.

## Step 5: base VM (WSL, run once)

```bash
bash prepare-base.sh
```

`prepare-base.sh` → `create-base-template.sh` (VMX + disk) → `register-base.sh` (register) → first boot.

```bash
bash register-base.sh
bash register-base.sh /mnt/c/VMs/ubuntu-base/ubuntu-base.vmx ubuntu24-base   # other VMX
```

`register-vm.py`: `wslpath` → Windows path; `GET /api/vms` and skip if the path exists; else `POST /api/vms/registration` with `name`, `path`. It never powers on or clones.

## Pitfalls from the post

- **NAT mode cannot reach vmrest** on `127.0.0.1:8697`; mirrored mode is required.
- **`vmrest -C` must be interactive**; piping a password did not work.
- **API account ≠ Ubuntu login account.**
- **vmrest not running after reboot** → no 8697 listener, HTTP 000 timeout, Terraform hangs on base lookup. Set up auto-start.
- **Unregistered VMs are invisible** to `/api/vms` even if VMX/disk exist.
- **Auto-start after reboot not verified** by the post (task exit 0 and HTTP 401 were). The repository's boot/S4U task was verified on 2026-11-06: vmrest was up before anyone logged on.
- **`listRegisteredVM` unsupported** (used by `inspect-base.sh`); check registration with `api-status.sh`.
- `open-base.sh` is a legacy entry point (use `register-base.sh`); `inspect-base.sh` is diagnostic only.
