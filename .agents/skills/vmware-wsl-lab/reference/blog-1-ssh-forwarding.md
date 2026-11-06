# Blog part 1: WSL2 SSH reachable on Windows port 22

Summary of https://naelonambul.tistory.com/207 ("[WSL 자동화 1편] WSL2 SSH를 Windows 22번 포트로 포워딩하기"). Re-read the post if exact wording matters.

## Contents
- Goal and routes (NAT vs mirrored)
- Step 1: sshd in WSL
- Step 2: `wsl2-ssh-forward.ps1`
- Step 3: logon scheduled tasks
- Step 4: verify from another PC
- `.wslconfig` resource limits
- Troubleshooting notes from the post
- Verification scope stated by the post

## Goal and routes

Another PC connects to Windows port 22 and lands in WSL2 Ubuntu sshd. This WSL is the Terraform/Ansible workspace for parts 2-3.

- **NAT mode (WSL2 default):** other PC → Windows :22 (`netsh portproxy`) → WSL2 :22. WSL IP can change after reboot or `wsl --shutdown`, so the script re-reads it.
- **Mirrored mode:** other PC → shared Windows/WSL IP :22. No portproxy.

## Step 1: sshd in WSL

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
ss -lnt   # :22 LISTEN
```

## Step 2: forwarding script (admin PowerShell, in the script folder)

Pass your own LAN subnet and distro name if they differ from the defaults (`-AllowedRemoteAddress 192.168.0.0/24`, `-Distro Ubuntu-24.04`). The blog version required editing the script; this repository exposes them as parameters.

```powershell
.\wsl2-ssh-forward.ps1 Install    # first setup
.\wsl2-ssh-forward.ps1 Status
.\wsl2-ssh-forward.ps1 Refresh    # after WSL restart / IP change
.\wsl2-ssh-forward.ps1 Remove
```

Behavior:
- NAT: creates/updates `netsh interface portproxy add v4tov4 listenport=22 listenaddress=0.0.0.0 connectport=22 connectaddress=<WSL_IP>`.
- Mirrored: if WSL address equals a Windows local IPv4, no portproxy is created.
- Firewall: inbound TCP 22 on all profiles, remote address limited to the subnet.
- Stops (does not auto-disable) if Windows OpenSSH Server already owns port 22.
- Touches nothing other than port 22 (e.g. RDP untouched).

## Step 3: run at Windows logon

```powershell
.\wsl2-ssh-forward.ps1 InstallTask
.\wsl2-ssh-forward.ps1 RemoveTask
```

| Scheduled task | Role | Privilege / healthy state |
|---|---|---|
| `WSL2 SSH Port Forward Refresh` | refresh forwarding for current network mode | admin / exit code 0 |
| `WSL2 SSH Service Start` | stop `ssh.socket`/`ssh.service`, run `sshd -D -e` in foreground | normal user / Running, no time limit |

```bash
wsl.exe -d Ubuntu-24.04 -u root -- /bin/sh -c 'systemctl stop ssh.socket ssh.service; mkdir -p /run/sshd; exec /usr/sbin/sshd -D -e'
```

- Holding `sshd -D` keeps WSL alive. `systemctl enable --now ssh` alone lets WSL shut down when the command ends, dropping SSH.
- Trigger is Windows **logon**, not boot.
- After a manual `wsl --shutdown`, run `Refresh` again.

## Step 4: verify from another PC

```bash
ssh -p 22 <wsl-user>@<Windows_PC_IP>
```

Confirm an actual login. Failure log: `%LOCALAPPDATA%\wsl2-ssh-forward.log`. Windows OpenSSH *client* is unrelated to the server.

## `.wslconfig` (`%UserProfile%\.wslconfig`, applies to all of WSL2)

```ini
[wsl2]
memory=2GB
processors=2
swap=1GB
guiApplications=false
nestedVirtualization=false

[experimental]
autoMemoryReclaim=dropCache
```

Apply: `wsl --shutdown` then `.\wsl2-ssh-forward.ps1 Refresh`. Check with `free -h`, `nproc`. These are the post's example values; size them for your own machine. Do not copy limits to an unrelated machine.

Tip from the post: add `networkingMode=mirrored` under `[wsl2]` from the start, since part 2 needs it for vmrest.

Ports: 22 = SSH (external → Windows → WSL); 8697 = vmrest (WSL → Windows, part 2).

## Troubleshooting notes from the post

1. **WSL powered off during SSH** ("The system will power off now!"): service-only start does not keep WSL alive → foreground `sshd -D -e`.
2. **Stale portproxy in mirrored mode:** a NAT-era `0.0.0.0:22 → <Windows LAN IP>:22` rule pointed at the host's own address → delete it; script skips portproxy when mirrored.
3. **Empty-port check failed:** `Get-NetTCPConnection` errors when no listener exists → treat empty as "port free".
4. **PowerShell 5.1 task aborted:** systemctl notices on stderr tripped `ErrorActionPreference=Stop` → separate that output; judge success by exit code and port 22 LISTEN.
5. **`.wslconfig.txt`:** Notepad may append `.txt`; then it is ignored.

## Verification scope stated by the post

- Confirmed: refresh task exit 0, SSH task Running (PT0S), `sshd -D -e` and TCP 22 LISTEN in Ubuntu.
- Not confirmed: later reboot and long-running persistence, reconnection from an external PC (an earlier LAN IP check timed out).
