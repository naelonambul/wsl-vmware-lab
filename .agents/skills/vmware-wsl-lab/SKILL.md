---
name: vmware-wsl-lab
description: Sets up and operates a Windows + WSL2 + VMware Workstation lab where Linux Terraform (elsudano/vmworkstation provider via the vmrest API) clones Ubuntu VMs and Ansible configures them over SSH, using the scripts in the wsl-vmware-lab repository, to build, test or deploy systems of one or more VMs (vms.tfvars + the user's own playbooks; the Ubuntu + nginx VM is only the example). Use when installing or updating WSL, setting WSL resource limits, resuming setup after a reboot, installing WSL SSH access, VMware Workstation, vmrest, Terraform or Ansible on a Windows PC; when creating, powering, configuring or destroying lab VMs; when editing lab.env; or when debugging vmrest port 8697, WSL mirrored networking, cloud-init, DHCP-lease inventory or stale known_hosts errors.
---

# VMware Workstation + WSL lab

**Purpose.** This lab is a base for building, testing and deploying systems with Terraform + Ansible on one Windows PC: Terraform creates the VMs listed in `vms.tfvars` (one or many), Ansible runs the user's own playbooks against them. The single Ubuntu VM with nginx (`ubuntu24-demo`, `ansible/configure-guest.yml`) is only the example and smoke test. Guests are Ubuntu cloud images; what runs on them is up to the user's playbooks.

Host name, Windows user, WSL user, distro and repository location differ on every machine. Discover them; never reuse values from examples or earlier sessions.

## 0. VMware networks first, then environment and preflight

Before `./lab setup` or **any** `./lab up`, run `./lab network` read-only in each host's checkout. Read [reference/network.md](reference/network.md) for the evidence checklist and read-only PowerShell fallback when WSL/scripts cannot run. Record VMnet0/1/8 and every other VMnet: actual role evidence, subnet, host adapter, DHCP/NAT settings, NAT forwards, physical adapters and bridge bindings. A VMnet number does not prove its type. Bindings are candidates, not proof of the adapter Automatic selected. Never reset VMware networks.

If VMnet0 Automatic's physical bridge remains unresolved, show the fresh evidence and ask the user before enabling `lan`. Select `LAB_LAN_VNET` only from inspected evidence; empty/VMnet0 is bridged, VMnet1-19 is custom, and the effective LAN network must differ from NAT and management. Existing LAN mismatches block every `up`, including `--allow-destroy`; `down` stays available for offline repair. Never bypass the gate or rerun bootstrap on an existing disk. A base NAT mismatch needs `setup --recreate` and rebuilt clones: show the impact and ask the user first.

`setup.cmd Install` is a host mutation: boot tasks for WSL sshd and vmrest, legacy cleanup, Windows/Hyper-V SSH firewall rules, AC power policy (battery only with `-IncludeBattery`, power skipped with `-SkipPower`), and removing VMware Bridge Protocol bindings from virtual adapters. Network inspection does not authorize Install. `setup.cmd Network` and Status are read-only and need no elevation.

On Windows, inspect `wsl --version` and `wsl --list --verbose` first. For initial WSL setup or a pending installation reboot, read [reference/install-new-pc.md](reference/install-new-pc.md), section 2, before attempting Bash preflight. The setup order is WSL web update, host-specific resource settings, then Ubuntu preparation. A reboot-required result is a checkpoint, not completed installation. Keep the setup checkpoint in `%LOCALAPPDATA%\wsl-vmware-lab\setup-checkpoint.json` (non-secret JSON: stage, boot time, completed and pending steps, next checks); read it first when resuming. Resume from recorded evidence after reboot; do not reset or reinstall an existing distribution. An explicit update/setup request follows this path even when WSL is already installed.

If you are already in a WSL shell (for example over SSH), SSH works; do not spend time checking it. Find the repository, then run preflight:

```bash
# Lists every checkout of this repository (any folder name): WSL home, Windows users, and
# shallow folders on C:/D: (C:\wsl-vmware-lab when antivirus blocks the user profile).
{ find "$HOME" /mnt/c/Users -maxdepth 6 -type f \( -name lab -o -name preflight.sh \) 2>/dev/null
  find /mnt/c /mnt/d -maxdepth 3 -type f \( -name lab -o -name preflight.sh \) 2>/dev/null; } | sort -u \
  | while read -r f; do [ -f "$(dirname "$f")/lib/config.sh" ] && dirname "$f"; done | sort -u
repo=<the one path printed>     # several printed: ask the user which one
"$repo/lab" status
```

If nothing is printed, ask the user where the repository is, or whether to clone https://github.com/naelonambul/wsl-vmware-lab. Preflight reports the discovered repository, WSL user, distro, Windows profile, networking mode, which secrets file holds the vmrest account (values hidden) and whether other users can read it, tools and vmrest state. Exit code 0 means vmrest is reachable **and** the stored vmrest account is accepted. It does not test WSL SSH from another PC, the base VM or a clone lifecycle.

vmrest has its own API account: a username and password set with `vmrest.exe -C`, kept by vmrest in `vmrest.cfg` in the Windows user profile, with the password not stored readably. It is separate from the Windows and Ubuntu logins. The scripts' copy of that account lives in a **secrets file in the Windows user folder**, `%USERPROFILE%\.env` by default (`LAB_SECRETS_FILE` to change it), as `VMWS_USERNAME=` (or `VMWS_USER=`) and `VMWS_PASSWORD=` lines. The file is parsed, never executed, so other tools may keep their own lines in it. It is readable at boot with nobody logged on; Windows Credential Manager was tried and is not (it stays locked without a logon). The user writes the file; when authentication fails, a mismatch between it and vmrest's account is the first suspect. Never read, print or guess the values.

When preflight fails at vmrest:

| Preflight output | Meaning | Next step |
|---|---|---|
| `HTTP 000` and `process=False` | vmrest is not running | Ask the user, then `"$repo/lab" status --start-vmrest` (starts the `VMware vmrest API` startup task; if it is absent the user runs `windows\setup.cmd Install -AllowedRemoteAddress <LAN>` (elevated PowerShell)) |
| `HTTP 000` but `process=True listener8697=True` | vmrest runs; WSL cannot reach it | Check `VMWS_ENDPOINT` and mirrored networking. Do not start a second vmrest |
| `HTTP 404` | endpoint lacks `/api` | Fix `VMWS_ENDPOINT` |
| `... .env not found` / `lacks VMWS_USERNAME` | no usable secrets file | Look for an existing copy first (another `.env`, an old `vmrest.env`; check variable **names** only). Then ask the user to run `./lab account` in their own terminal (vmrest `-C` + secrets file), or to point `LAB_SECRETS_FILE` at the existing file |
| `secrets file also grants access to ...` warning | other accounts can read it | With the user's OK run `./lab account --lock` (your user, SYSTEM and Administrators only; also removes explicit entries that `icacls /inheritance:r` leaves) |
| authenticated `HTTP 401` | secrets file does not match vmrest | The user corrects the file, or runs `./lab account` again (sets both and restarts vmrest). Also check vmrest runs as the same Windows user (another user has another `vmrest.cfg`) |
| `no vmrest.cfg` warning | API account never set up for this Windows user | The user runs `./lab account` |
| `task 'VMware vmrest API' absent` or `from an older setup` (Windows section of status) | vmrest or sshd will not come back at boot | Both must start at **boot, without logon**. Offer `windows\setup.cmd Install -AllowedRemoteAddress <LAN>` (elevated PowerShell): boot trigger, S4U, restart on failure; it also removes older tasks |
| `other enabled task(s) also start vmrest` | two launchers (for example one made by another tool) | Ask the user, then disable the other task (do not delete it) so `VMware vmrest API` is the only launcher |
| `power on AC still allows: sleep` (or hibernate / lid) | Windows will sleep and drop SSH, vmrest and the VMs | `setup.cmd Install` sets AC power to never sleep (with the user's OK; `-SkipPower` leaves it). Not a vmrest failure; status still exits 0 |
| `power (on battery): ...` | only matters when unplugged | Tell the user; `-Action Apply -IncludeBattery` if the PC runs on battery |
| `no interop` | WSL cannot run Windows programs | The user checks vmrest on Windows |

Do not run Terraform until preflight exits 0.

## 1. Choose the path

**Preparing a new Windows PC** (no WSL SSH / VMware / vmrest / Terraform yet)
→ Read [reference/install-new-pc.md](reference/install-new-pc.md) in full before changing anything.

**Working on an already installed lab host** (repository checked out in WSL, preflight exits 0)
→ Read [reference/operate-existing-host.md](reference/operate-existing-host.md) before running any lifecycle command.

**Something failed** (timeout, 404, 409, HTTP 000, host key changed, Ansible become timeout, NIC error)
→ Read [reference/pitfalls.md](reference/pitfalls.md) and match the symptom before retrying.

**Need the background of one layer** → the blog posts linked at the top of the repository README (an English complete guide and the Korean series, parts 0-4). The repository has changed since; when they differ, the scripts and these references win.

## 2. Architecture (both paths)

```
external agent --SSH:22--> Windows (mirrored networking) --> WSL2 Ubuntu sshd
WSL Terraform --HTTP--> Windows vmrest http://127.0.0.1:8697/api --> VMware Workstation
WSL Ansible --SSH--> guest VM (VMnet1 host-only mgmt NIC; VMnet8 NAT for internet)
```

Terraform owns VM existence and power. Ansible owns guest software. They do not call each other (Terraform only runs a `local-exec` bootstrap on the powered-off clone).

## 3. Configuration

All bash scripts source `lib/config.sh`, which reads optional settings from `lab.env` (gitignored; template `lab.env.example`) or the file named in `LAB_ENV_FILE`, and the vmrest account from the secrets file (`%USERPROFILE%\.env`).

- **VM set.** Without `vms.tfvars`, one VM `LAB_CLONE_NAME` (group `demo`). With `vms.tfvars` in the repository root (template `vms.tfvars.example`, gitignored; `LAB_VMS_FILE` to move it): `vms = { "<name>" = { processors, memory_mb, groups, image } }` (`image` optional, default `LAB_IMAGE`; `lan = true` adds a bridged NIC `lan0` with a LAN DHCP address, `lan_ip = "a.b.c.d/nn"` makes it static, no default route or DNS on it; changing these rebuilds the VM). Each VM is `<LAB_VM_ROOT_WIN>\<name>\<name>.vmx` (default root `%USERPROFILE%\Documents\Virtual Machines`), its hostname and its Ansible host; `groups` become Ansible groups and every VM is also in `lab`. `./lab up` creates and bootstraps new entries off; existing VMs retain live power. `up --all` or `up <vm>...` starts the selection. It reads the plan first and refuses to delete or replace any VM unless run as `./lab up --allow-destroy` (which destroys plus cleans entries removed from the list); a missing or mistyped `vms.tfvars` therefore stops instead of deleting VMs. An explicitly set `LAB_VMS_FILE` that does not exist is an error, not the single-VM fallback. There is one base per image in use (`./lab setup` prepares them: `base/<image>/base.vmx`, VM `<image>-base`). Before `up`/`down`, `lib/check-base.py` requires for each exactly one registered VM with that display name at that VMX (the provider takes the first name match); a duplicate stops with no change, and a clone may not use a base name. A rebuilt base (`./lab setup --recreate`, or another vmrest id or path) or a changed `image` makes the plan replace those clones and their bootstrap (`terraform_data.vm_base`), so `up` refuses until `--allow-destroy`; clone contents are lost. Pass `--allow-destroy` only when the user asked to remove or rebuild those VMs.
- **Playbooks.** `./lab configure [PLAYBOOK] [ansible-playbook options]` runs any playbook, also from the user's own project folder (`LAB_PLAYBOOK` sets the default). `ansible/check-lab.yml` checks every VM (SSH, cloud-init, sudo, OS). Keep the user's playbooks and `vms.tfvars` out of this repository's git history unless they ask.
- Guest image: `ubuntu-24.04`, `ubuntu-22.04` or `debian-13` (Debian's checksum list is not signed; say so), per VM with `image` in `vms.tfvars`, default `LAB_IMAGE` in `lab.env`. Guests need cloud-init, an SSH server, sudo and python3, not VMware Tools. Changing a VM's image rebuilds that VM with `./lab up --allow-destroy`: ask first. For an image not in the table, stop and ask the user; do not swap images silently.
- Guest VM user (inside the VM) is fixed: cloud-init creates `lab` (lab key, passwordless sudo) in every clone, and the clone's SSH host key is generated in WSL and pinned before its first boot (`lib/cloud-config.sh`, `lib/bootstrap-guest.sh`). The base is never booted. The WSL user is separate: the account the user SSHes into this PC as (the `User` of their SSH config entry); scripts run as it and never set it.
- Private files live in `~/.config/wsl-vmware-lab/` (`LAB_PRIVATE_DIR`).
- Windows side: one script, `windows\setup.cmd Install|Status|Network|Remove` (runs `setup.ps1` past the default execution policy for that run only; `-AllowedRemoteAddress` defaults to the LAN of the default route) (`-AllowedRemoteAddress <LAN>`, `-Distro`, `-VmrestPath`, `-IncludeBattery`, `-SkipPower`). Its two boot tasks run `wsl.exe` and `vmrest.exe` directly, so nothing depends on the checkout path; re-run Install only to change its parameters. Mirrored networking only.
- vmrest starts at Windows boot before any logon (`VMware vmrest API`: boot trigger, S4U, no time limit, restart 5 x 1 min). A logon-only start is not acceptable.

## 4. Rules that always apply

1. **User decides.** Propose options with trade-offs before changing a host, and run only what the user picks.
2. **Secrets.** Never print, copy or commit `lab.env`, vmrest credentials, SSH private keys, Terraform state or generated `inventory.json`. Never type the vmrest password on the user's behalf: the user runs `./lab account` in their own terminal (it refuses to run without one). Do not enable `set -x` around config loading. New variables get a fake value in `lab.env.example`.
3. **Preserve.** Never delete or re-prepare the base VM, reset WSL distributions, restore VMware network defaults, or overwrite an existing Terraform state unless the user explicitly asks.
4. **Check before lifecycle commands.** `./lab status` (or `lib/preflight.sh`) must exit 0 in this session before any Terraform command (section 0). `lab` runs one command at a time per checkout (`flock` on `.lab.lock`); a second one stops at once.
5. **One runner per state.** One checkout = one state, one VM set, one inventory. Serialize work, or use a fully isolated checkout with its own `lab.env`.
6. **Destroy via the wrapper.** Use `./lab destroy --confirm=<names>` (exact state VM set; runs cleanup), never bare `terraform destroy`. `0 destroyed` with vmrest down is not success.
7. **Never disable host key checking globally.** Clone host keys are generated in WSL and pinned before the first boot (`StrictHostKeyChecking=yes`); a mismatch means the address reached another VM.
8. **Never disable Hyper-V / VBS / Secure Boot** to make VMware start; WSL2 needs them.
9. **Verification.** Report a step as done only with the command and its actual output. Historical results in references are not fresh evidence. A test passes only under the conditions it claims: for example, a credential written and read in the same session proves nothing about a fresh boot.
10. **Hosts that differ from the skill.** When a host was set up another way (a vmrest task with another name or a logon trigger, the account in another file or under `VMWS_USER`, the OVA under an old name), do not work around it silently. Show the difference, propose converting the host to the skill's way, and on the user's OK convert it: disable rather than delete foreign tasks and keep foreign files. Then re-run preflight. If the difference reveals a gap in the skill itself, fix the skill and repository too.
11. **Test hosts.** Run disruptive tests (stopping vmrest, reboots, lifecycle runs) only on a host the user names as free for testing, never on a host in use.

12. **Distributed systems require a documented order.** Before configuring or starting replication, master/worker, membership or quorum services, read the official documentation for the exact installed version and write the configuration, first-start/bootstrap, full-shutdown and restart order, with sources and readiness queries. No record, no configure and no start. Follow [reference/distributed-systems.md](reference/distributed-systems.md), including package auto-start suppression and guards for irreversible initialization. Several PCs need a written order per host, one checkout per PC, services over `lan0`.

## 5. Routine command set (in WSL, from the repository found in section 0)

```bash
cd "$repo"
./lab status                     # must exit 0 first (host checks, vmrest, Terraform state; changes nothing)
./lab setup                      # once: WSL tools, image, cloud-init seed, base VM (skips a prepared base)
./lab up                         # create and bootstrap new/replacement VMs OFF; preserve existing power
./lab up --all                   # start all after preparation
./lab up <vm>...                 # start selection only; separate calls for ordered roles
./lab configure ansible/check-lab.yml   # every VM ready?
./lab configure                  # example: nginx + HTTP assertions on group demo; again: changed=0 failed=0
./lab configure ~/my-system/site.yml    # the user's own playbook
./lab down --all                 # graceful shutdown; success requires vmrest poweredOff
./lab down <vm>...               # graceful shutdown of selection (bare down is an error)
./lab down <vm>... --hard        # hard stop only after asking the user
./lab destroy --confirm=<names>  # exact comma-separated state VM set; cleanup-aware
./lab cleanup                    # retry cleanup left by a failed or interrupted delete
./lab up --dry-run               # plan only; also down/destroy --dry-run
./lab describe --json            # command arguments, envelope and error codes
```

Every command writes one JSON envelope to stdout; logs go to stderr. Inspect `ok`, `error`, `changed` and `data`; an interrupted mutation requires status inspection. Dry runs report pending cleanup/restoration without running them.

Several VMs: `cp vms.tfvars.example vms.tfvars`, edit, then `./lab up`. Changing the list later: edit and run `up` again (removing entries: `./lab up --allow-destroy`, after the user confirms).

Inventory and groups contain only powered-on VMs; project variables must define cluster topology. `configure --limit db` uses the default playbook and passes the limit unchanged; readiness is required for all powered-on VMs, with that set frozen across retries. If an apply fails after a partial start, run `./lab status` and ask the user before further changes. Graceful down waits up to `LAB_DOWN_WAIT_SECONDS` (120 by default), polling every 5 seconds. It ignores SSH poweroff return codes and trusts only vmrest; ask before `--hard`.

`ANSIBLE_TIMEOUT=60` gives slow privilege escalation a one-minute budget, avoiding the known 12-second prompt timeout.

## 6. Acceptance checklist (copy and tick)

```
- [ ] ./lab status exit 0 (vmrest 401 unauthenticated, 200 authenticated)
- [ ] every VM in the list appears in API inventory and is poweredOn (`./lab status`)
- [ ] Ansible run 1: HTTP 200 + expected content, failed=0
- [ ] Ansible run 2: changed=0 unreachable=0 failed=0
- [ ] power-off confirmed by API, not only Terraform exit code
- [ ] destroy removed clone from API/state + VMX, VMDK, seed ISO, clone dir
- [ ] base VM and unrelated VMs unchanged; shared inventory restored
- [ ] ./lab status still exits 0 afterwards
- [ ] (new or changed host) after a reboot with nobody logged on (`quser`: no users), ./lab status exits 0
```

Verified end to end on the lab laptop (2026-11-09, `./lab` and `windows/setup.ps1`): setup → up → configure ×2 (`changed=0` the second time) → down → destroy with cleanup; base rebuild → clones replaced with `--allow-destroy`; reboot with nobody logged on → SSH and vmrest up from the boot tasks. Not verified: a PC without VMware yet, Windows firewall profiles enabled.

## 7. Report format

Summary of changes / files changed / verification (commands run and their output) / remaining risks.

## Official references

WSL install/networking/config: learn.microsoft.com/en-us/windows/wsl/ · Workstation API: developer.broadcom.com/xapis/vmware-workstation-pro-api/latest/ · Provider: github.com/elsudano/terraform-provider-vmworkstation · Terraform install: developer.hashicorp.com/terraform/install · Ansible: docs.ansible.com · Ubuntu cloud images: cloud-images.ubuntu.com/noble/current/
