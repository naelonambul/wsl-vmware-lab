# wsl-vmware-lab

**English** · [한국어](README.ko.md)

A lab base for **building, testing, and deploying systems with Terraform + Ansible** on a single Windows PC. Terraform in WSL2 Ubuntu creates one or more VMs in **VMware Workstation** through the `elsudano/vmworkstation` provider and the `vmrest` REST API, and Ansible runs **your playbooks** against those VMs over SSH. The default single Ubuntu VM + nginx setup (`ubuntu24-demo` and `ansible/configure-guest.yml`) is only an example and smoke test.

```
other PC --SSH:22--> Windows (mirrored) --> WSL2 Ubuntu sshd
WSL Terraform --> vmrest http://127.0.0.1:8697/api --> VMware Workstation --> lab VMs
WSL Ansible --SSH--> lab VMs (VMnet1 host-only mgmt; VMnet8 NAT)
```

Background posts (the repository has evolved since publication; where they differ, **the current scripts and this README win**):
- English complete guide: [Complete Guide](https://naelonambul.tistory.com/212)
- Korean series: [Part 0 — WSL](https://naelonambul.tistory.com/210) · [Part 1 — VMware + vmrest account](https://naelonambul.tistory.com/211) · [Part 2 — SSH + boot tasks (`setup.ps1`)](https://naelonambul.tistory.com/207) · [Part 3 — Base VM (`./lab setup`)](https://naelonambul.tistory.com/208) · [Part 4 — Terraform/Ansible (`./lab`)](https://naelonambul.tistory.com/209)

## Requirements

- **Windows 11** with **WSL2 Ubuntu 24.04** (`Ubuntu-24.04`) and **mirrored networking** (`networkingMode=mirrored` under `[wsl2]` in `%USERPROFILE%\.wslconfig`).
- **VMware Workstation Pro installed manually.** The official installer requires a Broadcom account and is not automated. Its API account (separate from Windows and Ubuntu logins) is created in step 2 with `./lab account`.
- **Guest image (`LAB_IMAGE`):** an official cloud image that `./lab setup` downloads and checks. Guests need cloud-init, an SSH server, sudo and python3, not VMware Tools: the guest user (`lab`) and each clone's SSH host key are set by cloud-init from WSL before the first boot.

  | `LAB_IMAGE` | Image | Check |
  |---|---|---|
  | `ubuntu-24.04` (default) | `noble-server-cloudimg-amd64.ova` | `SHA256SUMS` signed by Ubuntu (gpgv) |
  | `ubuntu-22.04` | `jammy-server-cloudimg-amd64.ova` | same |
  | `debian-13` | `debian-13-generic-amd64.qcow2` | `SHA512SUMS` over HTTPS only (Debian does not sign cloud images) |

  `LAB_IMAGE` is the default; each VM in `vms.tfvars` may name its own `image`, so one system can mix them (for example web on Ubuntu, db on Debian). `./lab setup` prepares one base per image in use (`base/<image>/`, VM `<image>-base`). Changing a VM's image rebuilds that VM (`./lab up --allow-destroy`). The example nginx playbook uses apt.
- **Repository on a Windows drive** (for example `C:\wsl-vmware-lab`, `/mnt/c/wsl-vmware-lab` in WSL). The base VM files (`base/<image>/base.vmx` and `base.vmdk`) are built inside the repository, so VMware Workstation must be able to open them from a Windows path.

## Installation

1. **Clone the repository on a Windows drive (in WSL):**
   ```bash
   cd /mnt/c && git clone https://github.com/naelonambul/wsl-vmware-lab.git && cd wsl-vmware-lab
   ```

2. **Create the `vmrest` API account (in WSL, interactive terminal):**
   ```bash
   ./lab account          # runs vmrest.exe -C, writes %USERPROFILE%\.env, locks ACLs
   ./lab account --lock   # only re-locks %USERPROFILE%\.env permissions
   ```
   - Runs official `vmrest.exe -C` (backing up an existing `%USERPROFILE%\vmrest.cfg` first) so you can choose the API username and password.
   - Reads `username=` from `vmrest.cfg`, prompts for the same password once more, and writes `VMWS_USERNAME` and `VMWS_PASSWORD` to `%USERPROFILE%\.env` (`LAB_SECRETS_FILE`) while preserving any other lines in that file.
   - Locks `%USERPROFILE%\.env` NTFS permissions (inheritance disabled) so only your Windows account, `SYSTEM`, and `Administrators` can read it.
   - If the `VMware vmrest API` scheduled task already exists, restarts `vmrest` and checks that an authenticated `GET /vms` returns HTTP `200`. On a first install before step 3, `./lab status` performs that check in step 4.
   - Must be run in an interactive terminal by a person. AI agents never ask for, read, or type the password.

3. **Configure Windows boot tasks, firewall, power and the VMware bridge (elevated PowerShell in `windows\`):**
   ```powershell
   .\setup.cmd Install                                         # LAN detected from the default route
   .\setup.cmd Status                                          # read-only check (no elevation needed)
   .\setup.cmd Remove                                          # removes tasks and firewall rules (keeps power settings)
   ```
   `setup.cmd` runs `setup.ps1` with the same arguments, bypassing PowerShell's execution policy for that run only (Windows blocks `.ps1` scripts by default); the system setting is left alone. Options for `windows\setup.ps1`:
   - `-Action`: `Install`, `Status` (default), `Network` (read-only), or `Remove`
   - `-AllowedRemoteAddress <subnet>`: source range allowed on TCP 22. Default: the LAN of the adapter that carries the default route, i.e. the network other PCs reach this one on (WSL shares it in mirrored mode), for example `192.168.1.0/24`; `Status` shows it
   - `-Distro <name>`: WSL distribution name (default `Ubuntu-24.04`)
   - `-VmrestPath <path>`: path to `vmrest.exe` (default `$env:ProgramFiles\VMware\VMware Workstation\vmrest.exe`)
   - `-IncludeBattery`: also disable sleep, hibernation, and lid-close action on battery power
   - `-SkipPower`: leave Windows power settings unchanged

   What `Install` does:
   - Verifies WSL mirrored networking in `%USERPROFILE%\.wslconfig`, checks that `vmrest.exe` exists, and ensures Windows OpenSSH Server is not holding port 22.
   - Registers two scheduled tasks that run at boot (`AtStartup`, S4U logon without requiring a Windows sign-in, `RestartCount 5` every 1 minute, no execution time limit):
     - `WSL2 SSH Service Start` (at boot and at logon): runs `wsl.exe -d <Distro> -u root` to stop `ssh.socket`/`ssh.service` and run `/usr/sbin/sshd -D -e` in the foreground, keeping WSL running.
     - `VMware vmrest API` (at boot): runs `vmrest.exe` listening on `127.0.0.1:8697`.
     - Both tasks execute system binaries (`wsl.exe` and `vmrest.exe`) directly, so moving the repository does not break them.
   - Allows inbound TCP 22 from `-AllowedRemoteAddress` in Windows Firewall (`WSL2 SSH 22`) and Hyper-V Firewall for WSL (`WSL-SSH-Inbound-TCP22-LAN`).
   - Sets AC power (`-IncludeBattery` for DC as well) to never sleep, never hibernate, and do nothing when closing the lid, unless `-SkipPower` is passed.
   - Keeps the VMware Bridge Protocol only on physical adapters (Ethernet, Wi-Fi). WSL's mirrored mode adds a Hyper-V `vEthernet` adapter that VMware's VMnet0 "Automatic" bridge could otherwise pick, leaving `lan = true` VMs off the LAN.
   - Removes legacy tasks and old files under `%ProgramFiles%\wsl-vmware-lab`, starts both tasks, and waits until port `22` in WSL and `127.0.0.1:8697` on Windows are actively listening before reporting ready.

4. **Prepare the base VM and check the host (in WSL):**
   ```bash
   ./lab network   # inspect VMware roles and bridge evidence before setup
   bash lib/preflight.sh # host-only prerequisite check; works before Terraform is installed
   ./lab setup     # once: installs missing WSL tools via sudo, verifies Ubuntu image, builds base VM
   ./lab status    # read-only check of environment, vmrest, Windows tasks/power, and VMs
   ```
   - If `terraform`, `ansible-playbook`, `qemu-img`, `cloud-localds`, `gpgv` or the `ubuntu-cloudimage-keyring` is missing, `./lab setup` first runs `sudo bash lib/wsl-tools.sh` (asks for your WSL password). It then downloads the `LAB_IMAGE` cloud image and verifies it (see the table above), converts the image to `base/<image>/base.vmdk`, creates `~/.config/wsl-vmware-lab/lab_ed25519`, writes and registers `base/<image>/base.vmx` (`<image>-base`), and writes `base/<image>/base.prepared`. The base is never booted, so every clone's first boot is the image's first boot.
   - No public `./lab` host-only subcommand exists. Before initial setup, require `bash lib/preflight.sh` exit 0 in WSL: it warns about missing tools without invoking Terraform and checks host/vmrest prerequisites. It prints text, not JSON. Then run setup and full status as above.
   - Status is diagnostic: exit 0 / `ok: true` does not establish every VM’s health. Read `data.vms` (power and LAN evidence) and `warnings`; `vm_power_unknown` and `lan_vnet_mismatch` identify affected VMs.
   - `./lab status` checks the host configuration, `vmrest` loopback listener and credentials, Windows scheduled tasks and power settings, and the power state of any lab VMs. It initializes Terraform/providers automatically without marking `changed`.

### Installing with an AI Agent

To have Claude Code or OpenAI Codex set up or inspect the repository, tell the agent:

> Read https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md and install it.

Following [`INSTALL.md`](INSTALL.md), the agent finds or clones the repository on a Windows drive, installs the `vmware-wsl-lab` skill from `.claude/skills/vmware-wsl-lab` (or the identical Codex copy in `.agents/skills/vmware-wsl-lab`), and runs `./lab status`. The agent never asks for, reads, prints, or types the `vmrest` password.

## `./lab` Command Reference

```bash
./lab account [--lock]         # vmrest API account + secrets file (once; --lock: permissions only)
./lab setup [--recreate]       # WSL tools, Ubuntu image, cloud-init seed, base VM (once)
./lab status [--start-vmrest]   # checks; optional vmrest startup
./lab up [--all | <vm>...] [--allow-destroy] [--dry-run]  # prepare off; start selection only
./lab down (--all | <vm>...) [--hard] [--dry-run]  # graceful shutdown; explicit hard stop
./lab configure [PLAYBOOK] [ansible-playbook options]
./lab destroy --confirm=<names> [--dry-run]  # exact comma-separated state VM set
./lab cleanup                  # retry cleanup left by an interrupted delete
./lab network                  # read-only Windows/VMX network evidence; no vmrest
./lab describe --json          # command arguments, envelope and error reference
```

Every command writes one JSON envelope to **stdout**; human logs and Terraform/Ansible diagnostics go to **stderr**. `./lab describe --json` returns its reference inside `data`.

```json
{"ok":true,"command":"up","dry_run":true,"changed":false,"data":{},"warnings":[],"error":null}
```

This illustrates the envelope shape; `data` varies by command. `ok` is true exactly when `error` is null. Errors contain `code`, `message`, `hint` and `details`; warnings contain `code`, `message` and `vm`. `changed` means a mutation was attempted, possibly partly completed; it does not prove success. Keep stderr for diagnosis; it is not a secret-redacted archive.

`./lab up --dry-run`, `./lab down --all --dry-run` and `./lab destroy --dry-run` preview plans and guards without apply, guest SSH, cleanup, journal writes or state restoration. They initialize Terraform/providers and use private scratch files without marking `changed`; credentials and reachable vmrest are required; up/down also require prepared bases. Pending cleanup/restoration is reported. Dry-run destroy needs no confirmation; if supplied it must match. Actual destroy requires the exact, distinct comma-separated names in state (any order), with no interactive prompt or Terraform argument passthrough. An empty state without confirmation succeeds as a no-op.

| Error code | Exit | Next action |
|---|---|---|
| `usage_error` | 2 | Fix the call from the message. |
| `config_error` | 2 | Fix lab.env / vms.tfvars; ask the user if unclear. |
| `unknown_vm` | 2 | Use one of the listed names. |
| `secrets_missing` | 3 | Find an existing file by variable names only; else the user runs ./lab account. |
| `vmrest_auth` | 3 | The user corrects credentials or runs ./lab account. |
| `needs_user` | 3 | Hand the user the command requiring their terminal, sudo or elevated PowerShell. |
| `lock_held` | 4 | Wait and retry; never delete the lock. |
| `vmrest_unreachable` | 4 | Precheck only: ask the user to start vmrest and retry. |
| `plan_destroy_refused` | 5 | Review the VM list; ask the user before --allow-destroy / --confirm. |
| `config_change_requires_off` | 5 | Revert configuration edits, down the VM, then restore edits and up. |
| `lan_vnet_mismatch` | 5 | Show desired and actual wiring; ask the user about offline VMX repair. |
| `vm_power_unknown` | 5 | Run ./lab status; report; no automatic repair. |
| `guest_not_ready` | 1 | Read the per-VM reason and reference/pitfalls.md; no automatic retry. |
| `runtime_error` | 1 (SIGINT: 130; SIGTERM: 143) | Read stderr and ./lab status; ask the user about partly changed distributed systems. |

Success exits 0; an unclassified failure becomes `runtime_error`. Interrupted runs also emit `runtime_error`, preserving exit 130 for SIGINT or 143 for SIGTERM.

Setup, up, down, destroy, cleanup and configure take the checkout lock (`flock` on `.lab.lock`); a competing locked command exits with `lock_held`. Status, network, describe and account do not take that lock.

In-place VM configuration edits beyond power require the VM to be off (all attributes, not just CPU/memory). Revert edits before `./lab down <vm>`, restore them, then run `./lab up <vm>`; edits are applied off before a separate power-on plan. Pure power changes remain allowed.

### Building Your Own System

```bash
cp vms.tfvars.example vms.tfvars           # define VM names, CPUs, memory_mb, and Ansible groups (gitignored)
./lab network                    # inspect actual VMware network roles first
./lab up                         # create and bootstrap, leave off
./lab up --all                   # or ./lab up web1, then db1 in your required order
./lab configure ansible/check-lab.yml      # verify SSH, cloud-init, passwordless sudo, and OS facts on powered-on VMs
./lab configure ~/my-system/site.yml       # run your own playbook (can live outside this repository)
```

- Each key in `vms = { ... }` in `vms.tfvars` is the VM name (`^[a-z0-9][a-z0-9-]{0,62}$`, lowercase letters, digits, and `-`, and not a base name `<image>-base`). It becomes the Windows folder and VMX path (`<LAB_VM_ROOT_WIN>\<name>\<name>.vmx`), the guest hostname, and the Ansible host name.
- Omitted fields default to `processors = 2`, `memory_mb = 2048`, and `groups = ["demo"]`.
- Group names in `groups` must match `^[a-z_][a-z0-9_]*$`. Every VM is placed in its listed `groups` and is always added to the `lab` group (`ansible/check-lab.yml` runs on `lab`; the default `ansible/configure-guest.yml` runs on `demo`).
- **LAN NIC (optional):** `lan = true` adds a LAN NIC (bridged VMnet0 by default; custom VMnet via `LAB_LAN_VNET`), named `lan0` in the guest, that gets an address from your LAN router's DHCP (using a discovered LAN address). `lan_ip = "192.0.2.240/24"` is a documentation-only static example (replace the subnet and pick an address outside the router's DHCP range); `./lab up` refuses an address that is not on this PC's LAN (detected from the default route, shown by `./lab status`) or that already answers. `lan0` adds no default route or DNS; internet traffic stays on NAT. Playbooks read it as `ansible_lan0.ipv4.address` (`check-lab.yml` reports it). VMs on several PCs on the same LAN can reach each other this way. Changing `lan`/`lan_ip` rebuilds that VM (`./lab up --allow-destroy`). On a PC with Hyper-V adapters, check that VMware's VMnet0 bridges to the physical adapter (Virtual Network Editor).
- Adding an entry to `vms.tfvars` and running `./lab up` creates and bootstraps only the new VM (created powered off and left off) while existing VMs retain their live power. Start selected VMs with `./lab up <vm>...`, or all with `./lab up --all`. Multiple names are applied together without a start-order guarantee; use separate calls for ordered roles.

## Safety Guarantees

- **Refuses unintended VM deletion:** `./lab up` inspects `terraform plan -json` before applying. If any VM would be deleted or replaced, it prints the VM names and exits unless `--allow-destroy` is passed. A missing or mistyped `vms.tfvars` will not delete existing VMs. `./lab down --all` or `./lab down <vm>...` targets existing VMs and refuses destructive plans and all non-power VM updates before touching guests. Graceful shutdown succeeds only when vmrest confirms every selected VM is off; an unreachable guest is left running. The default wait is 120 seconds (`LAB_DOWN_WAIT_SECONDS`): the plan budgets 90 seconds for service stops plus 30 seconds for power-off. `--hard` explicitly permits a hard power-off. Bare `down` is an error.
- **Base VM verification:** Before `up` or `down`, `lib/check-base.py` confirms for each image in use that exactly one registered VM in `vmrest` has `displayName` `<image>-base` and points to `base/<image>/base.vmx`. It passes each base's VM ID and the SHA-256 hash of its `base.prepared` to Terraform, which records them per clone (`terraform_data.vm_base`). Rebuilding a base (`./lab setup --recreate`) or changing a VM's image marks those clones for replacement, and `./lab up` stops until you confirm with `./lab up --allow-destroy` (replacing clones erases their disks).
- **Current DHCP lease + host key pinned before boot:** for each new clone, `lib/bootstrap-guest.sh` generates an `ssh-ed25519` host key in WSL, puts it in the clone's cloud-init seed (`ssh_keys`, old keys deleted) and writes `known_hosts-<id>` before the clone first boots. `lib/guest-inventory.py` matches each VM's management NIC MAC (`ethernet1.generatedAddress`) against only active, non-expired leases on `LAB_MGMT_VNET` in `vmnetdhcp.leases` (using the last entry per IP), and counts a VM as ready only when SSH as `lab` succeeds against that pin (`StrictHostKeyChecking=yes`, `HostKeyAlias`). Ansible will never connect to a different VM that reused an IP. The seed ISO next to the clone's disk holds the same private key the disk holds once booted.
- **Replayable cleanup journal:** Before Terraform deletes or replaces VMs, `lib/cleanup-guest.py` records them in `terraform/cleanup-pending.json`. After a VM leaves the state (and its `.vmx` and `.vmdk` are gone), cleanup removes `cloud-init-<id>.iso`, leftover `.vmxf`, `known_hosts-<id>`, `seed-<id>/`, and the empty clone directory. Entries remain in the journal until cleanup succeeds and are retried automatically by the next `up`, `destroy`, or `./lab cleanup`.
- **`vmrest` on loopback with authentication:** `./lab status` requires `VMWS_ENDPOINT` to target loopback (`127.0.0.1`, `localhost`, or `[::1]`), checks that Windows port `8697` listens on loopback only, verifies that unauthenticated `GET /vms` returns HTTP `401`, and confirms that authenticated `GET /vms` returns HTTP `200`.

## Configuration: `lab.env` (Optional)

Copy `lab.env.example` to `lab.env` only when overriding defaults (`cp lab.env.example lab.env`; never store passwords in `lab.env`).

| Variable | Default | Purpose |
|---|---|---|
| `LAB_ENV_FILE` | `<repo>/lab.env` | Path to the optional settings file (set it in the environment, not inside `lab.env`) |
| `LAB_SECRETS_FILE` | `%USERPROFILE%\.env` | Secrets file holding `VMWS_USERNAME` (or `VMWS_USER`) and `VMWS_PASSWORD` |
| `VMWS_ENDPOINT` | `http://127.0.0.1:8697/api` | Loopback `vmrest` API URL |
| `LAB_PRIVATE_DIR` | `$HOME/.config/wsl-vmware-lab` | WSL directory for SSH keys, `inventory.json`, `known_hosts-<id>`, and `seed-<id>/` |
| `LAB_SSH_KEY` | `$LAB_PRIVATE_DIR/lab_ed25519` | Ed25519 SSH private key injected into guests |
| `LAB_INVENTORY` | `$LAB_PRIVATE_DIR/inventory.json` | Generated Ansible inventory file |
| `VMWARE_DIR` | `/mnt/c/Program Files/VMware/VMware Workstation` | VMware Workstation directory (`vmrun.exe`, `vmrest.exe`) |
| `LAB_DHCP_LEASES` | `/mnt/c/ProgramData/VMware/vmnetdhcp.leases` | VMware DHCP leases file |
| `LAB_DHCP_CONF` | `/mnt/c/ProgramData/VMware/vmnetdhcp.conf` | VMware DHCP configuration file |
| `LAB_NAT_VNET` | `VMnet8` | NAT virtual network (`ethernet0`) |
| `LAB_MGMT_VNET` | `VMnet1` | Host-only management virtual network (`ethernet1`) |
| `LAB_LAN_VNET` | empty (effective `VMnet0`) | LAN NIC: empty/VMnet0 = bridged; VMnet1–19 = custom; must differ from NAT and management |
| `LAB_BASE_DIR` | `<repo>/base` | Directory holding one `<image>/` folder per base (`base.vmx`, `base.vmdk`, `base.prepared`) |
| `LAB_IMAGE` | `ubuntu-24.04` | Guest image of VMs without `image` in `vms.tfvars`: `ubuntu-24.04`, `ubuntu-22.04` or `debian-13` |
| `LAB_UBUNTU_IMAGE_URL` | `https://cloud-images.ubuntu.com/<noble or jammy>/current` | Download directory (mirror) for the chosen Ubuntu image and its `SHA256SUMS` |
| `LAB_VM_ROOT_WIN` | `%USERPROFILE%\Documents\Virtual Machines` | Windows directory for clones (`<root>\<name>\<name>.vmx`); must match Workstation's default VM location |
| `LAB_VMS_FILE` | `<repo>/vms.tfvars` | Multi-VM definition file; if absent (and not set explicitly), falls back to the single demo VM below |
| `LAB_CLONE_NAME` | `ubuntu24-demo` | Single fallback VM name when `vms.tfvars` is absent |
| `LAB_CLONE_CPUS` | `2` | vCPUs for the single fallback VM |
| `LAB_CLONE_MEMORY_MB` | `2048` | Memory (MB) for the single fallback VM |
| `LAB_PLAYBOOK` | `<repo>/ansible/configure-guest.yml` | Default playbook run by `./lab configure` when none is specified |
| `LAB_GUEST_WAIT_SECONDS` | `300` | Readiness deadline for the frozen powered-on VM set in configure |
| `LAB_DOWN_WAIT_SECONDS` | `120` | Graceful shutdown power confirmation deadline; polls every 5 seconds |

## Network and running inventory

Before setup or any up, run `./lab network` and read [the network reference](.claude/skills/vmware-wsl-lab/reference/network.md). VMnet numbers do not prove roles. Inspect NAT, management and LAN wiring, DHCP/NAT/forwards, physical adapters and bridge bindings; bindings do not identify Automatic's selected adapter. If unresolved, ask before enabling LAN. Network works before setup without credentials or vmrest; existing state requires Terraform to read it.

Changing `LAB_LAN_VNET` does not rebuild clones. Every up variant refuses existing LAN wiring mismatches; use the documented offline VMX procedure, preserving the LAN MAC, after the user chooses repair. Changing `LAB_NAT_VNET` requires base recreation and rebuilt clones; review data loss first.

Configure inventories/groups contain only powered-on VMs. The first powered-on set stays fixed across readiness retries; powered-off VMs are omitted, unknown/API-error power is fatal, and zero running hosts fails. `configure --limit db` uses the default playbook and passes the limit unchanged, but readiness still covers every powered-on VM. Project variables must carry durable cluster topology.

Before configuring or starting replication, master/worker, membership or quorum services, write the version-specific, officially sourced bootstrap, shutdown and restart order with readiness queries. Follow [the distributed-systems reference](.claude/skills/vmware-wsl-lab/reference/distributed-systems.md): suppress package auto-start where required, guard irreversible initialization, use one `./lab up <vm>` or `./lab down <vm>` per ordered step. After a partial apply, inspect status and ask before recovery.

## Existing checkouts

No state migration is required for this upgrade: resource addresses and replacement triggers are unchanged; power variables are not stored in state. `vms.tfvars` and `lab.env` keep their formats. Plain up now prepares only; use `./lab up --all` to start all. Down requires `--all` or names; destroy requires `--confirm=<names>`. Review `./lab up --dry-run` before the first apply. To roll back, check out the pre-power-change revision `b97feef`; its old up behavior starts every VM.

## Developer verification

Offline tests run on **Linux only** (WSL Ubuntu or CI `ubuntu-latest`), never Windows Git Bash/MSYS. See [tests/README.md](tests/README.md) for bounded commands, fixture isolation and fork-loop prevention.

Current CLI real-host verification remains manual: compare network evidence with the Virtual Network Editor (view only); check mixed live power, create-only up, selected starts and replacements, graceful down, JSON results, interruption recovery and upgrade without replacement. For several PCs use isolated state/private directories and VM names per host, document version-specific service order, verify membership and a fresh write/read after shutdown/restart. Verify reboot behavior only with approval. Keep host-specific evidence private and report checks actually run. The last real-host run (2026-11-14, three Windows PCs on one LAN) covered the items listed under Verification scope in Notes; interruption recovery and VM replacement were checked by offline tests only.

## Repository Layout

| Path | Contents |
|---|---|
| `lab` | Single CLI entry point in WSL |
| `lib/` | Internal scripts called by `lab` (`config.sh`, `account.sh`, `wsl-tools.sh`, `base.sh`, `cloud-config.sh`, `register-vm.py`, `check-base.py`, `preflight.sh`, `network.sh`, `describe.json`, `envelope.py`, `power-map.py`, `lifecycle.sh`, `bootstrap-guest.sh`, `cleanup-guest.py`, `configure.sh`, `guest-inventory.py`, `guest-proxy.sh`, `config-functions.sh`, `runner-functions.sh`, `preflight-functions.sh`, `network-inspect.py`, `plan-inspect.py`, `bootstrap-records.py`, `diagnose.sh`) |
| `windows/` | `setup.ps1` (PowerShell setup/status/network/remove) and `tcp-relay.ps1` (stdio TCP relay used when direct WSL-to-guest SSH needs a Windows hop) |
| `terraform/` | Terraform configuration pinning `elsudano/vmworkstation` `2.0.1` (`main.tf`, `variables.tf`) |
| `ansible/` | Default nginx smoke-test playbook (`configure-guest.yml`) and running-VM readiness check (`check-lab.yml`) |
| `lab.env.example`, `vms.tfvars.example` | Templates for `lab.env` and `vms.tfvars` |
| `INSTALL.md` | Agent installation instructions for Claude Code and Codex |
| `.claude/skills/vmware-wsl-lab/` | Canonical `vmware-wsl-lab` agent skill (`SKILL.md`, `reference/`). `.agents/skills/vmware-wsl-lab/` is the Codex copy synced by `tools/sync-agent-skills.sh` |

## Notes

- **Verification scope:** The current CLI was verified on three Windows PCs on one LAN on 2026-11-14 (two wired and one bridged over Wi-Fi; one using a non-`VMnet0` physical bridge via `LAB_LAN_VNET=VMnet2`): read-only `./lab network` on all three PCs and `up` passing the LAN gate with `LAB_LAN_VNET=VMnet2` on the non-`VMnet0` PC (refusal on a mismatch was covered by offline tests only), create-only `up`, per-VM `up` matching its `--dry-run`, and ordered per-VM `down` after a dry-run, a 3-node MariaDB Galera cluster across the three PCs including orderly shutdown and full restart, host reboots (`vmrest` auto-started, VMs stayed off until started), `destroy --confirm` refusal/dry-run/execution, and upgrade from the previous release (`b97feef`) with mixed live power preserved. A fresh PC without VMware Workstation installed, enabled Windows Firewall profiles, and Wi-Fi bridging on other routers/adapters in general remain unverified.
- **Files never to commit:** `lab.env`, `*.env`, `vmrest.env`, `*.tfvars` (`vms.tfvars`), SSH keys (`*_ed25519*`), `inventory.json`, `known_hosts*`, `*.tfstate*`, `cleanup-pending.json`, and VM disks/images/ISOs (`base/`, `cloud-init/`, `*.ova`, `*.vmdk`, `*.vmx`, `*.iso`) are gitignored and must stay out of version control.
- **Community Terraform provider:** `elsudano/vmworkstation` (`2.0.1`) is an unofficial provider. It looks up the base VM by `displayName` and takes the first match, and it does not replace clones on its own when the base VM is rebuilt; this repository enforces both checks (`lib/check-base.py` and `terraform_data.vm_base`). Review its schema before upgrading the provider version.
- **Troubleshooting:** See [`.claude/skills/vmware-wsl-lab/reference/pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md) for known symptoms and fixes.

## License

[MIT](LICENSE)
