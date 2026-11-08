# Operating an existing lab host (template)

Use this when the lab is already installed and you are in a WSL shell on it (locally or over SSH). Host name, users, distro and paths differ per machine: take them from `lib/preflight.sh` output, not from this file.

## Contents
- Start here
- Where things are (defaults; preflight shows the actual values)
- Responsibilities and connectivity
- Credentials and private artifacts
- Routine commands
- File guide
- Isolation for multiple agents
- Optional: multi-VM application deployment (example topology)
- Known operational lessons
- Evidence rules

## Start here

1. Run preflight as described in SKILL.md section 0, and continue only when it exits 0.
2. `./lab status`: inspect the current state and report only non-secret findings.
3. Read the repository `README.md` if settings look unusual.
4. Preserve the base VM and any existing clone unless the user explicitly authorizes changes.

The shell is Bash inside WSL2, not PowerShell. Run Windows commands through `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command ... </dev/null`, always by full path: an SSH session into WSL has no Windows folders on `PATH` (bare `powershell.exe` gives `command not found`, also in `bash -lic`). The same goes for other Windows programs (`"/mnt/c/Program Files/VMware/VMware Workstation/vmrun.exe"` by default, or `VMWARE_DIR` from `lab.env`; `/mnt/c/Windows/System32/cmd.exe`). `lib/preflight.sh` keeps the full path in `$PS`.

## Where things are (defaults; preflight shows the actual values)

| Component | Default | Override |
| --- | --- | --- |
| Repository | wherever it was cloned; preflight prints it | n/a |
| Windows user profile | detected through Windows interop | `LAB_VM_ROOT_WIN` |
| VM list | `vms.tfvars` in the repository if present, else one VM `LAB_CLONE_NAME` | `LAB_VMS_FILE` |
| Clone VMX (each VM) | `%USERPROFILE%\Documents\Virtual Machines\<name>\<name>.vmx` | `LAB_VM_ROOT_WIN` |
| Base VMX | `base/ubuntu-base.vmx` in the repository | `LAB_BASE_DIR` |
| Workstation tools | `/mnt/c/Program Files/VMware/VMware Workstation/` | `VMWARE_DIR` |
| Private directory | `~/.config/wsl-vmware-lab/` | `LAB_PRIVATE_DIR` |
| Guest VM user | image default, reported via guestinfo | none (`LAB_GUEST_USER` is ignored) |
| DHCP leases | `/mnt/c/ProgramData/VMware/vmnetdhcp.leases` | `LAB_DHCP_LEASES` |
| DHCP config (management subnet) | `/mnt/c/ProgramData/VMware/vmnetdhcp.conf` | `LAB_DHCP_CONF` |

Use `wslpath -w` for arguments passed to Windows tools and `wslpath -u` for paths read from Terraform. VM disks and ISO files must be on a Windows drive.

## Responsibilities and connectivity

1. External agent → SSH → WSL.
2. Linux Terraform → Windows vmrest `http://127.0.0.1:8697/api` (mirrored WSL networking).
3. Terraform clones the registered base and controls CPU, memory, power and destruction.
4. Terraform `local-exec` runs `lib/bootstrap-guest.sh` on the powered-off clone (cloud-init ISO + management NIC).
5. Ansible connects to the running guest, installs nginx, deploys a page and checks HTTP.

VMnet8 = NAT (internet), VMnet1 = host-only management. If WSL cannot reach the management IP directly, inventory uses `lib/guest-proxy.sh` + `windows/tcp-relay.ps1` (per-connection stdio relay; no listening port).

Preflight reports whether `.wslconfig` uses mirrored networking. Do not change `.wslconfig` merely to run the example.

## Credentials and private artifacts

