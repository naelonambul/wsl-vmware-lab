# Agent Installation Playbook: Windows, WSL SSH, VMware, Terraform and Ansible

Use this document as an execution instruction for an agent with Windows terminal access, browser/computer-use tools, and an external SSH client. Written 2026-11-05. Read the entire document before making changes.

> Implementation: the scripts in this repository (wsl-vmware-lab). Optional settings go in `lab.env` (template `lab.env.example`); the vmrest account goes in `%USERPROFILE%\.env`. See `README.md`.

## Contents
- Objective and boundaries / Execution rules
- 1. Discover the machine and create a checkpoint
- 2. Update WSL, set resources, prepare Ubuntu, and resume after restart
- 3. Configure Linux SSH and remote access (firewall, NAT portproxy, start at boot, keep the PC awake)
- 4. Install VMware Workstation Pro using computer use
- 5. Configure and keep vmrest available
- 6. Install Linux automation tools
- 7. Prepare portable project files and a base VM (artifact table)
- 8. Run isolated acceptance tests (required evidence)
- 9. Computer-use protocol and failure handling
- 10. Handoff deliverables
- Official references

## Objective and boundaries

Prepare a Windows PC so an external agent can SSH into Ubuntu on WSL, use Linux Terraform to create VMware Workstation guests, and use Linux Ansible to configure those guests. Verify one disposable guest through creation, software configuration, HTTP testing, a second idempotent Ansible run, power-off and destruction.

Use shell commands for reproducible configuration and computer use for installer screens, firmware settings, account login and visual verification. Do not treat GUI screenshots alone as successful installation evidence. Do not create ordinary test VMs through the Workstation GUI; create/register the base through files and API, and let Terraform create disposable clones.

This is an agent workflow, not a bundled unattended installer. It tells the executing agent what to discover, implement and verify. No companion automation files are embedded or automatically downloaded by this document.

## Execution rules

- Inspect existing installations and reuse compatible components. Do not reset WSL distributions, replace existing VM networks, overwrite Terraform state or delete existing VMs.
- Use the authorization already provided for installation. Request user participation only when genuinely required for login/MFA, secure-desktop UAC, firmware changes or a disruptive reboot. Record a resume checkpoint before rebooting.
- Never disable Hyper-V, Virtual Machine Platform, virtualization-based security or Secure Boot merely to make VMware start: WSL2 depends on the Windows virtualization stack. Diagnose compatibility for the installed Workstation version first.
- Use official downloads. Ask the user to complete account credentials, MFA and CAPTCHA themselves. Do not bypass these controls.
- Keep secret values in a private `.env` outside the shared project; create `.env.example` with fake placeholders for every introduced environment variable. Do not log secret values or copy private keys, generated inventories or Terraform state into a repository.
- This repository reads `lab.env` (or `LAB_ENV_FILE`). A legacy `vmrest.env` is still read when `VMWS_CREDENTIALS_FILE` points to it. Paths and usernames from the original lab are examples, never defaults for a new machine; the defaults here are the Windows user profile; the guest VM user is the image's default user (reported via guestinfo), and the WSL user is whoever the user SSHes in as (their SSH config `User`), never set by scripts.
- Record chosen package versions in an installation manifest. Pin Terraform providers. Do not silently install an unbounded latest version and describe it as reproduced.

## 1. Discover the machine and create a checkpoint

In Windows PowerShell, collect:

```powershell
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber,OsArchitecture,CsTotalPhysicalMemory
Get-CimInstance Win32_Processor | Select-Object Name,VirtualizationFirmwareEnabled
wsl --status
wsl --version
wsl --list --verbose
Get-NetIPAddress -AddressFamily IPv4
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 22,8697
```

Some commands fail normally on a machine without WSL; distinguish missing software from failed installation. Determine the actual Windows profile, LAN address/subnet, WSL user, available disk space, existing Workstation version, VM locations and port ownership. This playbook targets an x64 Windows host and amd64 Ubuntu guest. Stop and redesign for ARM rather than downloading amd64 VM images blindly.

