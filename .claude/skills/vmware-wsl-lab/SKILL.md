---
name: vmware-wsl-lab
description: Sets up and operates a Windows + WSL2 + VMware Workstation lab where Linux Terraform (elsudano/vmworkstation provider via the vmrest API) clones Ubuntu VMs and Ansible configures them over SSH, using the scripts in the wsl-vmware-lab repository. Use when installing WSL SSH access, VMware Workstation, vmrest, Terraform or Ansible on a Windows PC; when creating, powering, configuring or destroying lab VMs; when editing lab.env; or when debugging vmrest port 8697, WSL mirrored networking, portproxy, cloud-init, DHCP-lease inventory or stale known_hosts errors.
---

# VMware Workstation + WSL lab

Two situations share this skill. Pick one first.

## 1. Choose the path

**Preparing a new Windows PC** (no WSL SSH / VMware / vmrest / Terraform yet)
→ Read [reference/install-new-pc.md](reference/install-new-pc.md) in full before changing anything.

**Working on an already installed lab host** (repository checked out in WSL, `lab.env` present)
→ Read [reference/operate-existing-host.md](reference/operate-existing-host.md) before running any lifecycle command.

**Something failed** (timeout, 404, 409, HTTP 000, host key changed, Ansible become timeout, NIC error)
→ Read [reference/pitfalls.md](reference/pitfalls.md) and match the symptom before retrying.

**Need the original step-by-step explanation of one layer**
- WSL2 SSH on Windows port 22, scheduled tasks, `.wslconfig` → [reference/blog-1-ssh-forwarding.md](reference/blog-1-ssh-forwarding.md)
- Tools install, vmrest, base VM image and API registration → [reference/blog-2-tools-base-vm.md](reference/blog-2-tools-base-vm.md)
- Terraform clone, Ansible nginx, destroy/cleanup → [reference/blog-3-terraform-ansible.md](reference/blog-3-terraform-ansible.md)

## 2. Architecture (both paths)

```
external agent --SSH:22--> Windows --(mirrored or portproxy)--> WSL2 Ubuntu sshd
WSL Terraform --HTTP--> Windows vmrest http://127.0.0.1:8697/api --> VMware Workstation
WSL Ansible --SSH--> guest VM (VMnet1 host-only mgmt NIC; VMnet8 NAT for internet)
```

Terraform owns VM existence and power. Ansible owns guest software. They do not call each other (Terraform only runs a `local-exec` bootstrap on the powered-off clone).

## 3. Configuration

All bash scripts source `lib/config.sh`, which reads `lab.env` (gitignored; template `lab.env.example`) or the file named in `LAB_ENV_FILE`.

- Windows-side paths default from the logged-in Windows user profile (`%USERPROFILE%\Documents\Virtual Machines\<clone>\...`).
- WSL account and guest VM user default to `ubuntu` (`LAB_GUEST_USER`).
- Private files live in `~/.config/wsl-vmware-lab/` (`LAB_PRIVATE_DIR`).
- Windows scripts take parameters instead: `wsl2-ssh-forward.ps1 -AllowedRemoteAddress <LAN/24> -Distro <name>`, `start-vmrest.ps1 -VmrestPath <exe>`.

## 4. Rules that always apply

1. **User decides.** Propose options with trade-offs before changing a host, and run only what the user picks.
2. **Secrets.** Never print, copy or commit `lab.env`, vmrest credentials, SSH private keys, Terraform state or generated `inventory.json`. Do not enable `set -x` around config loading. New variables get a fake value in `lab.env.example`.
3. **Preserve.** Never delete or re-prepare the base VM, reset WSL distributions, restore VMware network defaults, or overwrite an existing Terraform state unless the user explicitly asks.
4. **Check before lifecycle commands.** An unauthenticated `curl` to `/api/vms` must return `401` (or `200` with auth). `000`/timeout means vmrest is down; fix that before touching Terraform.
5. **One runner per state.** One checkout = one state, one clone, one inventory. Serialize work, or use a fully isolated checkout with its own `lab.env`.
6. **Destroy via the wrapper.** Use `bash terraform-vm.sh destroy` (runs cleanup), never bare `terraform destroy`. `0 destroyed` with vmrest down is not success.
7. **Never disable host key checking globally.** Remove only the verified clone's stale entry.
8. **Never disable Hyper-V / VBS / Secure Boot** to make VMware start; WSL2 needs them.
9. **Verification.** Report a step as done only with the command and its actual output. Historical results in references are not fresh evidence.

## 5. Routine command set (repository root, in WSL)

```bash
bash api-status.sh                         # vmrest inventory check
bash terraform-vm.sh status                # state (contains details; report only non-secret findings)
bash terraform-vm.sh on                    # OFF create -> bootstrap -> ON
ANSIBLE_TIMEOUT=60 bash configure-guest.sh # nginx + HTTP assertions
ANSIBLE_TIMEOUT=60 bash configure-guest.sh # idempotence: expect changed=0 failed=0
bash terraform-vm.sh off                   # Terraform apply, not a pure power command
bash terraform-vm.sh destroy               # interactive; cleanup-aware
```

`ANSIBLE_TIMEOUT=60` avoids the known 12-second privilege-escalation prompt timeout.

## 6. Acceptance checklist (copy and tick)

```
- [ ] vmrest reachable from WSL (401 unauthenticated, 200 authenticated)
- [ ] clone appears in API inventory and is poweredOn
- [ ] Ansible run 1: HTTP 200 + expected content, failed=0
- [ ] Ansible run 2: changed=0 unreachable=0 failed=0
- [ ] power-off confirmed by API, not only Terraform exit code
- [ ] destroy removed clone from API/state + VMX, VMDK, seed ISO, clone dir
- [ ] base VM and unrelated VMs unchanged; shared inventory restored
- [ ] external SSH and WSL->vmrest still work afterwards
```

## 7. Report format

Summary of changes / files changed / verification (commands run and their output) / remaining risks.

## Official references

WSL install/networking/config: learn.microsoft.com/en-us/windows/wsl/ · Workstation API: developer.broadcom.com/xapis/vmware-workstation-pro-api/latest/ · Provider: github.com/elsudano/terraform-provider-vmworkstation · Terraform install: developer.hashicorp.com/terraform/install · Ansible: docs.ansible.com · Ubuntu cloud images: cloud-images.ubuntu.com/noble/current/
