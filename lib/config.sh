# Shared settings loader. Source it from bash scripts in this repository:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
# Values come from lab.env (gitignored). Copy lab.env.example to start.
# Do not enable `set -x` while this file runs: lab.env holds the vmrest password.

LAB_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export LAB_PROJECT_DIR

LAB_ENV_FILE="${LAB_ENV_FILE:-$LAB_PROJECT_DIR/lab.env}"
if [[ -f "$LAB_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LAB_ENV_FILE"
fi
# Older posts stored credentials in vmrest.env; still honoured if present.
if [[ -n "${VMWS_CREDENTIALS_FILE:-}" && -f "$VMWS_CREDENTIALS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$VMWS_CREDENTIALS_FILE"
fi

# Windows user profile of the logged-in Windows account, as a Windows path.
# Prints nothing (and never fails) when Windows interop is unavailable, so
# scripts running under `set -euo pipefail` reach the explicit error below.
lab_windows_profile() {
  local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [[ -x "$ps" ]] || return 0
  "$ps" -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' \
    2>/dev/null | tr -d '\r' || true
}

export VMWS_ENDPOINT="${VMWS_ENDPOINT:-http://127.0.0.1:8697/api}"
export VMWARE_DIR="${VMWARE_DIR:-/mnt/c/Program Files/VMware/VMware Workstation}"
export LAB_PRIVATE_DIR="${LAB_PRIVATE_DIR:-$HOME/.config/wsl-vmware-lab}"
export LAB_GUEST_USER="${LAB_GUEST_USER:-ubuntu}"
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
if [[ -z "${LAB_CLONE_VMX_WIN:-}" ]]; then
  _lab_profile="$(lab_windows_profile)"
  if [[ -n "$_lab_profile" ]]; then
    LAB_CLONE_VMX_WIN="${_lab_profile}\\Documents\\Virtual Machines\\${LAB_CLONE_NAME}\\${LAB_CLONE_NAME}.vmx"
  fi
  unset _lab_profile
fi
export LAB_CLONE_VMX_WIN="${LAB_CLONE_VMX_WIN:-}"

# vmrest account lookup order: environment / lab.env, then Windows Credential
# Manager (generic credential LAB_CREDENTIAL_TARGET, stored by
# windows/vmrest-credential.ps1 Set). Values stay in this process's memory.
export LAB_CREDENTIAL_TARGET="${LAB_CREDENTIAL_TARGET:-wsl-vmware-lab/vmrest}"
VMWS_CREDENTIAL_SOURCE="${VMWS_CREDENTIAL_SOURCE:-}"

# Returns 0 and sets VMWS_USERNAME/VMWS_PASSWORD when found; 3 = no entry;
# other non-zero = Credential Manager unreachable (no interop, or this logon
# session cannot read the user's credentials).
lab_load_windows_credential() {
  local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe out rc
  [[ -x "$ps" ]] || return 2
  # No pipe here: the exit code must come from powershell.exe itself.
  out="$("$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$LAB_PROJECT_DIR/windows/vmrest-credential.ps1")" Get \
    -Target "$LAB_CREDENTIAL_TARGET" 2>/dev/null)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || return "$rc"
  out="${out//$'\r'/}"
  VMWS_USERNAME="$(sed -n 1p <<<"$out" | base64 -d)"
  VMWS_PASSWORD="$(sed -n 2p <<<"$out" | base64 -d)"
  [[ -n "$VMWS_USERNAME" ]] || return 4
  VMWS_CREDENTIAL_SOURCE="Windows Credential Manager ($LAB_CREDENTIAL_TARGET)"
  export VMWS_USERNAME VMWS_PASSWORD
}

lab_require_credentials() {
  if [[ -n "${VMWS_USERNAME:-}" && -n "${VMWS_PASSWORD:-}" ]]; then
    VMWS_CREDENTIAL_SOURCE="${VMWS_CREDENTIAL_SOURCE:-environment or settings file}"
  else
    local rc=0
    lab_load_windows_credential || rc=$?
    if [[ $rc -ne 0 ]]; then
      if [[ $rc -eq 3 ]]; then
        echo "vmrest account not found. Store it once on Windows:" >&2
      else
        echo "vmrest account: Windows Credential Manager not readable here (code $rc)." >&2
      fi
      echo "  powershell.exe -NoProfile -File \"$(wslpath -w "$LAB_PROJECT_DIR/windows/vmrest-credential.ps1" 2>/dev/null)\" Set" >&2
      echo "  (or set VMWS_USERNAME / VMWS_PASSWORD in lab.env)" >&2
      return 1
    fi
  fi
  export VMWS_USERNAME VMWS_PASSWORD VMWS_CREDENTIAL_SOURCE
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