Prefer a supported Windows 11 release with mirrored WSL networking. Microsoft documents mirrored mode for Windows 11 22H2 and later. For a host without that capability, use the NAT branch below and verify its different API/SSH routes explicitly.

Choose and record these non-secret parameters in a local installation checkpoint: distribution name, WSL username, project Windows path, corresponding WSL path, VM root directory, base name, unique test clone name, LAN subnet, chosen versions and current stage. Use `wslpath` for path conversion. Place VM files on a Windows drive, not the WSL ext4 filesystem. If antivirus blocks downloads or writes under the Windows user profile, as on one host, put the repository outside it (for example `C:\wsl-vmware-lab`). The clone folder is VMware Workstation's default VM location (Edit > Preferences > Workspace; `prefvmx.defaultVMPath` in `%APPDATA%\VMware\preferences.ini`, default `%USERPROFILE%\Documents\Virtual Machines`): vmrest clones there whatever path Terraform asks for, so `LAB_VM_ROOT_WIN` must equal it (preflight checks). To keep VMs outside the profile, change that Workstation setting first, restart vmrest, then set `LAB_VM_ROOT_WIN` to the same folder. After moving an existing repository, re-register the base VM with `register-base.sh`, re-run `windows/install-vmrest-task.ps1` and `wsl2-ssh-forward.ps1 InstallTask` (elevated) so the tasks point at the new path, then run preflight.

## 2. Update WSL, set resources, then prepare Ubuntu

### 2.1. Update the WSL runtime

After the read-only discovery above, begin initial setup with:

```powershell
wsl --update --web-download
wsl --version
```

`--web-download` downloads updates from GitHub rather than the Microsoft Store; it is not a force/reinstall flag. Record the actual output, exit code and resulting version. An already-current result is successful. If WSL is absent and update cannot run, install the runtime with `wsl --install --no-distribution`, handle any requested restart below, then retry the update. Do not unregister distributions or uninstall WSL merely to update it.

