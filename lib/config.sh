# Shared settings loader. Source it from bash scripts in this repository:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
# Optional settings come from lab.env (gitignored; template lab.env.example).
# The vmrest account comes from a secrets file in the Windows user folder
# (default %USERPROFILE%\.env), read on demand by lab_require_credentials.
# Do not enable `set -x` while this file runs: it handles the vmrest password.

LAB_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_PROJECT_DIR

LAB_ENV_FILE="${LAB_ENV_FILE:-$LAB_PROJECT_DIR/lab.env}"
if [[ -f "$LAB_ENV_FILE" ]]; then
  # Strip CR so a lab.env saved with Windows (CRLF) line endings does not put
  # "\r" into VM names (VMX syntax error, vmrest HTTP 500 on registration).
  # shellcheck disable=SC1090
  source <(tr -d '\r' < "$LAB_ENV_FILE")
fi

# Windows user profile of the logged-in Windows account, as a Windows path.
# Prints nothing (and never fails) when Windows interop is unavailable, so
# scripts running under `set -euo pipefail` reach the explicit errors below.
lab_windows_profile() {
  local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [[ -x "$ps" ]] || return 0
  "$ps" -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' \
    2>/dev/null | tr -d '\r' || true
}

export VMWS_ENDPOINT="${VMWS_ENDPOINT:-http://127.0.0.1:8697/api}"
export VMWARE_DIR="${VMWARE_DIR:-/mnt/c/Program Files/VMware/VMware Workstation}"
export LAB_PRIVATE_DIR="${LAB_PRIVATE_DIR:-$HOME/.config/wsl-vmware-lab}"
export LAB_SSH_KEY="${LAB_SSH_KEY:-$LAB_PRIVATE_DIR/lab_ed25519}"
export LAB_INVENTORY="${LAB_INVENTORY:-$LAB_PRIVATE_DIR/inventory.json}"
export LAB_DHCP_LEASES="${LAB_DHCP_LEASES:-/mnt/c/ProgramData/VMware/vmnetdhcp.leases}"
export LAB_DHCP_CONF="${LAB_DHCP_CONF:-/mnt/c/ProgramData/VMware/vmnetdhcp.conf}"
export LAB_NAT_VNET="${LAB_NAT_VNET:-VMnet8}"
export LAB_MGMT_VNET="${LAB_MGMT_VNET:-VMnet1}"
export LAB_BASE_NAME="${LAB_BASE_NAME:-ubuntu24-base}"
export LAB_BASE_DIR="${LAB_BASE_DIR:-$LAB_PROJECT_DIR/base}"
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

# Parse KEY=VALUE lines without executing the file (it may belong to other
# tools too). Accepts an `export ` prefix and single or double quotes.
# Reads VMWS_USERNAME (or VMWS_USER) and VMWS_PASSWORD only.
# Returns 0 when both are found, 3 when the file is missing, 4 when incomplete.
lab_load_secrets_file() {
  local file="$1" line key value user="" pass=""
  [[ -n "$file" && -f "$file" ]] || return 3
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(VMWS_USERNAME|VMWS_USER|VMWS_PASSWORD)[[:space:]]*=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) || ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      VMWS_USERNAME) user="$value" ;;
      VMWS_USER) [[ -n "$user" ]] || user="$value" ;;
      VMWS_PASSWORD) pass="$value" ;;
    esac
  done < "$file"
  [[ -n "$user" && -n "$pass" ]] || return 4
  VMWS_USERNAME="$user"
  VMWS_PASSWORD="$pass"
  VMWS_CREDENTIAL_SOURCE="secrets file $file"
  export VMWS_USERNAME VMWS_PASSWORD
}

# Lookup order: environment (or lab.env) -> LAB_SECRETS_FILE.
lab_require_credentials() {
  if [[ -n "${VMWS_USERNAME:-}" && -n "${VMWS_PASSWORD:-}" ]]; then
    VMWS_CREDENTIAL_SOURCE="${VMWS_CREDENTIAL_SOURCE:-environment or lab.env}"
  else
    local rc=0
    lab_load_secrets_file "$LAB_SECRETS_FILE" || rc=$?
    if [[ $rc -ne 0 ]]; then
      if [[ -z "$LAB_SECRETS_FILE" ]]; then
        echo "vmrest account: no secrets file location (Windows profile not detected); set LAB_SECRETS_FILE" >&2
      elif [[ $rc -eq 3 ]]; then
        echo "vmrest account: $LAB_SECRETS_FILE not found." >&2
        echo "  The user creates it with VMWS_USERNAME=... and VMWS_PASSWORD=... (the vmrest.exe -C account)." >&2
      else
        echo "vmrest account: $LAB_SECRETS_FILE lacks VMWS_USERNAME (or VMWS_USER) / VMWS_PASSWORD." >&2
      fi
      return 1
    fi
  fi
  export VMWS_USERNAME VMWS_PASSWORD VMWS_CREDENTIAL_SOURCE
}

