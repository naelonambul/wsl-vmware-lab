# Operating an existing lab host (template)

Use this when the lab is already installed and you are in a WSL shell on it (locally or over SSH). Host name, users, distro and paths differ per machine: take them from `preflight.sh` output, not from this file.

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
2. `bash terraform-vm.sh status`: inspect the current state and report only non-secret findings.
3. Read the repository `README.md` if settings look unusual.
4. Preserve the base VM and any existing clone unless the user explicitly authorizes changes.

The shell is Bash inside WSL2, not PowerShell. Run Windows commands through `powershell.exe -NoProfile -Command ...`.

## Where things are (defaults; preflight shows the actual values)

| Component | Default | Override |
| --- | --- | --- |
| Repository | wherever it was cloned; preflight prints it | n/a |
| Windows user profile | detected through Windows interop | `LAB_CLONE_VMX_WIN` |
| Clone VMX | `%USERPROFILE%\Documents\Virtual Machines\<clone>\<clone>.vmx` | `LAB_CLONE_VMX_WIN` |
| Base VMX | `base/ubuntu-base.vmx` in the repository | `LAB_BASE_DIR` |
| Workstation tools | `/mnt/c/Program Files/VMware/VMware Workstation/` | `VMWARE_DIR` |
| Private directory | `~/.config/wsl-vmware-lab/` | `LAB_PRIVATE_DIR` |
| Guest user | `ubuntu` | `LAB_GUEST_USER` |
| DHCP leases | `/mnt/c/ProgramData/VMware/vmnetdhcp.leases` | `LAB_DHCP_LEASES` |

Use `wslpath -w` for arguments passed to Windows tools and `wslpath -u` for paths read from Terraform. VM disks and ISO files must be on a Windows drive.

## Responsibilities and connectivity

1. External agent → SSH → WSL.
2. Linux Terraform → Windows vmrest `http://127.0.0.1:8697/api` (mirrored WSL networking).
3. Terraform clones the registered base and controls CPU, memory, power and destruction.
4. Terraform `local-exec` runs `bootstrap-guest.sh` on the powered-off clone (cloud-init ISO + management NIC).
5. Ansible connects to the running guest, installs nginx, deploys a page and checks HTTP.

VMnet8 = NAT (internet), VMnet1 = host-only management. If WSL cannot reach the management IP directly, inventory uses `guest-proxy.sh` + `tcp-relay.ps1` (per-connection stdio relay; no listening port).

Preflight reports whether `.wslconfig` uses mirrored networking. Do not change `.wslconfig` merely to run the example.

## Credentials and private artifacts

- vmrest account: secrets file `%USERPROFILE%\.env` (`LAB_SECRETS_FILE`), lines `VMWS_USERNAME=`/`VMWS_USER=` and `VMWS_PASSWORD=`, parsed (not executed) by `lib/config.sh`. Environment variables or `lab.env` override it. Terraform receives `TF_VAR_vmrest_*` from `lib/config.sh`.
- Private files: `lab_ed25519` key pair, `inventory.json`, `known_hosts-<vm-id>`, `seed-<vm-id>/` under `LAB_PRIVATE_DIR`.
- Never print or copy credentials, keys, Terraform state or inventory into chat, logs, commits or docs. Never enable `set -x` around config loading.
- `LAB_GUEST_USER` (default `ubuntu`) sets both the cloud-init user and the Ansible user.

## Routine commands

```bash
bash api-status.sh
bash terraform-vm.sh status
bash terraform-vm.sh on
ANSIBLE_TIMEOUT=60 bash configure-guest.sh
bash terraform-vm.sh off        # a Terraform apply; review state first
bash terraform-vm.sh destroy    # interactive; runs cleanup-guest.py afterwards
```

`destroy` saves state metadata, runs Terraform destroy, then removes only the generated seed ISO and an empty clone directory after verifying VMX/VMDK are gone. Bare `terraform destroy` skips this. It then removes that clone id's `known_hosts-<id>` and `seed-<id>/` (only the generated cloud-init files) under `LAB_PRIVATE_DIR`; other files are left.

## File guide

| File | Behavior |
| --- | --- |
| `terraform/main.tf` | Pins `elsudano/vmworkstation` 2.0.1; data source for base `var.base_name`; resource `vmworkstation_virtual_machine.ubuntu_demo`; bootstrap via `terraform_data` |
| `terraform/variables.tf` | endpoint, credentials (sensitive), names, VMX path, CPU/memory, validated `on`/`off` |
| `terraform-vm.sh` | loads config, API precheck, OFF→bootstrap→ON, cleanup-aware destroy |
| `bootstrap-guest.sh` | refuses a running clone; per-VM cloud-init seed; attaches ISO and management NIC |
| `guest-inventory.py` | state VMX path + management MAC → DHCP lease → direct SSH or proxy → private inventory |
| `configure-guest.sh` | retries inventory 30 times, then runs the playbook |
| `ansible/configure-guest.yml` | wait SSH/cloud-init; nginx; page; service; HTTP 200 + content assertion |
| `register-base.sh`, `register-vm.py` | idempotent `POST /api/vms/registration` |
| `prepare-cloud-init.sh`, `create-base-template.sh`, `prepare-base.sh` | one-time base preparation |
| `setup-wsl-tools.sh` | installs Terraform (HashiCorp apt), Ansible, image tools |

The resource address `vmworkstation_virtual_machine.ubuntu_demo` is used by helper scripts; keep it if you rename the clone.

## Isolation for multiple agents

One state, one clone and one inventory per checkout. Serialize work, or for an authorized experiment use a separate checkout with its own `lab.env` (`LAB_CLONE_NAME`, `LAB_CLONE_VMX_WIN`, `LAB_PRIVATE_DIR`, `LAB_INVENTORY`) and its own Terraform state. Never copy an existing state into a new experiment.

## Optional: multi-VM application deployment (example topology)

A lab can grow from the single demo clone into an application environment. Example layout (fill in your own addresses on `<LAN_SUBNET>`):

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

- Recreating the same clone path can reuse VM ID and IP → stale host key. Verify the clone by API path and management MAC/lease, then remove only that clone's entry with `ssh-keygen -f <clone-known-hosts> -R <ip>`.
- Default Ansible privilege-escalation wait (12 s) intermittently timed out; `ANSIBLE_TIMEOUT=60` fixed it. Root cause of the latency was not confirmed.
- After a reboot vmrest may be absent (HTTP 000). Start the `VMware vmrest API` task before retrying Terraform; `0 destroyed` with vmrest down is not success.
- SSH scheduled tasks trigger at Windows logon, not boot. Do not restart WSL or edit those tasks during an active remote session without console access.

## Evidence rules

Report a result only with the command and its output from this run. Earlier logs and blog results are history, not current evidence. State which reboot/persistence scenarios were actually tested.