### 2.2. Configure resources for this host

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory,NumberOfLogicalProcessors
```

Inspect `%USERPROFILE%\.wslconfig` if present and back it up before editing. Merge `memory`, `processors` and `swap` into its existing `[wsl2]` section without duplicating sections or removing unrelated settings. Choose limits based on the actual PC, existing workloads and planned VMware guests; explain the chosen values. WSL runs the automation tools while VMware guests also consume Windows resources. Do not reuse another machine's limits as universal defaults.

For example, on a roughly 32 GiB / 16 logical CPU host, 8GB memory, 4 processors and 4GB swap can be an initial allocation when leaving capacity for Windows and VMware. This is a sizing example, not a verified setting for every workload.

For supported mirrored mode, merge `networkingMode=mirrored` into the same section when configuring the lab network; otherwise use the NAT branch in section 3.

A resource/configuration change normally needs only `wsl --shutdown` and a new WSL start. This stops all running distributions: inspect `wsl --list --running`, coordinate active work, and keep Windows-side recovery access. A shutdown does not replace a Windows restart explicitly requested by an installer.

### 2.3. Prepare Ubuntu

Reuse a compatible installed distribution and its existing user account. When the target distribution is absent, run:

```powershell
wsl --install -d Ubuntu-24.04 --no-launch --web-download
```

If the command requests a Windows restart, follow section 2.4 before launching or claiming installation success. On first launch of a new distribution, let the user establish the Linux account/password privately by default. If the user explicitly authorizes the agent to create a named account, check for it first, create only that account, set its password through standard input without logging or storing it, add sudo membership as requested, and use `wsl --manage <Distro> --set-default-user <User>` when supported. Use UTF-8 without a BOM and Linux LF line endings when piping password input from Windows: CRLF can become an unintended trailing carriage return in the password. Verify default `whoami`, group membership and password-authenticated sudo; never enable passwordless sudo as a shortcut. Verify `wsl --list --verbose` reports version 2 for the chosen distribution; convert only that distribution with `wsl --set-version <Distro> 2` if necessary.

If virtualization is reported unavailable, also check `HyperVisorPresent` and actual WSL startup errors before concluding a firmware change is required. Do not diagnose a disabled BIOS setting from a single CIM flag. Explain confirmed blockers and arrange user participation for firmware changes; never guess firmware coordinates.

### 2.4. Windows restart and resume

Treat restart handling as part of setup, not an unrecorded interruption:

1. Save a non-secret checkpoint outside the repository, at `%LOCALAPPDATA%\wsl-vmware-lab\setup-checkpoint.json` (JSON). Include the repository path, target distribution, chosen resource values, config backup path (if any), exact command/output/exit code, current Windows boot time, completed stages, pending stages and next verification commands. Label the stage `pending-windows-restart`. Do not include passwords or private keys.
2. Tell the user why Windows must restart and to save open work. Obtain explicit restart timing unless already authorized. Never use a forced restart to close unsaved applications. The user may restart manually; no automatic task or unattended continuation is implied.
3. After reconnecting, read the checkpoint and compare `Get-CimInstance Win32_OperatingSystem | Select-Object LastBootUpTime` with the saved boot time. Check `wsl --version`, `wsl --status`, `wsl --list --verbose` and the existing `.wslconfig` again. A previous exit code 0 with restart-required output proves neither distribution readiness nor settings application.
4. If Ubuntu is still absent, rerun the recorded distribution install command once after the restart and inspect the new result. If present, launch it and finish any first-run initialization; reuse an existing account. Inspect errors before retrying and never unregister as generic recovery.
5. After a successful WSL2 launch, verify with `wsl -d <Distro> -- sh -lc 'uname -r; nproc; free -h; swapon --show'`. Compare CPU count, memory and swap with the chosen limits, allowing for kernel overhead. Mark the resource and distribution stages verified only from this fresh evidence. Proceed to SSH/VMware only within the requested scope.

When handing off before restart, state what is complete, what is pending, the checkpoint location and the exact next action. Keep the full installation marked incomplete until its own acceptance tests pass.

### Lessons from a real run

- A distribution install that returns exit 0 with a restart requirement may still leave no distribution after the restart. Check `wsl --list --verbose`; rerunning the same install command once then succeeded.
- Configured `.wslconfig` limits were confirmed only from inside the distribution (`nproc`, `free -h`, `swapon --show`), with memory slightly below the configured value because of kernel overhead.
- A root-only probe does not prove first-run account setup is complete; verify the default user and sudo separately.
- Files written from Windows for WSL scripts (such as `lab.env`) must use LF line endings; see pitfalls.
- The update/install flow left no SSH server: external `ssh` failed until openssh-server was installed (section 3). After registering the tasks (logon-only at the time, and not started by the installer), SSH still failed because WSL idled out; starting the keep-alive task immediately fixed it. The firewall profiles were disabled on that host, so firewall rules were not the cause.

This flow (update, resources, Ubuntu install, restart/resume, account, tools, vmrest, base, Terraform clone and Ansible) was verified on one host that already had VMware Workstation. External SSH from another LAN PC was then verified, including after a reboot before anyone logged on, once the SSH tasks used a boot trigger and S4U. A clean PC without VMware has not been tested.

## 3. Configure Linux SSH and remote access

Section 2 does not install an SSH server, and `preflight.sh` does not check WSL sshd. When the user will reach this WSL from another PC, do this section before moving on to tools and VMware; do not assume SSH exists because WSL, tools and vmrest work.

Inside Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y openssh-server
sudo ssh-keygen -A
sudo systemctl enable --now ssh
ss -lnt
```

If systemd is not available, inspect `/etc/wsl.conf` and the distribution's supported systemd configuration before selecting a service-start mechanism. Provision the external agent's public key in the intended user's `~/.ssh/authorized_keys` with directory mode 700 and file mode 600. Verify key login before considering password-login changes. Never write a private SSH key into documentation.

For mirrored mode, inspect both Windows and Hyper-V firewall rules. Create an inbound TCP 22 rule scoped to the intended LAN subnet and WSL creator ID; avoid a broad default inbound allow policy. `windows/wsl2-ssh-forward.ps1 Install` creates both (Windows rule `WSL2 SSH 22`, Hyper-V rule `WSL-SSH-Inbound-TCP22-LAN`) and saves the range for later `Refresh` runs. On a host whose firewall profiles are disabled, a successful login does not prove the range restriction works; test from an address outside the range when it matters. Microsoft documents `New-NetFirewallHyperVRule` and the WSL creator ID on its networking page. Check port ownership first: Windows OpenSSH and WSL SSH must not compete for the same externally reached endpoint. Choose a deliberate alternate port if necessary rather than stopping an unrelated service.

