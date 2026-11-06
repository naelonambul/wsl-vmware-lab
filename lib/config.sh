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
  # shellcheck disable=SC1090
  source "$LAB_ENV_FILE"
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
export LAB_NAT_VNET="${LAB_NAT_VNET:-VMnet8}"
export LAB_MGMT_VNET="${LAB_MGMT_VNET:-VMnet1}"
export LAB_BASE_NAME="${LAB_BASE_NAME:-ubuntu24-base}"
export LAB_BASE_DIR="${LAB_BASE_DIR:-$LAB_PROJECT_DIR/base}"
export LAB_CLONE_NAME="${LAB_CLONE_NAME:-ubuntu24-demo}"
export LAB_CLONE_CPUS="${LAB_CLONE_CPUS:-2}"
export LAB_CLONE_MEMORY_MB="${LAB_CLONE_MEMORY_MB:-2048}"

LAB_WINDOWS_PROFILE="${LAB_WINDOWS_PROFILE:-$(lab_windows_profile)}"
export LAB_WINDOWS_PROFILE
if [[ -z "${LAB_CLONE_VMX_WIN:-}" && -n "$LAB_WINDOWS_PROFILE" ]]; then
  LAB_CLONE_VMX_WIN="${LAB_WINDOWS_PROFILE}\\Documents\\Virtual Machines\\${LAB_CLONE_NAME}\\${LAB_CLONE_NAME}.vmx"
fi
export LAB_CLONE_VMX_WIN="${LAB_CLONE_VMX_WIN:-}"

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
  : "${LAB_CLONE_VMX_WIN:?Could not detect the Windows profile; set LAB_CLONE_VMX_WIN in lab.env}"
  export TF_VAR_vmrest_endpoint="$VMWS_ENDPOINT"
  export TF_VAR_vmrest_username="$VMWS_USERNAME"
  export TF_VAR_vmrest_password="$VMWS_PASSWORD"
  export TF_VAR_base_name="$LAB_BASE_NAME"
  export TF_VAR_clone_name="$LAB_CLONE_NAME"
  export TF_VAR_clone_vmx_path="$LAB_CLONE_VMX_WIN"
  export TF_VAR_clone_processors="$LAB_CLONE_CPUS"
  export TF_VAR_clone_memory_mb="$LAB_CLONE_MEMORY_MB"
}
