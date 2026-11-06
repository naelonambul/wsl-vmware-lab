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
| Terraform hangs reading base VM, then fails; `curl` gives HTTP `000` | vmrest not running, no 8697 listener (common after reboot) | Check Windows process/listener (`Get-NetTCPConnection` port 8697); start vmrest / its logon task `VMware vmrest API`; re-probe expecting 401 |
| Terraform 404 | endpoint missing `/api` | `http://127.0.0.1:8697/api` |
| WSL cannot reach `127.0.0.1:8697` | WSL in NAT mode; vmrest bound to loopback | Use mirrored mode. Do not expose Basic-auth vmrest to the LAN |
| VM missing from `/api/vms` | VMX/disk exist but not registered | `bash register-base.sh` (idempotent by path) |
| `vmrest -C` fails with piped password | requires interactive input | user types it interactively |
| `inspect-base.sh` fails on `listRegisteredVM` | unsupported command | use `api-status.sh` |

## Terraform provider

| Symptom | Cause | Fix |
|---|---|---|
| "Invalid resource/data source" | names from incompatible examples | `terraform providers schema -json`; this pin uses `vmworkstation_virtual_machine`, `sourceid`, `denomination` |
| Empty Description error | provider rejects empty base description | add `annotation` to base VMX |
| HTTP 500 during creation | NIC removal on running VM (no hot-remove) | create OFF, bootstrap, then ON (keep OFF→bootstrap→ON order) |
| NAT NIC recreate fails even when OFF | provider NAT NIC recreation bug | base VMX `connectionType="custom"`, `vnet="VMnet8"` (assumes VMnet8 is NAT) |
| 409 "already exists" on retry | failed create left clone in API but not in state | compare API list and state before retry; do not delete blindly |
| Provider reports IP `0.0.0.0/0` | not a real address | inventory uses mgmt MAC → DHCP lease (`/mnt/c/ProgramData/VMware/vmnetdhcp.leases`) |

## Guest boot, SSH, Ansible

| Symptom | Cause | Fix |
|---|---|---|
| VM crashes on boot | hand-written VMX lacks PCIe slot for `e1000e` | use `e1000` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | clone first exposes base host key, or recreated clone reuses VM ID/IP | verify clone via API path + mgmt MAC/lease, then `ssh-keygen -f <clone-specific-known-hosts> -R <guest-IP>` only. Never disable host checking globally |
| `Timeout (12s) waiting for privilege escalation prompt` | short default become wait (latency source unconfirmed; sudo itself verified passwordless) | `ANSIBLE_TIMEOUT=60` |
| WSL cannot SSH to guest mgmt IP | host-only range not reachable from mirrored WSL | inventory falls back to `guest-proxy.sh` + `tcp-relay.ps1` (no listening port created) |
| App/replica connects to an old subnet | stale separate copy of the deployment env file | keep one private env file (symlink copies to it); check addresses and inventory before deploy |
| `base` boot "done" after 45 s | fixed sleep in `prepare-base.sh` | does not prove cloud-init completion; verify separately |

## WSL SSH access

| Symptom | Cause | Fix |
|---|---|---|
| SSH drops, "The system will power off now!" | WSL exits when no foreground process | scheduled task `WSL2 SSH Service Start` running `sshd -D -e` |
| portproxy rule points at itself in mirrored mode | NAT-era rule left over | remove it; mirrored mode needs no portproxy |
| Port 22 conflict | Windows OpenSSH Server owns 22 | choose deliberately; do not stop unrelated services silently |
| `.wslconfig` ignored | saved as `.wslconfig.txt` | rename |
| PowerShell 5.1 task aborts on systemctl message | stderr + `ErrorActionPreference=Stop` | judge by exit code and LISTEN state |
| Unreachable after reboot before logon | tasks trigger at logon, not boot | expected; needs user logon |

Do not restart WSL or edit scheduled tasks during an active remote session without a recovery path (Windows console).

## Destroy / cleanup

| Symptom | Cause | Fix |
|---|---|---|
| Seed ISO left after destroy | provider does not delete it | use `terraform-vm.sh destroy` (runs `cleanup-guest.py`); bare `terraform destroy` skips it |
| `0 destroyed` | vmrest was off, nothing found | not success; start vmrest and recheck API + files |
| Old `verify-lifecycle.sh` | uses bare destroy, predates cleanup flow | read its results; do not rerun as the preferred entry point |
| WSL seed dirs / known_hosts remain | wrapper does not remove them | expected; remove only verified clone-specific entries if asked |