For NAT mode, use Windows `netsh interface portproxy` to forward the chosen Windows listening port to the current WSL IPv4 and port 22. Restrict its Windows firewall rule to the approved subnet. WSL NAT addresses can change, so implement a refresh action that discovers the current distribution address. Do not install a NAT portproxy for the mirrored path just because an older tutorial does so.

Diagnose a failed external login in this order, from read-only evidence, before changing firewall rules:

1. In WSL, `ss -lntp | grep ':22 '` and `ps -eo pid,etime,args | grep [s]shd`. No listener means sshd is not installed or not running. A very small `etime` that keeps resetting means WSL is idling out (see the persistence subsection).
2. Ask the user to try once, then read `/var/log/auth.log` (or `journalctl -u ssh`). An entry with the other PC's address means the network path works and the problem is authentication. No entry while sshd was running points to the network path.
3. Only then inspect firewalls: `Get-NetFirewallProfile -PolicyStore ActiveStore` (a disabled profile is not blocking) and `Get-NetFirewallHyperVProfile` / `Get-NetFirewallHyperVVMSetting` for the WSL creator ID (default inbound is typically Block). Add scoped allow rules if a profile that applies is enabled.

Connecting from Windows to its own LAN address on port 22 is not a valid test in mirrored mode: Windows has no `:22` listener and the attempt fails even when external access works.

Verify from the external controlling machine, not only from localhost:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 <wsl-user>@<windows-lan-ip> 'id; uname -r'
```

Compare the host key through the Windows/WSL local console before accepting it. Save a client SSH alias only after this succeeds.

### Persist SSH from boot, without logon

A one-shot `systemctl start ssh` command was insufficient to keep WSL reachable in the existing lab. Implement a Windows scheduled task under the correct interactive Windows user that starts the selected distribution as root and keeps the SSH daemon attached:

```powershell
wsl.exe -d <Distro> -u root -- /bin/sh -c 'systemctl stop ssh.socket ssh.service; mkdir -p /run/sshd; exec /usr/sbin/sshd -D -e'
```

This takes ownership of SSH startup in that distribution; do not run a competing daemon on port 22. Register it with a boot trigger and S4U (run whether or not the user is logged on, without storing a password), plus a logon trigger, like the vmrest task. This repository's `wsl2-ssh-forward.ps1 InstallTask` does this and starts it once immediately; its tasks (one of them elevated) run an administrator-only copy of the script in `%ProgramFiles%\wsl-vmware-lab`, never a file in the user-writable checkout. A task registered but not started leaves WSL to shut down when idle, taking sshd with it, until the next trigger fires. Confirm the `sshd -D -e` process keeps running (its `etime` grows across checks) before asking the user to test. Configure no execution time limit, ignore duplicate instances, and record the exact task name/action. Elevated privileges are needed for firewall/portproxy setup, not necessarily for the long-running user task. In NAT mode maintain a separate forwarding-refresh task. Verify with a real reboot: before anyone logs on (`quser` shows no users), log in over SSH from another LAN PC. Keep a recovery console available. A logon-only trigger is not acceptable for unattended use.

### Keep the PC awake

Sleep or hibernation stops WSL, sshd, vmrest and the VMs; from another PC this looks exactly like a broken SSH setup (port 22 timeout). Display-off timeouts are harmless. `bash preflight.sh` reads the active power plan through `windows/configure-power.ps1 -Machine` and warns when, on AC power, Windows sleeps or hibernates after a timeout or the lid action is not "do nothing" (and separately for battery on PCs that have one). Show the current values with `windows/configure-power.ps1` (no arguments, read only), then, with the user's OK, have the user run `-Action Apply` in Windows PowerShell (`-IncludeBattery` to cover battery too; `-WhatIf` to preview). Apply saves the original values once to `%LOCALAPPDATA%\wsl-vmware-lab\power-backup.json`; `-Action Restore` puts them back. Only the active plan changes, and a Group Policy power setting overrides it. Acceptance: preflight shows `[OK] power (plugged in)`.

## 4. Install VMware Workstation Pro using computer use

1. Open the official Broadcom download instructions linked below. Navigate to the current Windows Workstation Pro download in the support portal.
2. Let the user complete Broadcom authentication, export-compliance forms and terms where required. Record the selected release/build and download source.
3. Verify the downloaded installer's Authenticode signature and publisher before launching it. Do not trust a filename alone.
4. Use computer use to run the installer, inspect each page and complete the supported installation. Ask the user to handle secure-desktop UAC if the tool cannot interact with it. Keep existing VM files and networks intact.
5. If a reboot is required, checkpoint and resume. Open Workstation to verify the installed version and that it can coexist with the active WSL2 configuration.

Discover the actual installation directory. Verify `vmrun.exe -T ws list` from WSL using its full quoted path; zero running VMs is a valid result. Do not assume the old lab's Program Files path exists.

Inspect Virtual Network Editor through computer use. Reuse a working NAT network and a host-only management network with DHCP. Common names are VMnet8 and VMnet1, but inspect actual names/subnets and adapters. Do not restore all network defaults on an existing host. Record NIC/network choices for bootstrap and inventory scripts.

## 5. Configure and keep vmrest available

Find `vmrest.exe` in the installed Workstation directory. Read its installed help and the API documentation before selecting flags. Configure API authentication using its interactive `-C` flow when supported; handle real credentials privately. Store the API values only in the private `.env` with restrictive access.

Run vmrest on the Windows host under the account whose VM inventory it must manage. Confirm the actual listening address/port using `Get-NetTCPConnection`, and identify the owning process. In mirrored mode prefer a Windows loopback listener reachable from WSL at `http://127.0.0.1:8697/api`. Do not expose Basic-auth HTTP to the LAN to solve a loopback issue.

