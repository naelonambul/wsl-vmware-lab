# shellcheck shell=bash
# Shared settings loader. Source it from bash scripts in this repository:
#   source "$LAB_PROJECT_DIR/lib/config.sh" (scripts in lib/: source "$(dirname "${BASH_SOURCE[0]}")/config.sh")
# Optional settings come from lab.env (gitignored; template lab.env.example).
# The vmrest account comes from a secrets file in the Windows user folder
# (default %USERPROFILE%\.env), read on demand by lab_require_credentials.
# Do not enable `set -x` while this file runs: it handles the vmrest password.

LAB_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_PROJECT_DIR

# shellcheck source=lib/config-functions.sh
source "$LAB_PROJECT_DIR/lib/config-functions.sh"

# The entry point needs result functions without loading host configuration.
[[ "${LAB_ENTRY_ONLY:-0}" != 1 ]] || return 0

LAB_ENV_FILE="${LAB_ENV_FILE:-$LAB_PROJECT_DIR/lab.env}"
if [[ -f "$LAB_ENV_FILE" ]]; then
  # Strip CR so a lab.env saved with Windows (CRLF) line endings does not put
  # "\r" into VM names (VMX syntax error, vmrest HTTP 500 on registration).
  # shellcheck disable=SC1090
  lab_env_text=$(tr -d '\r' < "$LAB_ENV_FILE") || lab_fail config_error 'Cannot read LAB_ENV_FILE.'
  # Enable extglob because syntax checks do not execute lab.env's shopt commands.
  if ! bash -O extglob -n <<< "$lab_env_text" 2>/dev/null; then
    unset lab_env_text
    lab_fail config_error 'lab.env has a shell syntax error; check it yourself with: bash -n lab.env'
  fi
  source /dev/stdin <<< "$lab_env_text"
  unset lab_env_text
fi

# VMnet0 is Workstation's implicit bridged network; custom VMnets are 0-19.
# Validate before profile discovery or any command can touch the host.
export LAB_NAT_VNET="${LAB_NAT_VNET:-VMnet8}"
export LAB_MGMT_VNET="${LAB_MGMT_VNET:-VMnet1}"
export LAB_LAN_VNET="${LAB_LAN_VNET:-}"
if [[ -n "$LAB_LAN_VNET" && ! "$LAB_LAN_VNET" =~ ^VMnet([0-9]|1[0-9])$ ]]; then
  lab_fail config_error 'LAB_LAN_VNET must be empty or VMnet0 through VMnet19.'
fi
if [[ "${LAB_LAN_VNET:-VMnet0}" == "$LAB_NAT_VNET" || "${LAB_LAN_VNET:-VMnet0}" == "$LAB_MGMT_VNET" ]]; then
  lab_fail config_error 'The effective LAN VMnet must differ from LAB_NAT_VNET and LAB_MGMT_VNET.'
fi

export VMWS_ENDPOINT="${VMWS_ENDPOINT:-http://127.0.0.1:8697/api}"
export VMWARE_DIR="${VMWARE_DIR:-/mnt/c/Program Files/VMware/VMware Workstation}"
export LAB_PRIVATE_DIR="${LAB_PRIVATE_DIR:-$HOME/.config/wsl-vmware-lab}"
export LAB_SSH_KEY="${LAB_SSH_KEY:-$LAB_PRIVATE_DIR/lab_ed25519}"
export LAB_INVENTORY="${LAB_INVENTORY:-$LAB_PRIVATE_DIR/inventory.json}"
export LAB_DHCP_LEASES="${LAB_DHCP_LEASES:-/mnt/c/ProgramData/VMware/vmnetdhcp.leases}"
export LAB_DHCP_CONF="${LAB_DHCP_CONF:-/mnt/c/ProgramData/VMware/vmnetdhcp.conf}"
export LAB_BASE_DIR="${LAB_BASE_DIR:-$LAB_PROJECT_DIR/base}"
# Guest image of VMs that do not name one in vms.tfvars (lib/base.sh lists the
# supported images). Each image in use has its own base: VM "<image>-base",
# files in base/<image>/.
export LAB_IMAGE="${LAB_IMAGE:-ubuntu-24.04}"
# Guest user created in every clone by cloud-init (lib/cloud-config.sh). Fixed,
# not a setting: inventories of existing VMs depend on it.
export LAB_GUEST_USER=lab
# Default VM set when no vms.tfvars exists: one VM with these values.
export LAB_CLONE_NAME="${LAB_CLONE_NAME:-ubuntu24-demo}"
export LAB_CLONE_CPUS="${LAB_CLONE_CPUS:-2}"
export LAB_CLONE_MEMORY_MB="${LAB_CLONE_MEMORY_MB:-2048}"
# Several VMs (a whole system): Terraform var file with `vms = { ... }`.
# Set explicitly (environment or lab.env)? Then a missing file is an error, not
# the single-VM fallback (lab_terraform_env).
if [[ -n "${LAB_VMS_FILE:-}" ]]; then LAB_VMS_FILE_EXPLICIT=1; else LAB_VMS_FILE_EXPLICIT=0; fi
LAB_VMS_FILE="${LAB_VMS_FILE:-$LAB_PROJECT_DIR/vms.tfvars}"
[[ "$LAB_VMS_FILE" == /* ]] || LAB_VMS_FILE="$LAB_PROJECT_DIR/$LAB_VMS_FILE"
export LAB_VMS_FILE

LAB_WINDOWS_PROFILE="${LAB_WINDOWS_PROFILE:-$(lab_windows_profile)}"
export LAB_WINDOWS_PROFILE
# Windows folder holding one folder per clone (<root>\<name>\<name>.vmx).
if [[ -z "${LAB_VM_ROOT_WIN:-}" && -n "${LAB_CLONE_VMX_WIN:-}" ]]; then
  # Older lab.env: derive the root from the single clone's VMX path.
  LAB_VM_ROOT_WIN="${LAB_CLONE_VMX_WIN%\\*}"; LAB_VM_ROOT_WIN="${LAB_VM_ROOT_WIN%\\*}"
fi
if [[ -z "${LAB_VM_ROOT_WIN:-}" && -n "$LAB_WINDOWS_PROFILE" ]]; then
  LAB_VM_ROOT_WIN="${LAB_WINDOWS_PROFILE}\\Documents\\Virtual Machines"
fi
export LAB_VM_ROOT_WIN="${LAB_VM_ROOT_WIN:-}"

# Secrets file holding the vmrest account (the one created with vmrest.exe -C).
# Default: .env in the Windows user folder, protected by that folder's NTFS
# permissions and readable whether or not anyone is logged on.
# Order: LAB_SECRETS_FILE if set; else the older blog setup's vmrest.env when
# VMWS_CREDENTIALS_FILE points to it; else %USERPROFILE%\.env.
if [[ -z "${LAB_SECRETS_FILE:-}" && -n "${VMWS_CREDENTIALS_FILE:-}" ]]; then
  LAB_SECRETS_FILE="$VMWS_CREDENTIALS_FILE"
fi
if [[ -z "${LAB_SECRETS_FILE:-}" && -n "$LAB_WINDOWS_PROFILE" ]]; then
  LAB_SECRETS_FILE="$(wslpath -u "$LAB_WINDOWS_PROFILE")/.env"
fi
export LAB_SECRETS_FILE="${LAB_SECRETS_FILE:-}"
VMWS_CREDENTIAL_SOURCE="${VMWS_CREDENTIAL_SOURCE:-}"
