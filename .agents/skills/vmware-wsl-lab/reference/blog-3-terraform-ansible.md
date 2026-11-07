# Blog part 3: Terraform clone + Ansible configuration

Summary of https://naelonambul.tistory.com/209 ("[WSL 자동화 3편] Terraform으로 VM 만들고 Ansible로 Ubuntu 설정하기"). Re-read the post if exact wording matters.

## Contents
- Goal
- Commands
- Files
- Versions and network settings
- What `terraform-vm.sh on` does
- IP discovery and playbook
- Verification results stated by the post
- Next goal stated by the post

Pitfalls from this post are merged into [pitfalls.md](pitfalls.md).

## Goal

Clone a test VM from the part 2 base. Terraform manages creation and power; Ansible configures Ubuntu inside. They run separately and do not call each other.

## Commands (WSL, project folder)

```bash
bash api-status.sh              # 0) vmrest: /api/vms HTTP 200 = OK
bash terraform-vm.sh on         # 1) clone + boot
bash configure-guest.sh         # 2) Ansible: nginx, page, HTTP check
bash terraform-vm.sh destroy    # 3) delete + cleanup

bash terraform-vm.sh off
bash terraform-vm.sh status
bash run-demo.sh on             # legacy name -> terraform-vm.sh
```

`destroy -auto-approve` is supported for automated runs (only for an explicitly authorized disposable state).

`configure-guest.sh` runs:

```bash
ansible-playbook -i "$LAB_INVENTORY" ansible/configure-guest.yml   # default ~/.config/wsl-vmware-lab/inventory.json
```

## Files

| Path | Role |
|---|---|
| `terraform/main.tf`, `variables.tf` | resources and variables |
| `terraform-vm.sh` | entry (`on`/`off`/`status`/`destroy`), API precheck |
| `bootstrap-guest.sh` | cloud-init ISO + mgmt NIC on powered-off VM |
| `cleanup-guest.py` | remove leftover seed ISO / empty folder after destroy |
| `api-status.sh`, `check-power.sh` | API and power checks |
| `configure-guest.sh` | Ansible wrapper |
| `guest-inventory.py` | builds inventory |
| `guest-proxy.sh` + Windows `tcp-relay.ps1` | SSH via Windows when direct access fails |
| `ansible/configure-guest.yml` | playbook |

Appendix, not part of the main flow: `run-demo.sh`, `diagnose-base.sh`, `diagnose-error.sh`, `diagnose-terraform.sh`, `configure-vmrest-bridge.ps1`, `remove-vmrest-bridge.ps1`. The bridge scripts need admin and change Windows networking; the post says skip them. `diagnose-terraform.sh` is read-only: it shows the VM list, state, base power and the plan's changes (warning on delete/replace) and applies nothing. (The blog's original version shut down the base VM and applied `power_state=off`.)

## Versions and network settings

- Provider `elsudano/vmworkstation` 2.0.1; its API client `vmware-workstation-api-client` v1.10.46
- Endpoint `http://127.0.0.1:8697/api`
- Guest Ubuntu 24.04 (noble) cloud image
- NIC 1 VMnet8 (NAT) for internet/apt; NIC 2 VMnet1 (host-only) for management SSH from WSL Ansible
- Test VM NIC model `e1000`

## What `terraform-vm.sh on` does

1. API precheck: `/api/vms` must return 200 (3 s connect, 8 s total timeout)
2. Clone base, powered off
3. `bootstrap-guest.sh` via `terraform_data`/`local-exec`: cloud-init ISO + mgmt NIC
4. Re-apply with power on

cloud-init: accounts, SSH keys, DHCP. Ansible: packages.

## IP discovery and playbook

`guest-inventory.py`: reads VM path and mgmt NIC MAC from state, finds the IP in VMware DHCP leases for that MAC, ignores provider `0.0.0.0/0`.

`configure-guest.yml`: wait for SSH + cloud-init → install nginx → deploy page, start service → assert HTTP 200 and the deployed string from inside the guest.

## Verification results stated by the post

- Create + power on: success
- Ansible run 1: nginx, HTTP 200, `failed=0`
- Ansible run 2: `ok=6 changed=0 unreachable=0 failed=0`
- Destroy: 2 resources removed, no leftover folder, base kept
- Unverified by the post: vmrest auto-start after reboot (later verified with the repository's boot/S4U task)

Networking notes: the host had no VMnet8 host adapter; in mirrored mode VMware host-only ranges were not directly reachable, so VMnet1 management with SSH relay fallback was used.

## Next goal stated by the post

One automated flow: `git pull` → Terraform create → wait SSH → Ansible deploy/test → save logs → stop or delete. Real project deployment, CI and crash recovery were future work (operate-existing-host.md describes a later multi-VM deployment as a template).
