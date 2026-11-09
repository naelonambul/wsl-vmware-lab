# wsl-vmware-lab

**English** · [한국어](README.ko.md)

A lab base for **building, testing, and deploying systems with Terraform + Ansible** on a single Windows PC. Terraform in WSL2 Ubuntu creates one or more VMs in **VMware Workstation** through the `elsudano/vmworkstation` provider and the `vmrest` REST API, and Ansible runs **your playbooks** against those VMs over SSH. The default single Ubuntu VM + nginx setup (`ubuntu24-demo` and `ansible/configure-guest.yml`) is only an example and smoke test.

```
other PC --SSH:22--> Windows (mirrored) --> WSL2 Ubuntu sshd
WSL Terraform --> vmrest http://127.0.0.1:8697/api --> VMware Workstation --> lab VMs
WSL Ansible --SSH--> lab VMs (VMnet1 host-only mgmt; VMnet8 NAT)
```

Background posts (the repository has evolved since publication; where they differ, **this README wins**):
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
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force   # this window only; Windows blocks scripts by default
   .\setup.ps1 Install -AllowedRemoteAddress 192.168.1.0/24   # replace with your LAN subnet
   .\setup.ps1 Status                                          # read-only check (no elevation needed)
   .\setup.ps1 Remove                                          # removes tasks and firewall rules (keeps power settings)
   ```
   Options for `windows\setup.ps1`:
   - `-Action`: `Install`, `Status` (default), or `Remove`
   - `-AllowedRemoteAddress <subnet>`: required for `Install`; source range allowed on TCP 22 (for example `192.168.1.0/24`)
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
   ./lab setup     # once: installs missing WSL tools via sudo, verifies Ubuntu image, builds base VM
   ./lab status    # read-only check of environment, vmrest, Windows tasks/power, and VMs
   ```
   - If `terraform`, `ansible-playbook`, `qemu-img`, `cloud-localds`, `gpgv` or the `ubuntu-cloudimage-keyring` is missing, `./lab setup` first runs `sudo bash lib/wsl-tools.sh` (asks for your WSL password). It then downloads the `LAB_IMAGE` cloud image and verifies it (see the table above), converts the image to `base/ubuntu-base.vmdk`, creates `~/.config/wsl-vmware-lab/lab_ed25519`, writes and registers `base/ubuntu-base.vmx` (`ubuntu24-base`), and writes `base/ubuntu-base.prepared`. The base is never booted, so every clone's first boot is the image's first boot.
   - `./lab status` checks the host configuration, `vmrest` loopback listener and credentials, Windows scheduled tasks and power settings, and the power state of any lab VMs without modifying anything.

### Installing with an AI Agent

To have Claude Code or OpenAI Codex set up or inspect the repository, tell the agent:

> Read https://github.com/naelonambul/wsl-vmware-lab/blob/main/INSTALL.md and install it.

Following [`INSTALL.md`](INSTALL.md), the agent finds or clones the repository on a Windows drive, installs the `vmware-wsl-lab` skill from `.claude/skills/vmware-wsl-lab` (or the identical Codex copy in `.agents/skills/vmware-wsl-lab`), and runs `./lab status`. The agent never asks for, reads, prints, or types the `vmrest` password.

## `./lab` Command Reference

```bash
./lab account [--lock]         # vmrest API account + secrets file (once; --lock: permissions only)
./lab setup [--recreate]       # WSL tools, Ubuntu image, cloud-init seed, base VM (once)
./lab status [--start-vmrest | --plan [on|off]]   # checks; --plan: what up/down would change
./lab up [--allow-destroy]     # create new VMs from vms.tfvars and power all on
./lab down                     # power the existing VMs off
./lab configure [PLAYBOOK] [ansible-playbook options]
./lab destroy [-auto-approve]  # delete every VM of this checkout
./lab cleanup                  # retry cleanup left by an interrupted delete
```

Only one `lab` command runs at a time per checkout (`flock` on `.lab.lock`); a second concurrent command exits immediately.

