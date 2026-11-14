# shellcheck shell=bash
# Shared definitions; sourcing this file performs no host discovery.

# Result records contain only explicitly selected public command metadata.
lab_result() {
  [[ -z "${LAB_RESULT_FILE:-}" ]] || python3 "$LAB_PROJECT_DIR/lib/envelope.py" data "$1" 3>&-
}

lab_fail() {
  local code="$1" message="$2" rc=1 details="${4:-}"
  [[ -n "$details" ]] || details='{}'
  case "$code" in
    usage_error|config_error|unknown_vm) rc=2 ;;
    secrets_missing|vmrest_auth|needs_user) rc=3 ;;
    lock_held|vmrest_unreachable) rc=4 ;;
    plan_destroy_refused|lan_vnet_mismatch|vm_power_unknown|config_change_requires_off) rc=5 ;;
  esac
  if [[ -n "${LAB_RESULT_FILE:-}" ]]; then
    python3 "$LAB_PROJECT_DIR/lib/envelope.py" fail "$code" "$message" "${3:-}" "$details" 3>&-
  fi
  printf '[ERROR] %s: %s\n' "$code" "$message" >&2
  [[ -z "${3:-}" ]] || printf '        %s\n' "$3" >&2
  exit "$rc"
}

lab_ansible_env() {
  export ANSIBLE_PIPELINING=true
  # The default 12 s privilege-escalation wait timed out on slower hosts.
  export ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-60}"
}

# Windows user profile of the logged-in Windows account, as a Windows path.
# Prints nothing (and never fails) when Windows interop is unavailable, so
# scripts running under `set -euo pipefail` reach the explicit errors below.
lab_windows_profile() {
  local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [[ -x "$ps" ]] || return 0
  # Discovery must not consume a piped Terraform destroy confirmation.
  "$ps" -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' \
    </dev/null 2>/dev/null | tr -d '\r' || true
}

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
      lab_fail secrets_missing "No usable vmrest credentials." "The user runs ./lab account, or sets LAB_SECRETS_FILE."
    fi
  fi
  export VMWS_USERNAME VMWS_PASSWORD VMWS_CREDENTIAL_SOURCE
}

# Who may open the secrets file: "private" (only your user, SYSTEM and
# Administrators; compared by SID so localized names do not matter),
# "open:<names>" or "error:<reason>". The path goes through the environment:
# powershell.exe -Command does not bind trailing arguments to param().
lab_secrets_acl() {
  local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  LAB_ACL_FILE="$(wslpath -w "$1")" WSLENV="LAB_ACL_FILE${WSLENV:+:$WSLENV}" \
    "$ps" -NoProfile -NonInteractive -Command '
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    try {
      $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      $allowed = @($me, "S-1-5-18", "S-1-5-32-544")
      $other = foreach ($a in (Get-Acl -LiteralPath $env:LAB_ACL_FILE -ErrorAction Stop).Access) {
        if ($a.AccessControlType -ne "Allow") { continue }
        try { $sid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sid = $null }
        if (-not $sid -or $allowed -notcontains $sid) { $a.IdentityReference.Value }
      }
      if ($other) { "open:" + (($other | Select-Object -Unique) -join ", ") } else { "private" }
    } catch { "error:" + $_.Exception.GetType().Name }' </dev/null 2>/dev/null | tr -d '\r' || true
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
  [[ -n "${LAB_VM_ROOT_WIN:-}" ]] || lab_fail config_error "Could not detect the Windows profile; set LAB_VM_ROOT_WIN in lab.env"
  export TF_VAR_vmrest_endpoint="$VMWS_ENDPOINT"
  export TF_VAR_vmrest_username="$VMWS_USERNAME"
  export TF_VAR_vmrest_password="$VMWS_PASSWORD"
  export TF_VAR_default_image="$LAB_IMAGE"
  export TF_VAR_vm_root_win="$LAB_VM_ROOT_WIN"
  # Default single VM; a vms.tfvars passed with -var-file overrides it.
  TF_VAR_vms=$(printf '{"%s":{"processors":%d,"memory_mb":%d,"groups":["demo"]}}' \
    "$LAB_CLONE_NAME" "$LAB_CLONE_CPUS" "$LAB_CLONE_MEMORY_MB")
  export TF_VAR_vms
  LAB_TF_VAR_ARGS=()
  if [[ -f "$LAB_VMS_FILE" ]]; then
    # shellcheck disable=SC2034 # read by the scripts that source this file
    LAB_TF_VAR_ARGS=(-var-file="$LAB_VMS_FILE")
  elif [[ "$LAB_VMS_FILE_EXPLICIT" == 1 ]]; then
    echo "[ERROR] LAB_VMS_FILE is set but $LAB_VMS_FILE does not exist." >&2
    echo "        Fix the path, or unset LAB_VMS_FILE to use the single default VM $LAB_CLONE_NAME." >&2
    lab_fail config_error "LAB_VMS_FILE does not exist." "Fix the path or unset LAB_VMS_FILE."
  fi
}