- vmrest account: secrets file `%USERPROFILE%\.env` (`LAB_SECRETS_FILE`), lines `VMWS_USERNAME=`/`VMWS_USER=` and `VMWS_PASSWORD=`, parsed (not executed) by `lib/config.sh`. Environment variables or `lab.env` override it. Terraform receives `TF_VAR_vmrest_*` from `lib/config.sh`.
- Private files: `lab_ed25519` key pair, `inventory.json`, `known_hosts-<vm-id>`, `seed-<vm-id>/` under `LAB_PRIVATE_DIR`.
- Never print or copy credentials, keys, Terraform state or inventory into chat, logs, commits or docs. Never enable `set -x` around config loading.
- Guest user: cloud-init keeps the image's default user; a guest unit writes its name to guestinfo `wsl-vmware-lab.guest_user` on every boot and `lib/guest-inventory.py` reads it with `vmrun readVariable ... guestVar`; the same unit reports the SSH host key as `wsl-vmware-lab.host_key`. Until the guest reports both, inventory generation retries; the inventory and known_hosts files are written only once every VM checked out.

## Routine commands

```bash
./lab status
./lab status
./lab up
./lab configure
./lab down        # a Terraform apply; review state first
./lab destroy    # interactive; runs lib/cleanup-guest.py afterwards
```

`destroy` saves state metadata, runs Terraform destroy, then removes only the generated seed ISO and an empty clone directory after verifying VMX/VMDK are gone. Bare `terraform destroy` skips this. It also removes a leftover `<clone>.vmxf` that names the clone's VMX, then that clone id's `known_hosts-<id>` and `seed-<id>/` (only the generated cloud-init files) under `LAB_PRIVATE_DIR`; other files are left and reported.

## File guide

| File | Behavior |
| --- | --- |
| `terraform/main.tf` | Pins `elsudano/vmworkstation` 2.0.1; data source for base `var.base_name`; `vmworkstation_virtual_machine.vm` and `terraform_data.guest_bootstrap` with `for_each = var.vms`; output `vms` (id, path, groups per name). Clone `description` must equal the base's (provider limitation) |
| `terraform/variables.tf` | endpoint, credentials (sensitive), base name, `vm_root_win`, `vms` map (validated names/groups), validated `on`/`off` |
| `vms.tfvars.example` | template for a multi-VM system (`web1` in `demo`+`web`, `db1` in `db`) |
| `lib/lifecycle.sh` | loads config, API precheck, passes `vms.tfvars`; `on`/`off` first confirm the base with `lib/check-base.py` (exactly one VM with the base name, at the base VMX); `on` checks the plan (refuses VM delete/replace, including clones of a rebuilt base, without `--allow-destroy`) → creates new VMs off (targeted) → bootstrap → all ON; cleans VMs removed with `--allow-destroy`; `off` refuses a plan with anything but power changes; VMs about to be deleted are journaled in `terraform/cleanup-pending.json` and cleaned once gone (failed cleanup is retried by the next `on`/`destroy`/`cleanup`; `status` lists pending entries); cleanup-aware destroy |
| `lib/bootstrap-guest.sh` | refuses a running clone; per-VM cloud-init seed (hostname = VM name); attaches ISO and management NIC |
| `lib/guest-inventory.py` | per VM: VMX management MAC → current DHCP lease on the management subnet, guestinfo user and SSH host key (pinned), direct SSH or proxy → private inventory with groups + `lab`, written atomically |
| `lib/configure.sh` | `[PLAYBOOK] [ansible options]`; waits for the inventory (all VMs) up to `LAB_GUEST_WAIT_SECONDS` (default 300 s, each attempt limited to 120 s), then runs the playbook |
| `ansible/configure-guest.yml` | example: wait SSH/cloud-init; nginx; page; service; HTTP 200 + content assertion (group `demo`) |
| `ansible/check-lab.yml` | smoke test for group `lab`: SSH, cloud-init, sudo, OS facts |
| `./lab status` | power state of every VM, or of one name/id |
| `lib/register-vm.py` | idempotent `POST /api/vms/registration` (called by `./lab setup`) |
| `lib/base.sh` (`./lab setup`) | one-time base preparation; markers make re-runs safe, `--recreate` (base off, user-approved) rebuilds |
| `lib/wsl-tools.sh` (sudo, run by `./lab setup` when a tool is missing) | installs Terraform (HashiCorp apt), Ansible, image tools |