### Building Your Own System

```bash
cp vms.tfvars.example vms.tfvars           # define VM names, CPUs, memory_mb, and Ansible groups (gitignored)
./lab up
./lab configure ansible/check-lab.yml      # verify SSH, cloud-init, passwordless sudo, and OS facts on all VMs
./lab configure ~/my-system/site.yml       # run your own playbook (can live outside this repository)
```

- Each key in `vms = { ... }` in `vms.tfvars` is the VM name (`^[a-z0-9][a-z0-9-]{0,62}$`, lowercase letters, digits, and `-`, and not a base name `<image>-base`). It becomes the Windows folder and VMX path (`<LAB_VM_ROOT_WIN>\<name>\<name>.vmx`), the guest hostname, and the Ansible host name.
- Omitted fields default to `processors = 2`, `memory_mb = 2048`, and `groups = ["demo"]`.
- Group names in `groups` must match `^[a-z_][a-z0-9_]*$`. Every VM is placed in its listed `groups` and is always added to the `lab` group (`ansible/check-lab.yml` runs on `lab`; the default `ansible/configure-guest.yml` runs on `demo`).
- **LAN NIC (optional):** `lan = true` adds a bridged NIC (VMnet0), named `lan0` in the guest, that gets an address from your LAN router's DHCP (for example 192.168.1.x). `lan_ip = "192.168.1.240/24"` makes it static instead (pick an address outside the router's DHCP range). `lan0` adds no default route or DNS; internet traffic stays on NAT. Playbooks read it as `ansible_lan0.ipv4.address` (`check-lab.yml` reports it). VMs on several PCs on the same LAN can reach each other this way. Changing `lan`/`lan_ip` rebuilds that VM (`./lab up --allow-destroy`). On a PC with Hyper-V adapters, check that VMware's VMnet0 bridges to the physical adapter (Virtual Network Editor).
- Adding an entry to `vms.tfvars` and running `./lab up` creates and bootstraps only the new VM (created powered off, bootstrapped, then powered on) while already-running VMs stay on.

## Safety Guarantees

- **Refuses unintended VM deletion:** `./lab up` inspects `terraform plan -json` before applying. If any VM would be deleted or replaced, it prints the VM names and exits unless `--allow-destroy` is passed. A missing or mistyped `vms.tfvars` will not delete existing VMs. `./lab down` targets only VMs already in the state and refuses any plan that does more than change power state.
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
| `LAB_BASE_DIR` | `<repo>/base` | Directory holding one `<image>/` folder per base (`base.vmx`, `base.vmdk`, `base.prepared`) |
| `LAB_IMAGE` | `ubuntu-24.04` | Guest image of VMs without `image` in `vms.tfvars`: `ubuntu-24.04`, `ubuntu-22.04` or `debian-13` |
| `LAB_UBUNTU_IMAGE_URL` | `https://cloud-images.ubuntu.com/<noble or jammy>/current` | Download directory (mirror) for the chosen Ubuntu image and its `SHA256SUMS` |
| `LAB_VM_ROOT_WIN` | `%USERPROFILE%\Documents\Virtual Machines` | Windows directory for clones (`<root>\<name>\<name>.vmx`); must match Workstation's default VM location |
| `LAB_VMS_FILE` | `<repo>/vms.tfvars` | Multi-VM definition file; if absent (and not set explicitly), falls back to the single demo VM below |
| `LAB_CLONE_NAME` | `ubuntu24-demo` | Single fallback VM name when `vms.tfvars` is absent |
| `LAB_CLONE_CPUS` | `2` | vCPUs for the single fallback VM |
| `LAB_CLONE_MEMORY_MB` | `2048` | Memory (MB) for the single fallback VM |
| `LAB_PLAYBOOK` | `<repo>/ansible/configure-guest.yml` | Default playbook run by `./lab configure` when none is specified |
| `LAB_GUEST_WAIT_SECONDS` | `300` | Maximum seconds `./lab configure` waits for all VMs to report IP, user, and host key |