From WSL, first probe without credentials:

```bash
curl --max-time 8 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8697/api/vms
```

HTTP 401 demonstrates reachability and an authentication requirement. HTTP 000/timeouts do not. Next verify authenticated `GET /api/vms` using the private `.env` without printing credentials or enabling shell tracing. Avoid passing credentials in command-line arguments when implementing a reusable client; load them inside a Python API client and construct the Authorization header in memory.

For NAT WSL, do not assume localhost reaches Windows. Discover the Windows-facing route and implement the narrowest necessary API bridge/bind/firewall configuration, documenting its authentication and exposure. Never apply a broad LAN rule to an unauthenticated endpoint.

vmrest must start at Windows **boot, before any logon**. Install it with `windows/install-vmrest-task.ps1` from an elevated PowerShell: task `VMware vmrest API`, boot trigger, S4U as the Windows user who ran `vmrest.exe -C`, no time limit, restart 5 times 1 minute apart, running an administrator-only copy of `start-vmrest.ps1` in `%ProgramFiles%\wsl-vmware-lab`; `start-vmrest.ps1` stays running while vmrest runs so the restart policy applies. If another tool already registered a vmrest task, disable it (do not delete) so only one launcher remains. Acceptance: reboot, then confirm with nobody logged on (`quser` reports no users) that `curl` from WSL gets HTTP 401. A logon-triggered start is not acceptable.

Store the scripts' copy of the vmrest account in `%USERPROFILE%\.env` as `VMWS_USERNAME=` and `VMWS_PASSWORD=` lines: the user writes the same values given to `vmrest.exe -C`, and keeps the file readable only by their own Windows account. Never type these values for the user. `bash preflight.sh` then confirms authenticated HTTP 200 and checks the file permissions. Windows Credential Manager does not work here: it is locked in the no-logon boot session.

## 6. Install Linux automation tools

Use HashiCorp's official Ubuntu apt instructions, including its signing key and signed repository, to install the selected Terraform CLI version. Do not replace these with an unverified shell installer. Use Ubuntu packages or the current official Ansible installation guide to select a compatible Ansible version.