# Images the VM list uses: LAB_IMAGE (VMs without an image) and every
# image = "..." in vms.tfvars. Terraform validates the names.
lab_used_images() {
  {
    printf '%s\n' "$LAB_IMAGE"
    if [[ -f "$LAB_VMS_FILE" ]]; then tr -d '\r' < "$LAB_VMS_FILE" | sed -e 's/#.*//' \
      | sed -nE 's/.*(^|[^A-Za-z0-9_])image[[:space:]]*=[[:space:]]*"([^"]*)".*/\2/p'
    fi
  } | sort -u
}

# Confirm every base in use before Terraform clones it (check-base.py) and pass
# their identities to Terraform as TF_VAR_bases: the id makes the plan stop if
# the provider's name lookup finds another VM, and the hash of the base's
# prepared marker (new with every ./lab setup --recreate) makes the plan
# replace clones of an older base. Run after lab_terraform_env.
lab_base_identity() {
  local image images prepared digest id json='' sep=''
  images=$(lab_used_images) || return 1
  [[ -n "$images" ]] || return 1
  for image in $images; do
    prepared="$LAB_BASE_DIR/$image/base.prepared"
    if [[ ! -f "$prepared" ]]; then
      echo "[ERROR] No prepared base for image $image ($prepared is missing). Run: ./lab setup" >&2
      return 1
    fi
    id=$(python3 "$LAB_PROJECT_DIR/lib/check-base.py" "$LAB_BASE_DIR/$image/base.vmx" "$image-base") || return 1
    digest=$(sha256sum < "$prepared" | cut -d' ' -f1) || return 1
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
    json+=$(printf '%s"%s":{"id":"%s","prepared":"%s"}' "$sep" "$image" "$id" "$digest")
    sep=,
  done
  export TF_VAR_bases="{$json}"
}

# The LAN as "<network>/<prefix> <dev> <address>", e.g. "192.168.1.0/24 eth0
# 192.168.1.253": the network of the default route. With mirrored networking
# WSL shares Windows' addresses, so this is the LAN other PCs reach this one on
# (and windows/setup.ps1 detects the same).
lab_lan() {
  local dev cidr
  dev=$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }') || return 1
  [[ -n "$dev" ]] || return 1
  cidr=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{ print $4; exit }') || return 1
  [[ -n "$cidr" ]] || return 1
  python3 -c 'import ipaddress, sys; i = ipaddress.ip_interface(sys.argv[1]); print(i.network, sys.argv[2], i.ip)' "$cidr" "$dev"
}

# Windows path compared case-insensitively, with / and \ treated alike.
lab_norm_win_path() { local p="${1//\//\\}"; printf '%s' "${p,,}"; }

# Is the VM with this Windows VMX path running? Exit status: 0 running,
# 1 not running, 2 unknown (vmrun failed or answered unexpectedly; reason on
# stderr). Callers must treat 2 as "do not touch the VM".
lab_vm_running() {
  local target out line count listed=0 found=1
  target=$(lab_norm_win_path "$1")
  if ! out=$(timeout 60 "${VMWARE_DIR}/vmrun.exe" -T ws list 2>&1); then
    echo "vmrun could not list running VMs: ${out//$'\r'/}" >&2
    return 2
  fi
  out=${out//$'\r'/}
  if [[ ! "${out%%$'\n'*}" =~ ^Total\ running\ VMs:\ ([0-9]+)$ ]]; then
    echo "unexpected vmrun list output: ${out%%$'\n'*}" >&2
    return 2
  fi
  count="${BASH_REMATCH[1]}"
  # Parse with builtins: a failed tail in process substitution used to hide
  # every running VM and incorrectly report that it was safe to edit.
  if [[ "$out" == *$'\n'* ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      listed=$((listed + 1))
      [[ "$(lab_norm_win_path "$line")" != "$target" ]] || found=0
    done <<< "${out#*$'\n'}"
  fi
  [[ "$listed" == "$count" ]] || { echo 'Incomplete vmrun list; power is unknown.' >&2; return 2; }
  return "$found"
}