## Repository Layout

| Path | Contents |
|---|---|
| `lab` | Single CLI entry point in WSL |
| `lib/` | Internal scripts called by `lab` (`config.sh`, `account.sh`, `wsl-tools.sh`, `base.sh`, `cloud-config.sh`, `register-vm.py`, `check-base.py`, `preflight.sh`, `diagnose.sh`, `lifecycle.sh`, `bootstrap-guest.sh`, `cleanup-guest.py`, `configure.sh`, `guest-inventory.py`, `guest-proxy.sh`) |
| `windows/` | `setup.ps1` (elevated PowerShell setup/status/remove) and `tcp-relay.ps1` (stdio TCP relay used when direct WSL-to-guest SSH needs a Windows hop) |
| `terraform/` | Terraform configuration pinning `elsudano/vmworkstation` `2.0.1` (`main.tf`, `variables.tf`) |
| `ansible/` | Default nginx smoke-test playbook (`configure-guest.yml`) and all-VM readiness check (`check-lab.yml`) |
| `lab.env.example`, `vms.tfvars.example` | Templates for `lab.env` and `vms.tfvars` |
| `INSTALL.md` | Agent installation instructions for Claude Code and Codex |
| `.claude/skills/vmware-wsl-lab/` | Canonical `vmware-wsl-lab` agent skill (`SKILL.md`, `reference/`). `.agents/skills/vmware-wsl-lab/` is the Codex copy synced by `tools/sync-agent-skills.sh` |

## Notes

- **Verified scope:** Verified on one laptop on 2026-11-09 (VMware Workstation Pro already installed, WSL2 mirrored networking, Windows Firewall Private and Public profiles off): `windows\setup.ps1 Install`, `./lab setup` through the base VM, a clone with `./lab up`, `./lab configure` twice (second run `changed=0`), `./lab configure ansible/check-lab.yml`, `./lab destroy` with file cleanup, and a reboot with WSL `sshd` and `vmrest` up before any logon. The unbooted base with a pinned host key and the `lab` user was checked the same day with `./lab setup --recreate`, `up`, `configure` twice, `check-lab.yml`, `down`/`up`, and again after disabling `open-vm-tools` and removing `vmware-rpctool` in the guest. Each `LAB_IMAGE` (`ubuntu-24.04`, `ubuntu-22.04`, `debian-13`) passed `setup --recreate`, `up`, `configure` twice, `check-lab.yml`, `down`/`up` and `destroy` the same day. A mixed `vms.tfvars` (Ubuntu 24.04 + Debian 13) passed the same steps; changing one VM's image to Ubuntu 22.04 rebuilt only that VM (`up --allow-destroy`) while the other stayed on; and a clone made by the previous version kept running through the upgrade (`configure` `changed=0`). **Not yet verified:** a fresh PC without VMware Workstation installed, and a PC with Windows Firewall profiles enabled.
- **Files never to commit:** `lab.env`, `*.env`, `vmrest.env`, `*.tfvars` (`vms.tfvars`), SSH keys (`*_ed25519*`), `inventory.json`, `known_hosts*`, `*.tfstate*`, `cleanup-pending.json`, and VM disks/images/ISOs (`base/`, `cloud-init/`, `*.ova`, `*.vmdk`, `*.vmx`, `*.iso`) are gitignored and must stay out of version control.
- **Community Terraform provider:** `elsudano/vmworkstation` (`2.0.1`) is an unofficial provider. It looks up the base VM by `displayName` and takes the first match, and it does not replace clones on its own when the base VM is rebuilt; this repository enforces both checks (`lib/check-base.py` and `terraform_data.vm_base`). Review its schema before upgrading the provider version.
- **Troubleshooting:** See [`.claude/skills/vmware-wsl-lab/reference/pitfalls.md`](.claude/skills/vmware-wsl-lab/reference/pitfalls.md) for known symptoms and fixes.

## License

[MIT](LICENSE)