```bash
sudo apt-get install -y ansible python3 qemu-utils cloud-image-utils genisoimage openssh-client curl ca-certificates gnupg
terraform version
ansible --version
qemu-img --version
cloud-localds --help
```

Versions verified on the original lab: Terraform 1.17.1, Ansible 2.16.3, provider `elsudano/vmworkstation` 2.0.1. These commands assume the package repositories have already been prepared; Terraform is installed in the preceding official apt step. Record exact installed versions. Ansible runs in WSL as the control node; native Windows is not the control-node target of this architecture.

## 7. Prepare portable project files and a base VM

Use this repository as the source. Have the user write the vmrest account into `%USERPROFILE%\.env`, copy `lab.env.example` to `lab.env` only if a default must change, and review each script before first use. Never copy credentials, private keys, state, inventory or VM disks from another host as installation assets.

The repository implements the following artifacts. If you rebuild them elsewhere, keep this behavior:

| Artifact | Required behavior |
| --- | --- |
| `terraform/main.tf`, `variables.tf` | Pin `elsudano/vmworkstation` 2.0.1 for reproducing the tested example; endpoint includes `/api`; explicit base and unique clone name/path; 2 vCPU and 2048 MB test RAM if resources permit |
| Base preparation scripts | Verify official Ubuntu 24.04 amd64 cloud-image checksum; extract/convert VMDK; generate VMX and base seed; register VMX via API without GUI |
| Registration client | Authenticated `POST /api/vms/registration`; first list inventory and match normalized Windows path to avoid duplicate registration |
| `bootstrap-guest.sh` | While clone is OFF, attach per-clone cloud-init ISO on Windows storage and configure NAT plus host-only management NIC |
| `terraform-vm.sh` | Initialize; apply OFF for initial creation/bootstrap, then ON; explicit OFF/status; cleanup-aware destroy |
| `guest-inventory.py` | Read state VMX path, management MAC and DHCP leases; select the current lease on the management subnet; pin the guest-reported SSH host key; write private inventory |
| `guest-proxy.sh`, `tcp-relay.ps1` | Optional per-connection Windows TCP relay if WSL cannot reach the management subnet |
| `configure-guest.sh`, Ansible playbook | Wait for SSH/cloud-init; install nginx; deploy fixed test page; enable service; assert HTTP 200 and expected content; support idempotent rerun |
| Cleanup helper | After successful destroy, remove only the recorded clone seed ISO and verified empty clone directory; preserve base |

Download Ubuntu cloud images only from the official Ubuntu cloud-image service. Verify SHA256 against the official manifest; verify the manifest signature when tooling permits. A checksum downloaded from an unrelated mirror is not evidence of provenance.

Create an unencrypted SSH key only if appropriate for this local automation scope; protect its private file and directory permissions. Cloud-init must keep the image's default user (`users: [default]`), authorize the public key for it, disable root/password SSH as intended, and enable DHCP. For the guest NIC type, the tested older VMX used `e1000`; do not assume `e1000e` fits an incompatible virtual PCI layout.

Prepare the base on Windows-accessible storage, register it through vmrest, boot it via the supported CLI, verify initialization completion and shut it down before cloning. Do not treat a fixed sleep as proof of cloud-init completion. Avoid embedding per-clone instance IDs in the reusable base. Record the base API ID and preserve it during later cleanup.

For the tested provider schema, use `vmworkstation_virtual_machine`, `sourceid` and `denomination`, with a nonempty description. Validate the pinned schema instead of guessing names from another provider. Use a custom VMnet8/NAT mapping consistent with the discovered host to avoid the historical NIC recreation failure. Terraform may invoke bootstrap through `terraform_data` and `local-exec`; this remains a Terraform infrastructure step, not an Ansible call to Terraform.

## 8. Run isolated acceptance tests

Create a unique clone name, Windows VM directory and Terraform state. Never test destroy against a preexisting shared state. Give each agent its own private inventory/known-host paths, or serialize use of shared paths with a lock. Copying only Terraform source is insufficient if helper scripts still write a global inventory file.

Implement a cleanup trap before creating resources. Preserve any shared inventory, save logs privately, and always attempt cleanup of the isolated clone on failure. Verify cleanup errors rather than swallowing them. Do not remove the base or unrelated resources.