# curl config line for basic auth, read by `curl -K -` from stdin so the
# password never appears in the process list. Escapes \ and " for curl.
lab_curl_auth() {
  local u="${VMWS_USERNAME//\\/\\\\}" p="${VMWS_PASSWORD//\\/\\\\}"
  u="${u//\"/\\\"}"; p="${p//\"/\\\"}"
  printf 'user = "%s:%s"\n' "$u" "$p"
}

lab_terraform_env() {
  lab_require_credentials
  : "${LAB_VM_ROOT_WIN:?Could not detect the Windows profile; set LAB_VM_ROOT_WIN in lab.env}"
  export TF_VAR_vmrest_endpoint="$VMWS_ENDPOINT"
  export TF_VAR_vmrest_username="$VMWS_USERNAME"
  export TF_VAR_vmrest_password="$VMWS_PASSWORD"
  export TF_VAR_base_name="$LAB_BASE_NAME"
  export TF_VAR_vm_root_win="$LAB_VM_ROOT_WIN"
  # Default single VM; a vms.tfvars passed with -var-file overrides it.
  TF_VAR_vms=$(printf '{"%s":{"processors":%d,"memory_mb":%d,"groups":["demo"]}}' \
    "$LAB_CLONE_NAME" "$LAB_CLONE_CPUS" "$LAB_CLONE_MEMORY_MB")
  export TF_VAR_vms
  LAB_TF_VAR_ARGS=()
  if [[ -f "$LAB_VMS_FILE" ]]; then
    LAB_TF_VAR_ARGS=(-var-file="$LAB_VMS_FILE")
  elif [[ "$LAB_VMS_FILE_EXPLICIT" == 1 ]]; then
    echo "[ERROR] LAB_VMS_FILE is set but $LAB_VMS_FILE does not exist." >&2
    echo "        Fix the path, or unset LAB_VMS_FILE to use the single default VM $LAB_CLONE_NAME." >&2
    return 1
  fi
}

# Confirm the base VM before Terraform clones it (check-base.py) and pass its
# identity to Terraform: TF_VAR_base_id makes the plan stop if the provider's
# name lookup finds another VM, and TF_VAR_base_prepared (a hash of the
# base's prepared marker, new with every ./lab setup --recreate) makes the
# plan replace clones of an older base. Run after lab_terraform_env.
lab_base_identity() {
  local prepared="$LAB_BASE_DIR/ubuntu-base.prepared" id
  if [[ ! -f "$prepared" ]]; then
    echo "[ERROR] The base is not prepared ($prepared is missing). Run: ./lab setup" >&2
    echo "        (A base prepared by an older version that works: touch \"$prepared\")" >&2
    return 1
  fi
  id=$(python3 "$LAB_PROJECT_DIR/check-base.py" "$LAB_BASE_DIR/ubuntu-base.vmx" "$LAB_BASE_NAME") || return 1
  export TF_VAR_base_id="$id"
  TF_VAR_base_prepared=$(sha256sum < "$prepared" | cut -d' ' -f1)
  export TF_VAR_base_prepared
}

# Windows path compared case-insensitively, with / and \ treated alike.
lab_norm_win_path() { local p="${1//\//\\}"; printf '%s' "${p,,}"; }

# Is the VM with this Windows VMX path running? Exit status: 0 running,
# 1 not running, 2 unknown (vmrun failed or answered unexpectedly; reason on
# stderr). Callers must treat 2 as "do not touch the VM".
lab_vm_running() {
  local target out line
  target=$(lab_norm_win_path "$1")
  if ! out=$("${VMWARE_DIR}/vmrun.exe" -T ws list 2>&1); then
    echo "vmrun could not list running VMs: ${out//$'\r'/}" >&2
    return 2
  fi
  out=${out//$'\r'/}
  if [[ "$(head -n 1 <<<"$out")" != 'Total running VMs: '* ]]; then
    echo "unexpected vmrun list output: $(head -n 1 <<<"$out")" >&2
    return 2
  fi
  while IFS= read -r line; do
    [[ -n "$line" && "$(lab_norm_win_path "$line")" == "$target" ]] && return 0
  done < <(tail -n +2 <<<"$out")
  return 1
}