Helper scripts read the Terraform output `vms`, not resource addresses. A state made by the older single-clone version (`vmworkstation_virtual_machine.ubuntu_demo`) is not migrated: destroy it with that version before upgrading, or the new version plans a second clone at the same path.

## Isolation for multiple agents

One state, one VM set and one inventory per checkout. Serialize work, or for an authorized experiment use a separate checkout with its own `lab.env` (`LAB_VMS_FILE` or `LAB_CLONE_NAME`, `LAB_VM_ROOT_WIN`, `LAB_PRIVATE_DIR`, `LAB_INVENTORY`) and its own Terraform state. VM names must not collide with another checkout's VMs in the same `LAB_VM_ROOT_WIN`. Never copy an existing state into a new experiment.

## Optional: multi-VM application deployment (example topology)

A lab can grow from the single demo clone into an application environment: list the VMs in `vms.tfvars` with groups such as `web`, `api`, `db`, and target those groups from the user's own playbooks (`lib/configure.sh <playbook>`). The NAT/host-only clones made here get DHCP addresses; the bridged layout below came from a hand-built deployment. Example layout (fill in your own addresses on `<LAN_SUBNET>`):

| Role | Address | Notes |
| --- | --- | --- |
| nginx (entry) | `<IP_NGINX>` | serves `/docs`, proxies to HAProxy |
| HAProxy | `<IP_HAPROXY>` | balances API nodes; check alternating backend header |
| API node 1/2 | `<IP_API_1>`, `<IP_API_2>` | app service under `/opt/<app>` |
| MariaDB primary | `<IP_DB_PRIMARY>` | app account limited to `<app>.*` and `<LAN_SUBNET>` |
| MariaDB replica | `<IP_DB_REPLICA>` | read-only; check both replication threads |
| MongoDB | `<IP_MONGO>` | authorization enabled; firewall 27017 to `<LAN_SUBNET>` only |

Lessons from running such a deployment:

- Bridged guests need explicit static network config (netplan) and cloud-init network regeneration disabled; the demo clone path creates NAT clones only.
- Gracefully stop a VM before editing its VMX; back up the VMX and guest network files first.
- A stale copy of the deployment env file with old addresses broke replica connections. Keep one private env file (symlink copies to it) and check addresses and inventory before each deploy. Never package private env files with installer sources.
- After changing a DB password, update every consumer's env file and restart services; record only that it changed, never the value.
- Verification should cover: HTTP 200 on health/docs through every hop, both API nodes in rotation, schema/migration parity on primary and replica, replica read-only. This does not prove automatic failover.

## Known operational lessons

- Host keys are not learned on first contact: each clone reports its SSH host key through guestinfo (`wsl-vmware-lab.host_key`), `lib/guest-inventory.py` writes it to `known_hosts-<id>` under the alias `wsl-vmware-lab-<id>`, and SSH runs with `StrictHostKeyChecking=yes`. A different key at the address (another VM got it) fails the connection instead of configuring the wrong VM.
- Default Ansible privilege-escalation wait (12 s) intermittently timed out; `ANSIBLE_TIMEOUT=60` fixed it. Root cause of the latency was not confirmed.
- After a reboot vmrest may be absent (HTTP 000). Start the `VMware vmrest API` task before retrying Terraform; `0 destroyed` with vmrest down is not success.
- SSH scheduled tasks start at boot without logon (S4U) and again at logon when registered by the current `wsl2-ssh-forward.ps1 InstallTask`; hosts set up earlier may still have logon-only tasks. Do not restart WSL or edit those tasks during an active remote session without console access.
- A host that sleeps or hibernates drops every remote session; from outside it looks like an SSH timeout. Preflight reports the power plan (`power (plugged in)` / `power (on battery)`); changing it is the user's call (`windows/configure-power.ps1 -Action Apply`, undo with `-Action Restore`).

## Evidence rules

Report a result only with the command and its output from this run. Earlier logs and blog results are history, not current evidence. State which reboot/persistence scenarios were actually tested.

A command handed to the user (for example a one-line `ssh <user>@<host> '...'` to run a step that needs their approval) must be the exact form you ran and verified in this session, not a retyped or shortened version. A retyped command with bare `powershell.exe` failed this way.