Run the prepared project's commands, adapting filenames if implementation differs:

```bash
./lab up
./lab configure
./lab configure
./lab down
./lab destroy
```

For an explicitly authorized disposable test, the wrapper can accept Terraform's `-auto-approve -input=false` destroy arguments. Review the state target first. Use bounded waits and report failures precisely.

Required evidence:

- Authenticated API inventory and base registration succeed without GUI VM creation.
- New clone appears in API inventory and reports powered on.
- Guest SSH and cloud-init finish; nginx page returns HTTP 200 with expected content.
- Second Ansible run reports `changed=0 unreachable=0 failed=0`.
- Power-off is confirmed by API, not only by a successful Terraform exit.
- Destruction removes the clone from API/state and removes VMX, VMDK, generated seed ISO and clone directory.
- Base and unrelated VM inventory/state remain unchanged.
- Original inventory is restored if temporarily shared.
- External SSH and WSL-to-vmrest access still work after the selected persistence test.

The existing lab needed `ANSIBLE_TIMEOUT=60` after a default 12-second privilege-escalation prompt timeout. A clone may expose an inherited SSH key before cloud-init regenerates it; recreating the same clone path may also reuse the VM ID/IP and old known-host filename. Verify the intended clone via API path and management MAC/lease before removing only its stale known-host entry. Never solve this by globally disabling host verification. Distinguish a stale-entry problem from a guest that never started SSH.

## 9. Computer-use protocol and failure handling

Capture the current screen before interacting. Identify controls by visible text/accessibility information rather than assuming fixed coordinates. Inspect each resulting screen before continuing. Avoid recording authentication fields. Save non-secret screenshots of installed versions, selected VMware networks and the running disposable VM only when useful.

For UAC, login, firmware or restart blockers, state the exact required human action and the checkpoint to resume. For package or API failures, inspect command exit status and logs first. Do not repeatedly rerun an installer, regenerate the base or reset networks as a generic repair.

If SSH drops, recover through the Windows console and inspect the selected distribution, foreground sshd task and mode-specific firewall/portproxy. If API times out, inspect Windows vmrest process/listener and account before touching Terraform. If creation fails, distinguish API/authentication/schema/base-registration/NIC errors. On every failure, attempt scoped clone cleanup and report anything left behind.

## 10. Handoff deliverables

Produce an English machine-specific runbook, source-file manifest, pinned dependency versions, fake-only `.env.example`, non-secret checkpoint and test report. Record exact commands, exit results, API/power observations, Ansible recaps, cleanup checks and log locations. State which persistence/reboot scenarios were actually tested. Include recovery instructions and remaining limitations.

Do not report the installation as verified unless the acceptance tests passed. This installation document itself has not been executed end-to-end on a clean Windows machine; its workflow combines official installation guidance with the separately tested existing lab lifecycle.

## Official references

- WSL commands and web update: https://learn.microsoft.com/en-us/windows/wsl/basic-commands
- WSL installation: https://learn.microsoft.com/en-us/windows/wsl/install
- WSL networking, mirrored mode and Hyper-V firewall: https://learn.microsoft.com/en-us/windows/wsl/networking
- WSL configuration: https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- VMware download and licensing instructions: https://knowledge.broadcom.com/external/article/368667/download-and-license-free-vmware-desktop.html
- Workstation API: https://developer.broadcom.com/xapis/vmware-workstation-pro-api/latest/
- Terraform installation: https://developer.hashicorp.com/terraform/install
- Workstation provider source/schema: https://github.com/elsudano/terraform-provider-vmworkstation
- Ansible installation: https://docs.ansible.com/projects/ansible/latest/installation_guide/intro_installation.html
- Windows/WSL Ansible control-node guidance: https://docs.ansible.com/projects/ansible/latest/os_guide/intro_windows.html
- Ubuntu cloud images: https://cloud-images.ubuntu.com/noble/current/

The Workstation provider is a third-party integration, not a HashiCorp/Broadcom-maintained provider. Recheck its pinned version and installed Workstation API compatibility before using a different release.
