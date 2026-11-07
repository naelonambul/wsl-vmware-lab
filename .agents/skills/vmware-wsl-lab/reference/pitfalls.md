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
| Terraform hangs reading base VM, then fails; `curl` gives HTTP `000` | vmrest not running, no 8697 listener (common after reboot) | `bash preflight.sh` shows the Windows process/listener/task state; with the user's OK, `bash preflight.sh --start-vmrest` starts it and waits for 401 |
| Terraform 404 | endpoint missing `/api` | `http://127.0.0.1:8697/api` |
| WSL cannot reach `127.0.0.1:8697` | WSL in NAT mode; vmrest bound to loopback | Use mirrored mode. Do not expose Basic-auth vmrest to the LAN |
| VM missing from `/api/vms` | VMX/disk exist but not registered | `bash register-base.sh` (idempotent by path) |
| `register-base.sh` gets HTTP 500; VMware log shows a VMX syntax error | `lab.env` written from Windows with CRLF line endings put `\r` into the VM name (older checkouts) | `lib/config.sh` now strips CR when loading `lab.env` and preflight warns about CRLF; on an older checkout convert it with `sed -i 's/\r$//' lab.env`, regenerate the base VMX and register again |
| `vmrest -C` fails with piped password | requires interactive input | user types it interactively |
| Unauthenticated 401 works, authenticated request also 401 (Terraform/provider auth errors) | secrets file (`%USERPROFILE%\.env` or `LAB_SECRETS_FILE`) differs from the vmrest API account (`vmrest.exe -C`, stored in `vmrest.cfg`; password not readable) | user corrects the file, or re-runs `vmrest.exe -C`, writes the same values and restarts vmrest. Never read or print the values |
| preflight cannot find the account although one exists | it is in another file or under `VMWS_USER` instead of `VMWS_USERNAME` | both names are accepted; point `LAB_SECRETS_FILE` at the file |
| Account stored in Windows Credential Manager not visible from WSL over SSH | WSL started at boot without logon runs in a batch (S4U) session, where the Credential Manager vault stays locked | use the secrets file; this repository no longer uses Credential Manager |
| Account worked before, now 401 | vmrest restarted under another Windows user (other profile, other `vmrest.cfg`), or `-C` was re-run without updating the stored copy | check which user runs vmrest (logon task principal); keep one account in sync |
| `inspect-base.sh` fails on `listRegisteredVM` | unsupported command | use `api-status.sh` |
| Registration or another vmrest call returns HTTP 500 although the change happened | vmrest reports an error after doing the work | check the real state (`/api/vms`, VM folder) before retrying; `register-vm.py` now re-reads the list after an error. Details are in the vmrest log, `%TEMP%\vmware-<user>\vmware-vmrest-*.log` (for the S4U task, the task user's `%TEMP%`) |
| Downloads or file writes under `C:\Users\...` are blocked (git clone, image download, VM disks) | antivirus blocks writes in the user profile | keep the repository outside the profile (e.g. `C:\wsl-vmware-lab`); for VM disks change Workstation's default VM location and restart vmrest, then set `LAB_VM_ROOT_WIN` to match; after moving the repository re-register the base and re-run the task installers |
| A tool started from WSL cannot create folders under `Documents` (`Failed to create directory ...\Virtual Machines\...`), while the same command in PowerShell works | Windows Defender **Controlled folder access** blocks the WSL-launched process | check `Get-MpPreference \| Select EnableControlledFolderAccess`; let the user allow the app or turn the feature off, or run the Windows tool through `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe` (full path; see WSL SSH access); keep the repository outside protected folders |
| Terraform `on` fails: `Provider produced inconsistent result after apply ... .path: was "<LAB_VM_ROOT_WIN>\..." but now "...Documents\Virtual Machines\..."` | vmrest clones into Workstation's default VM location, ignoring the requested path | set `LAB_VM_ROOT_WIN` to Workstation's default VM location (preflight warns on a mismatch), or change that Workstation setting and restart vmrest; then `terraform-vm.sh destroy` the half-created clone and retry |
| Scheduled task fails after moving the repository | tasks registered by an older version store the checkout path | re-run `windows/install-vmrest-task.ps1` and `wsl2-ssh-forward.ps1 InstallTask` (elevated); current versions run a copy in `%ProgramFiles%\wsl-vmware-lab` |
| Fix pulled into the repository has no effect on boot tasks | tasks run the copy in `%ProgramFiles%\wsl-vmware-lab` | re-run both installs (elevated); `preflight.sh` warns when the copy differs |
| Install refuses: `... can be changed by <user>; refusing to use it for a scheduled task` | `%ProgramFiles%\wsl-vmware-lab` ACL lets a non-administrator write | restore inherited Program Files permissions on that folder (or delete it) and re-run the install |
| `A portproxy not created by this script uses 0.0.0.0:22 ...` | another tool's portproxy holds 0.0.0.0:22; the script records the one it creates and touches only that | ask the user before deleting it; in mirrored mode it can collide with WSL sshd |
| `Hyper-V firewall rule ... does not look like this script's rule; left unchanged` | a same-name Hyper-V rule with a different display name, direction, VM creator or port | ask the user; the script will not modify or remove it |

## Terraform provider

| Symptom | Cause | Fix |
|---|---|---|
| "Invalid resource/data source" | names from incompatible examples | `terraform providers schema -json`; this pin uses `vmworkstation_virtual_machine`, `sourceid`, `denomination` |
| Empty Description error | provider rejects empty base description | add `annotation` to base VMX |
| HTTP 500 during creation | NIC removal on running VM (no hot-remove) | create OFF, bootstrap, then ON (keep OFF→bootstrap→ON order) |
| NAT NIC recreate fails even when OFF | provider NAT NIC recreation bug | base VMX `connectionType="custom"`, `vnet="VMnet8"` (assumes VMnet8 is NAT) |
| 409 "already exists" on retry | failed create left clone in API but not in state | compare API list and state before retry; do not delete blindly |
| Provider reports IP `0.0.0.0/0` | not a real address | inventory uses mgmt MAC → DHCP lease (`/mnt/c/ProgramData/VMware/vmnetdhcp.leases`) |
| Several clones get the same NAT IP / MAC | vmrest copies the base VMX verbatim, including `uuid.bios` and `ethernet0.generatedAddress` | `bootstrap-guest.sh` now removes the UUID and generated MACs and sets `uuid.action = "create"` before the first power-on; older clones need it applied while powered off |
| A `while read` loop over VMs stops after the first one | a Windows program (`vmrun.exe`, `powershell.exe`) inside the loop reads the loop's stdin | give Windows programs in loops `</dev/null` |

## Guest boot, SSH, Ansible

| Symptom | Cause | Fix |
|---|---|---|
| `sha256sum -c SHA256SUMS`: `no file was verified` | OVA saved under the old blog name; Ubuntu lists `noble-server-cloudimg-amd64.ova` | `bash download-ubuntu-image.sh` (official name, signature + checksum) |
| VM crashes on boot | hand-written VMX lacks PCIe slot for `e1000e` | use `e1000` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | clone first exposes base host key, or recreated clone reuses VM ID/IP | verify clone via API path + mgmt MAC/lease, then `ssh-keygen -f <clone-specific-known-hosts> -R <guest-IP>` only. Never disable host checking globally |
| `Timeout (12s) waiting for privilege escalation prompt` | short default become wait (latency source unconfirmed; sudo itself verified passwordless) | `configure-guest.sh` now defaults `ANSIBLE_TIMEOUT=60`; raise it further if needed |
| WSL cannot SSH to guest mgmt IP | host-only range not reachable from mirrored WSL | inventory falls back to `guest-proxy.sh` + `tcp-relay.ps1` (no listening port created) |
| App/replica connects to an old subnet | stale separate copy of the deployment env file | keep one private env file (symlink copies to it); check addresses and inventory before deploy |
| `base` boot "done" after 45 s (older checkouts) | fixed sleep in `prepare-base.sh` | `prepare-base.sh` now waits (up to 10 min) for the guestinfo user report from first-boot cloud-init before shutting the base down |

## WSL SSH access

| Symptom | Cause | Fix |
|---|---|---|
| `ssh <user>@<windows-lan-ip>` refused or times out on a newly set up PC; WSL `ss -lnt` shows no `:22` | openssh-server never installed (WSL install/update and tools steps do not include it; preflight does not check it) | install-new-pc section 3: install `openssh-server`, enable it, then set up firewall and tasks |
| SSH drops, "The system will power off now!" | WSL exits when no foreground process | scheduled task `WSL2 SSH Service Start` running `sshd -D -e` |
| External SSH works briefly after setup, then fails; sshd `etime` keeps resetting | WSL idles out; `WSL2 SSH Service Start` is registered but has not run since registration | `Start-ScheduledTask -TaskName 'WSL2 SSH Service Start'` once now (current `InstallTask` does this); check `sshd -D -e` stays up |
| SSH from another PC times out on port 22 although everything worked before; nothing changed on the PC (often a laptop, after it was left alone) | Windows went to sleep or hibernation (power plan timeout or lid close), which stops WSL, sshd, vmrest and the VMs | wake the PC; preflight `power (plugged in)` warning shows the cause; the user runs `windows/configure-power.ps1 -Action Apply` (undo: `-Action Restore`). Display-off is not the cause |
| `powershell.exe: command not found` (or `vmrun.exe`, `cmd.exe`) in a command run over SSH, although interop works | an SSH session into WSL has no Windows folders on `PATH`, also in a login/interactive shell (`bash -lic`); likely because the boot task, not a Windows logon, starts sshd (not confirmed) | call Windows programs by full path, e.g. `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command ... </dev/null`; hand the user the exact command you verified |
| `Test-NetConnection <own LAN IP> -Port 22` from Windows fails in mirrored mode | Windows itself has no `:22` listener; a same-host test is not representative | test from another LAN PC and read `/var/log/auth.log` for its address |
| portproxy rule points at itself in mirrored mode | NAT-era rule left over | remove it; mirrored mode needs no portproxy |
| Port 22 conflict | Windows OpenSSH Server owns 22 | choose deliberately; do not stop unrelated services silently |
| `.wslconfig` ignored | saved as `.wslconfig.txt` | rename |
| PowerShell 5.1 task aborts on systemctl message | stderr + `ErrorActionPreference=Stop` | judge by exit code and LISTEN state |
| `WSL2 SSH Port Forward Refresh` last result `1`; log shows `wsl: Failed to start the systemd user session` | `wsl.exe` prints this warning on stderr and the task reports failure (seen in mirrored mode; root cause not confirmed) | judge by a real SSH login from another PC; in mirrored mode no portproxy is needed anyway |
| SSH unreachable after reboot before logon | SSH tasks registered by an older `wsl2-ssh-forward.ps1` trigger only at logon | re-run `wsl2-ssh-forward.ps1 InstallTask` (elevated): boot trigger + S4U, plus logon. Verified: external SSH worked before anyone logged on |
| vmrest down after reboot until someone logs on | vmrest started by a logon task | re-run `windows/install-vmrest-task.ps1` (elevated): boot trigger + S4U. Verified: vmrest answered with no user logged on |

Do not restart WSL or edit scheduled tasks during an active remote session without a recovery path (Windows console).

## Destroy / cleanup

| Symptom | Cause | Fix |
|---|---|---|
| Seed ISO left after destroy | provider does not delete it | use `terraform-vm.sh destroy` (runs `cleanup-guest.py`); bare `terraform destroy` skips it |
| `0 destroyed` | vmrest was off, nothing found | not success; start vmrest and recheck API + files |
| `Guest has not reported its default user through guestinfo yet` | guest still booting, or `open-vm-tools` / the `wsl-vmware-lab-guestinfo` unit missing in the guest (non-Ubuntu images such as Debian 12 cloud images lack `open-vm-tools`; only Ubuntu cloud images are supported) | `configure-guest.sh` retries; if it persists, check the image ships `open-vm-tools` and the unit's result |
| `cloud-init status --wait` never returns after a reboot | a unit ordered `After=cloud-final.service` and wanted by `multi-user.target` forms a cycle; systemd drops cloud-final | do not order guest units after cloud-final (see `lib/cloud-config.sh`) |
| `on` fails with HTTP 409 / Code 108 right after destroy | destroying a running clone can leave `<clone>.vmxf` in the clone folder | current `cleanup-guest.py` removes a `.vmxf` that names the clone's VMX; otherwise check the folder before recreating |
| `Provider produced inconsistent result after apply ... .description` | the provider does not set a clone's description and reports the base VM's | keep `description = data.vmworkstation_virtual_machine.base.description` in `terraform/main.tf` |
| `Resource targeting is in effect` warning during `on` | expected: new VMs are created powered off with `-target` so running VMs stay on | none; the following full apply converges everything |
| Old `verify-lifecycle.sh` | uses bare destroy, predates cleanup flow | read its results; do not rerun as the preferred entry point |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` in Ansible after re-creating the clone | vmrest derives the VM id from the VMX path, so a clone re-created at the same path reuses the id and its old `known_hosts-<id>` | current `bootstrap-guest.sh` resets `known_hosts-<id>` for each fresh clone, and `terraform-vm.sh destroy` removes it; on older checkouts `git pull` and re-run `on`. Never disable host key checking |
