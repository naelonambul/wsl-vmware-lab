# Operating an existing lab host

Use the existing configured WSL and guest accounts. Discover host-specific paths
from status; never copy values from examples. Do not create/delete guest accounts
or change SSH authorization unless the user explicitly requests that change.

## Start here

1. Read [network.md](network.md); run `./lab network` before setup or any up.
   It needs no vmrest or credentials; with state present it uses Terraform
   show JSON. Record role, subnet, DHCP/NAT/forward and bridge evidence privately.
2. Run `./lab status` and require exit 0 before lifecycle work. Match errors
   using [../SKILL.md](../SKILL.md), section 0, then [pitfalls.md](pitfalls.md).
3. Preserve existing bases, clones, state and foreign host setup. Changes need
   the user's authorization; network inspection does not authorize Windows Install.
4. For distributed services, first write the version-specific procedure required
   by [distributed-systems.md](distributed-systems.md). No record, no configure/start.

Use Bash inside WSL, not Windows Git Bash/MSYS. Windows tools need absolute paths
in remote WSL sessions: PowerShell is
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`; VMware tools
are under `VMWARE_DIR`. Use `wslpath -w` for Windows arguments and `wslpath -u`
for Windows paths read in WSL.

## Defaults and responsibilities

| Item | Default / configuration |
|---|---|
| VM list | Root `vms.tfvars` (`LAB_VMS_FILE`); absent implicit file falls back to `LAB_CLONE_NAME`. An explicit missing file fails. |
| Clone VMX | `<LAB_VM_ROOT_WIN>\<name>\<name>.vmx`; root defaults to the Windows profile's Documents/Virtual Machines. |
| Base | `base/<image>/base.vmx`, registered as `<image>-base`; `LAB_BASE_DIR` overrides the directory. Never boot it. |
| Private files | `$HOME/.config/wsl-vmware-lab` (`LAB_PRIVATE_DIR`): key pair, inventory, pinned host keys and seeds. |
| Guest login | Fixed `lab` account created by cloud-init; no configurable guest username. |
| Networks | Default NAT VMnet8, management VMnet1, LAN bridged VMnet0; inspect actual roles first. |
| Credentials | `%USERPROFILE%\.env` (`LAB_SECRETS_FILE`); `VMWS_USERNAME`/`VMWS_USER` and `VMWS_PASSWORD`, parsed without executing the file. |

Terraform owns VM existence, hardware and power; bootstrap writes the powered-off
clone's seed and NICs. Ansible runs the user's playbooks over the management NIC,
directly or through `guest-proxy.sh` / `windows/tcp-relay.ps1`. LAN services
between PCs use `lan0`, with DHCP or optional `lan_ip`; NAT remains the internet route.

Never print/copy secrets, private keys, state or generated inventory into chat,
logs or commits. Never enable `set -x` during configuration loading. The user
runs `./lab account` in their terminal; agents never type the password.

## Command results and routine operations

`./lab describe --json` returns the authoritative command/error reference in
`data`. Every command emits one JSON envelope on stdout; diagnostics go to stderr.
Status is diagnostic: exit 0 / `ok: true` can coexist with unknown power or LAN mismatches. Read `data.vms` and `warnings` (`vm_power_unknown`, `lan_vnet_mismatch`) to assess each VM.
Read `ok` and `error`; `changed` means an attempted mutation, possibly partial.

```bash
./lab network
./lab status
./lab status --start-vmrest      # only when authorized to start the existing task
./lab up --dry-run              # preview; needs initialized Terraform/providers
./lab up                        # create/bootstrap new or replacement VMs off
./lab up --all                  # start all; no ordering guarantee
./lab up <vm>                   # one ordered step; preserve other live power
./lab configure ansible/check-lab.yml
./lab configure <project-playbook>
./lab configure --limit db      # default playbook; readiness still covers running set
./lab down <vm>                 # graceful ordered step
./lab down --all                # graceful whole checkout
./lab down <vm> --hard --dry-run # review exact selection/options first
./lab down <vm> --hard          # explicit user-approved hard stop
./lab destroy --confirm=<names> --dry-run # matching preview; confirmation optional only for preview
./lab destroy --confirm=<names> # exact distinct comma-separated state VM set
./lab cleanup                   # replay pending cleanup/record restoration
```

Before destructive `up --allow-destroy`, `down --hard`, or `destroy --confirm=<names>`, require and review `--dry-run` with the exact same selection and options (including `--allow-destroy`, `--hard`, and confirmation); remove only `--dry-run` for the real call. For example, preview `./lab up --all --allow-destroy --dry-run` before `./lab up --all --allow-destroy`. Only up/down/destroy support dry-run; setup (including `setup --recreate`), cleanup, configure, account, status, network and describe have no dry-run. For `setup --recreate`, review base/clone impact and obtain authorization without claiming a preview exists.

Up/down also support `--dry-run`. No apply, guest SSH, journal writes, cleanup
or state restoration occurs in a dry run; private scratch files are used.
Up requires known power for every state VM; down requires it for the selection.
All non-power VM in-place edits require power off: revert edits, down the VM,
restore edits and up. Off configuration reconciliation precedes selected start.
Removing/replacing VMs through up requires user-authorized `--allow-destroy`.
An authorized replacement loses the old disk and stays off unless selected.

Graceful down uses a private best-effort inventory, requests poweroff on reachable
guests and ignores SSH return codes; only vmrest confirms success. It polls every
5 s, up to `LAB_DOWN_WAIT_SECONDS` (120). A timeout is `guest_not_ready`;
ask before hard stop. Bare down is a usage error.

Destroy is non-interactive; free Terraform arguments are rejected. Names must
equal all state VM names (order independent, no duplicates). Empty state without
confirmation succeeds as a no-op. It journals deletions and cleans generated
files after VMX/disks disappear. Never use bare Terraform destroy.

Configure omits powered-off VMs, fails on unknown/API-error power and requires
at least one running host. The first running set is frozen across retries;
a later dropout remains unready. Groups contain running VMs only: define durable
cluster topology in project variables, even when using `--limit`.

## Implementation guide

| Path | Current role |
|---|---|
| `lab` / `lib/runner-functions.sh` | JSON envelope ownership, argument dispatch, checkout lock, mutation process-group signals. |
| `lib/config.sh` / `config-functions.sh` | Settings, credential loading, Terraform variables, structured result/error helpers. |
| `lib/lifecycle.sh` | State-instance selection, live-power seeds, saved plans/guards, create-off bootstrap, selected power, shutdown and deletion/cleanup. |
| `lib/power-map.py` / `plan-inspect.py` | State VM instances and live power; all-attribute VM update safety check. |
| `lib/bootstrap-records.py` / `cleanup-guest.py` | Durable missing bootstrap-record restoration and cleanup journal. |
| `lib/network.sh` / `network-inspect.py` | Windows/VMX evidence and LAN mismatch gate. |
| `lib/describe.json` / `envelope.py` | Command/error contract, stdout result and mutation/action metadata. |
| `lib/base.sh` / `bootstrap-guest.sh` | One unbooted base per image; powered-off clone seed/NICs and pinned host key; completed bootstrap cannot be repeated. |
| `lib/guest-inventory.py` / `configure.sh` | Running-host readiness and private inventory; project/default playbook execution. |
| `terraform/main.tf` / `variables.tf` | Per-image base lookup; per-name VM/bootstrap records; live-seeded `power_states` map defaults new VMs off. |
| `lib/preflight.sh` / `windows/setup.ps1` | Host checks / Windows Install, Status, Network, Remove actions. |

Lifecycle power, LAN and confirmation checks use VM instances in Terraform show
JSON, not possibly stale output `vms`. Configure guest inventory reads `terraform output -json vms`; the best-effort inventory used by down reads VM instances from `terraform show -json`.

## Network changes and recovery

`LAB_LAN_VNET` empty/VMnet0 means bridged; VMnet1–19 uses custom plus vnet.
Effective LAN must differ from NAT/management. Changing it never triggers clone
replacement; every up refuses existing LAN mismatches, even with
`--allow-destroy`. Down/status/network/configure/destroy remain available.
Follow [network.md](network.md) for user-chosen offline VMX repair; preserve the
LAN MAC and never re-bootstrap an existing disk. Base NAT changes require
user-approved base recreation plus rebuilt clones.

## Isolation and evidence

One checkout owns one state, VM set and inventory. Serialize runners or use fully
isolated state/settings/private directories and noncolliding VM names. Never
copy state for an experiment. Do not test destruction/reboots on an in-use host.

For partial starts/applies, inspect `./lab status`, report actual power and ask
before recovery. Follow the documented order per host; multi-name calls have no
ordering guarantee. After reboot verify status, LAN addresses, membership and
a fresh write/read. Report only observed evidence; historical checks do not
establish current behavior. See the repository `tests/README.md` for Linux-only
offline verification and fixture safety.
