# Pitfalls: symptom → cause → fix

Merged from blog parts 1-3 and both runbooks. Match the symptom, confirm the cause with a read-only check, then apply only the scoped fix.

## Contents
- vmrest / API
- Terraform provider
- Guest boot, SSH, Ansible
- WSL SSH access
- Destroy / cleanup

## vmrest / API

| Symptom | Cause | Fix |
|---|---|---|
| Terraform hangs reading base VM, then fails; `curl` gives HTTP `000` | vmrest not running, no 8697 listener (common after reboot) | `./lab status` shows the Windows process/listener/task state; with the user's OK, `./lab status --start-vmrest` starts it and waits for 401 |
| Terraform 404 | endpoint missing `/api` | `http://127.0.0.1:8697/api` |
| WSL cannot reach `127.0.0.1:8697` | WSL in NAT mode; vmrest bound to loopback | Use mirrored mode. Do not expose Basic-auth vmrest to the LAN |
| VM missing from `/api/vms` | VMX/disk exist but not registered | `./lab setup` (registration is idempotent by path) |
| base registration gets HTTP 500; VMware log shows a VMX syntax error | `lab.env` written from Windows with CRLF line endings put `\r` into the VM name (older checkouts) | `lib/config.sh` now strips CR when loading `lab.env` and preflight warns about CRLF; on an older checkout convert it with `sed -i 's/\r$//' lab.env`, regenerate the base VMX and register again |
| `vmrest -C` fails with piped password | requires interactive input | the user runs `./lab account` in a terminal (it refuses without one) |
| `./lab status` still warns about other accounts on the secrets file after `icacls /inheritance:r /grant:r` | that removes inherited entries only; entries set directly on the file (e.g. `CodexSandboxUsers:(RX)`) stay | `./lab account --lock` (sets exactly your user, SYSTEM and Administrators) |
| Unauthenticated 401 works, authenticated request also 401 (Terraform/provider auth errors) | secrets file (`%USERPROFILE%\.env` or `LAB_SECRETS_FILE`) differs from the vmrest API account (`vmrest.exe -C`, stored in `vmrest.cfg`; password not readable) | user corrects the file, or runs `./lab account` again. Never read or print the values |
| preflight cannot find the account although one exists | it is in another file or under `VMWS_USER` instead of `VMWS_USERNAME` | both names are accepted; point `LAB_SECRETS_FILE` at the file |
| Account stored in Windows Credential Manager not visible from WSL over SSH | WSL started at boot without logon runs in a batch (S4U) session, where the Credential Manager vault stays locked | use the secrets file; this repository no longer uses Credential Manager |
| Account worked before, now 401 | vmrest restarted under another Windows user (other profile, other `vmrest.cfg`), or `-C` was re-run without updating the stored copy | check which user runs vmrest (logon task principal); keep one account in sync |
| Registration or another vmrest call returns HTTP 500 although the change happened | vmrest reports an error after doing the work | check the real state (`/api/vms`, VM folder) before retrying; `lib/register-vm.py` now re-reads the list after an error. Details are in the vmrest log, `%TEMP%\vmware-<user>\vmware-vmrest-*.log` (for the S4U task, the task user's `%TEMP%`) |
| Downloads or file writes under `C:\Users\...` are blocked (git clone, image download, VM disks) | antivirus blocks writes in the user profile | keep the repository outside the profile (e.g. `C:\wsl-vmware-lab`); for VM disks change Workstation's default VM location and restart vmrest, then set `LAB_VM_ROOT_WIN` to match; after moving the repository re-register the base and re-run the task installers |
| A tool started from WSL cannot create folders under `Documents` (`Failed to create directory ...\Virtual Machines\...`), while the same command in PowerShell works | Windows Defender **Controlled folder access** blocks the WSL-launched process | check `Get-MpPreference \| Select EnableControlledFolderAccess`; let the user allow the app or turn the feature off, or run the Windows tool through `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe` (full path; see WSL SSH access); keep the repository outside protected folders |
| Terraform `on` fails: `Provider produced inconsistent result after apply ... .path: was "<LAB_VM_ROOT_WIN>\..." but now "...Documents\Virtual Machines\..."` | vmrest clones into Workstation's default VM location, ignoring the requested path | set `LAB_VM_ROOT_WIN` to Workstation's default VM location (preflight warns on a mismatch), or change that Workstation setting and restart vmrest; then `./lab destroy` the half-created clone and retry |
| `a portproxy rule listens on 0.0.0.0:22 (NAT-era)` | an old portproxy holds 0.0.0.0:22 | in mirrored mode it collides with WSL sshd; with the user's OK: `netsh interface portproxy delete v4tov4 listenport=22 listenaddress=0.0.0.0` |
| `Hyper-V firewall rule ... does not look like this script's rule; left unchanged` | a same-name Hyper-V rule with a different display name, direction, VM creator or port | ask the user; the script will not modify or remove it |

## Terraform provider

| Symptom | Cause | Fix |
|---|---|---|
| "Invalid resource/data source" | names from incompatible examples | `terraform providers schema -json`; this pin uses `vmworkstation_virtual_machine`, `sourceid`, `denomination` |
| Empty Description error | provider rejects empty base description | add `annotation` to base VMX |
| HTTP 500 during creation | NIC removal on running VM (no hot-remove) | create OFF, bootstrap, then ON (keep OFF→bootstrap→ON order) |
| NAT NIC recreate fails even when OFF | provider NAT NIC recreation bug | base VMX `connectionType="custom"`, `vnet="VMnet8"` (assumes VMnet8 is NAT) |
| 409 "already exists" on retry | failed create left clone in API but not in state | compare API list and state before retry; do not delete blindly |
| Provider reports IP `0.0.0.0/0` | not a real address | inventory uses mgmt MAC → DHCP lease (`/mnt/c/ProgramData/VMware/vmnetdhcp.leases`): only the last entry per address counts, and it must be this MAC's, active, unexpired and in `LAB_MGMT_VNET`'s subnet from `vmnetdhcp.conf` |
| Several clones get the same NAT IP / MAC | vmrest copies the base VMX verbatim, including `uuid.bios` and `ethernet0.generatedAddress` | `lib/bootstrap-guest.sh` now removes the UUID and generated MACs and sets `uuid.action = "create"` before the first power-on; older clones need it applied while powered off |
| A `while read` loop over VMs stops after the first one | a Windows program (`vmrun.exe`, `powershell.exe`) inside the loop reads the loop's stdin | give Windows programs in loops `</dev/null` |

## Guest boot, SSH, Ansible

| Symptom | Cause | Fix |
|---|---|---|
| `sha256sum -c SHA256SUMS`: `no file was verified` | OVA saved under the old blog name; Ubuntu lists `noble-server-cloudimg-amd64.ova` | `./lab setup` (official name, signature + checksum) |
| VM crashes on boot | hand-written VMX lacks PCIe slot for `e1000e` | use `e1000` |
| `Host key verification failed` / `REMOTE HOST IDENTIFICATION HAS CHANGED` | the address answers with a key other than the one pinned for the clone at bootstrap: another VM got the address | check the lease (`./lab status`, `vmnetdhcp.leases`). `known_hosts-<id>` is written once by `lib/bootstrap-guest.sh` for each new disk; do not edit it. Never disable host key checking |
| `no pinned SSH host key` / SSH as `lab` never succeeds on an existing clone | the clone was created by an older version (image default user, host key reported through guestinfo) | rebuild: `./lab setup --recreate`, then `./lab up --allow-destroy` (clone contents are lost) |
| `Timeout (12s) waiting for privilege escalation prompt` | short default become wait (latency source unconfirmed; sudo itself verified passwordless) | `lib/configure.sh` now defaults `ANSIBLE_TIMEOUT=60`; raise it further if needed |
| WSL cannot SSH to guest mgmt IP | host-only range not reachable from mirrored WSL | inventory falls back to `lib/guest-proxy.sh` + `windows/tcp-relay.ps1` (no listening port created) |
| App/replica connects to an old subnet | stale separate copy of the deployment env file | keep one private env file (symlink copies to it); check addresses and inventory before deploy |
| `N registered VMs are named "<base>"` | another VM (a copy, an old base, a clone) has the base display name; the provider would clone the first match | rename or remove the others in Workstation's library (`./lab status`); nothing was changed |
| `on` refuses: "The base VM changed" | base rebuilt (`./lab setup --recreate`) or re-registered at another id/path | `./lab up --allow-destroy` rebuilds the clones from the new base (contents lost), after the user confirms |

## WSL SSH access

| Symptom | Cause | Fix |
|---|---|---|
| `ssh <user>@<windows-lan-ip>` refused or times out on a newly set up PC; WSL `ss -lnt` shows no `:22` | openssh-server never installed (WSL install/update and tools steps do not include it; preflight does not check it) | install-new-pc section 3: install `openssh-server`, enable it, then set up firewall and tasks |
| SSH drops, "The system will power off now!" | WSL exits when no foreground process | scheduled task `WSL2 SSH Service Start` running `sshd -D -e` |
| External SSH works briefly after setup, then fails; sshd `etime` keeps resetting | WSL idles out; `WSL2 SSH Service Start` is registered but has not run since registration | `Start-ScheduledTask -TaskName 'WSL2 SSH Service Start'` once now (current `InstallTask` does this); check `sshd -D -e` stays up |
| SSH from another PC times out on port 22 although everything worked before; nothing changed on the PC (often a laptop, after it was left alone) | Windows went to sleep or hibernation (power plan timeout or lid close), which stops WSL, sshd, vmrest and the VMs | wake the PC; `./lab status` shows the power values; `windows\setup.cmd Install` sets AC power to never sleep. Display-off is not the cause |
| `powershell.exe: command not found` (or `vmrun.exe`, `cmd.exe`) in a command run over SSH, although interop works | an SSH session into WSL has no Windows folders on `PATH`, also in a login/interactive shell (`bash -lic`); likely because the boot task, not a Windows logon, starts sshd (not confirmed) | call Windows programs by full path, e.g. `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command ... </dev/null`; hand the user the exact command you verified |
| `Test-NetConnection <own LAN IP> -Port 22` from Windows fails in mirrored mode | Windows itself has no `:22` listener; a same-host test is not representative | test from another LAN PC and read `/var/log/auth.log` for its address |
| Port 22 conflict | Windows OpenSSH Server owns 22 | choose deliberately; do not stop unrelated services silently |
| `.wslconfig` ignored | saved as `.wslconfig.txt` | rename |
| vmrest login fails with the Ubuntu password | the vmrest API account (`vmrest.exe -C`, interactive only) is separate from the WSL and guest login accounts | use the account set with `vmrest -C`; its values go only in `%USERPROFILE%\.env` |
| PowerShell 5.1 task aborts on systemctl message | stderr + `ErrorActionPreference=Stop` | judge by exit code and LISTEN state |
| task `WSL2 SSH Service Start` last result not 0; log shows `wsl: Failed to start the systemd user session` | `wsl.exe` prints this warning on stderr (seen in mirrored mode; root cause not confirmed) | judge by the port (`setup.ps1 Status`: sshd listens on :22) and a real SSH login from another PC, not by the task result |
| SSH or vmrest unreachable after reboot before logon | tasks from an older setup trigger only at logon | run `windows\setup.cmd Install` (elevated): boot trigger + S4U (SSH also at logon). Verified: SSH and vmrest answered before anyone logged on |

Do not restart WSL or edit scheduled tasks during an active remote session without a recovery path (Windows console).

## Destroy / cleanup

| Symptom | Cause | Fix |
|---|---|---|
| Seed ISO left after destroy | provider does not delete it | use `./lab destroy` (runs `lib/cleanup-guest.py`); bare `terraform destroy` skips it |
| `0 destroyed` | vmrest was off, nothing found | not success; start vmrest and recheck API + files |
| `SSH lab@<ip> not ready (Connection refused)` for minutes on a new clone | sshd not up: cloud-init still running, or a seed that starts `ssh.service` by hand (on Ubuntu 24.04 that fights `ssh.socket` on the first boot) | `lib/configure.sh` retries; the lab's seed leaves the ssh units alone. If it persists, check the clone's console |
| `cloud-init status --wait` never returns after a reboot | a unit ordered `After=cloud-final.service` and wanted by `multi-user.target` forms a cycle; systemd drops cloud-final | do not order guest units after cloud-final (see `lib/cloud-config.sh`) |
| `on` fails with HTTP 409 / Code 108 right after destroy | destroying a running clone can leave `<clone>.vmxf` in the clone folder | current `lib/cleanup-guest.py` removes a `.vmxf` that names the clone's VMX; otherwise check the folder before recreating |
| `Provider produced inconsistent result after apply ... .description` | the provider does not set a clone's description and reports the base VM's | keep `description = data.vmworkstation_virtual_machine.base.description` in `terraform/main.tf` |
| `Resource targeting is in effect` warning during `on` | expected: new VMs are created powered off with `-target` so running VMs stay on | none; the following full apply converges everything |
| Old `verify-lifecycle.sh` | uses bare destroy, predates cleanup flow | read its results; do not rerun as the preferred entry point |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` in Ansible after re-creating the clone | vmrest derives the VM id from the VMX path, so a clone re-created at the same path reuses the id and its old `known_hosts-<id>` | `lib/bootstrap-guest.sh` writes a new pin for every new disk; on older checkouts `git pull` and re-run `on`. Never disable host key checking |
