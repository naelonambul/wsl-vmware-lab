#!/usr/bin/env bash
# Host checks, run by ./lab status [--start-vmrest] (WSL).
#   ./lab status                 # report only, changes nothing
#   ./lab status --start-vmrest  # also start vmrest if it is down
# Exit code 0 = vmrest listens on loopback only, refuses requests without
# credentials and accepts the stored account; 1 = not ready. VM state is
# reported separately (lib/lifecycle.sh status).
# Never prints secrets.
set -uo pipefail

start_vmrest=false
case "${1:-}" in
  "") ;;
  --start-vmrest) start_vmrest=true ;;
  -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (use --start-vmrest)" >&2; exit 2 ;;
esac

# shellcheck source=lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }

# How many seconds to wait for vmrest after starting it. The launcher itself
# checks after 2 s; the API usually answers within a few seconds more.
START_WAIT_SECONDS=30
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

echo '== Environment (discovered, not assumed)'
ok "repository: $LAB_PROJECT_DIR"
distro="${WSL_DISTRO_NAME:-}"
if [[ -z "$distro" ]]; then
  # WSL_DISTRO_NAME is unset in SSH sessions; the UNC root names the distro.
  distro="$(wslpath -w / 2>/dev/null | sed -nE 's#^\\\\wsl(\.localhost|\$)\\([^\\]+).*#\2#p')"
fi
ok "WSL user: $(id -un)  home: $HOME  distro: ${distro:-unknown}"
interop=false
if [[ -x "$PS" ]] && "$PS" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1; then
  interop=true
fi
profile="$(lab_windows_profile)"
if [[ -n "$profile" ]]; then
  ok "Windows user profile: $profile"
else
  warn "Windows interop unavailable; set LAB_VM_ROOT_WIN in lab.env and check vmrest on Windows yourself"
fi
if [[ -n "$profile" ]]; then
  wslconfig="$(wslpath -u "$profile")/.wslconfig"
  if [[ -f "$wslconfig" ]] && tr -d '\r' < "$wslconfig" | grep -qiE '^\s*networkingMode\s*=\s*mirrored'; then
    ok "WSL networking: mirrored (Windows 127.0.0.1 reachable from WSL)"
  else
    warn "WSL networking is not mirrored in $wslconfig; 127.0.0.1:8697 may not reach Windows vmrest"
  fi
fi

echo '== Configuration'
if [[ -f "$LAB_ENV_FILE" ]]; then
  ok "settings file: $LAB_ENV_FILE"
  if grep -q $'\r' "$LAB_ENV_FILE"; then
    warn "settings file has Windows (CRLF) line endings; the scripts strip them, but convert it once: sed -i 's/\\r\$//' $LAB_ENV_FILE"
  fi
else
  ok "settings file: none (defaults; optional lab.env from lab.env.example)"
fi
have_creds=false
cred_msg="$(lab_require_credentials 2>&1 >/dev/null)"
if lab_require_credentials 2>/dev/null; then
  have_creds=true
  ok "vmrest account: from ${VMWS_CREDENTIAL_SOURCE} (values not shown)"
  # The secrets file should grant access only to your user (plus SYSTEM and
  # Administrators).
  if $interop && [[ "$VMWS_CREDENTIAL_SOURCE" == "secrets file /mnt/"* ]]; then
    secrets="${VMWS_CREDENTIAL_SOURCE#secrets file }"
    acl="$(lab_secrets_acl "$secrets")"
    case "$acl" in
      private) ok "secrets file permissions: only your user, SYSTEM and Administrators are granted access" ;;
      open:*)  warn "secrets file also grants access to: ${acl#open:}; restrict it with: ./lab account --lock" ;;
      *)       warn "secrets file permissions: could not be checked (${acl:-no output}); check with: icacls \"$(wslpath -w "$secrets")\"" ;;
    esac
  fi
else
  warn "vmrest account: not available"
  sed 's/^/       /' <<<"$cred_msg"
fi
if lan=$(lab_lan); then ok "LAN: ${lan%% *} (for VMs with lan = true; lan_ip must be in it)"; else warn "LAN unknown (no IPv4 default route in WSL)"; fi
ok "guest images in use: $(lab_used_images | tr '\n' ' ')(default $LAB_IMAGE)  user: $LAB_GUEST_USER (created by cloud-init, SSH host key pinned before first boot)"
[[ -n "${LAB_BASE_NAME:-}" ]] && warn "LAB_BASE_NAME is set but no longer used; each image's base is named <image>-base"
if [[ -f "$LAB_VMS_FILE" ]]; then
  ok "VM list: $LAB_VMS_FILE"
elif [[ "$LAB_VMS_FILE_EXPLICIT" == 1 ]]; then
  warn "VM list: LAB_VMS_FILE is set but $LAB_VMS_FILE does not exist; terraform-vm.sh will refuse to run"
else
  ok "VM list: single VM $LAB_CLONE_NAME (${LAB_CLONE_CPUS} vCPU, ${LAB_CLONE_MEMORY_MB} MB); for several VMs copy vms.tfvars.example to vms.tfvars"
fi
if [[ -n "$LAB_VM_ROOT_WIN" ]]; then ok "VM folder: $LAB_VM_ROOT_WIN (one <name> folder per VM)"; else warn "VM folder unknown (LAB_VM_ROOT_WIN)"; fi
# vmrest clones into VMware Workstation's default VM folder (Preferences >
# Workspace), not into the path Terraform asks for; the two must match or the
# provider 2.0.1 fails with "inconsistent result after apply: .path".
# Only compare an explicit preference; do not guess when the key is absent.
if $interop && [[ -n "$LAB_VM_ROOT_WIN" ]]; then
  appdata=$("$PS" -NoProfile -NonInteractive -Command '$env:APPDATA' </dev/null 2>/dev/null | tr -d '\r')
  prefs=''
  [[ -z "$appdata" ]] || prefs="$(wslpath -u "$appdata")/VMware/preferences.ini"
  ws_default=''
  if [[ -f "$prefs" ]]; then
    v="$(tr -d '\r' < "$prefs" | sed -nE 's/^[[:space:]]*prefvmx\.defaultVMPath[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' | tail -n 1)"
    [[ -n "$v" ]] && ws_default="$v"
  fi
  norm() { local x="${1//\//\\}"; x="${x%\\}"; echo "${x,,}"; }
  if [[ -z "$ws_default" ]]; then
    : # No preference key: no inferred default and no warning.
  elif [[ "$(norm "$ws_default")" == "$(norm "$LAB_VM_ROOT_WIN")" ]]; then
    ok "VM folder matches VMware Workstation's default VM location"
  else
    warn "VM folder $LAB_VM_ROOT_WIN differs from Workstation's default VM location $ws_default; provider 2.0.1 clones there, so Terraform will fail. Set LAB_VM_ROOT_WIN to Workstation's default VM folder."
  fi
fi
[[ -n "${LAB_CLONE_VMX_WIN:-}" ]] && warn "LAB_CLONE_VMX_WIN is deprecated; set LAB_VM_ROOT_WIN instead (derived from it for now)"
ok "private dir: $LAB_PRIVATE_DIR$([[ -d "$LAB_PRIVATE_DIR" ]] || echo ' (not created yet)')"

echo '== Tools'
for tool in terraform ansible-playbook python3 qemu-img cloud-localds curl; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else warn "$tool missing (./lab setup installs it)"; fi
done
for exe in vmrun.exe vmrest.exe; do
  if [[ -f "$VMWARE_DIR/$exe" ]]; then ok "$exe in $VMWARE_DIR"; else fail "$exe not found in VMWARE_DIR=$VMWARE_DIR"; fi
done

echo '== vmrest API'
# vmrest must stay on loopback (#21): the endpoint itself, and the listener below.
ep_host=$(sed -E 's#^[a-z]+://(\[[^]]+\]|[^:/]+).*#\1#' <<<"$VMWS_ENDPOINT")
case "$ep_host" in
  127.0.0.1|localhost|'[::1]') ok "endpoint is loopback: $VMWS_ENDPOINT" ;;
  *) fail "VMWS_ENDPOINT host is $ep_host; the lab expects vmrest on 127.0.0.1 only (mirrored networking)"; exit 1 ;;
esac
probe() {
  curl --connect-timeout 3 --max-time 8 -s -o /dev/null -w '%{http_code}' "${VMWS_ENDPOINT%/}/vms" 2>/dev/null
}
windows_vmrest_state() {
  $interop || { echo 'unknown (no interop)'; return; }
  "$PS" -NoProfile -NonInteractive -Command '
    $p = [bool](Get-Process vmrest -ErrorAction SilentlyContinue)
    $t = Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue
    $l = [bool](Get-NetTCPConnection -State Listen -LocalPort 8697 -ErrorAction SilentlyContinue)
    "process=$p listener8697=$l startupTask=$(if ($t) { $t.State } else { "absent" })"' 2>/dev/null | tr -d '\r'
}
start_it() {
  $interop || { fail "cannot start vmrest without Windows interop"; return 1; }
  if "$PS" -NoProfile -NonInteractive -Command \
      'if (Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName "VMware vmrest API"; exit 0 } else { exit 3 }' \
      >/dev/null 2>&1; then
    ok "started scheduled task 'VMware vmrest API'"
  else
    fail "startup task 'VMware vmrest API' absent: run windows\\setup.cmd Install (elevated)"; return 1
  fi
}

code="$(probe)"
if [[ "$code" == 000 ]]; then
  fail "no answer from ${VMWS_ENDPOINT} (HTTP 000) - vmrest is not reachable"
  state="$(windows_vmrest_state)"
  echo "       Windows side: $state"
  if [[ "$state" == *"process=True listener8697=True"* ]]; then
    echo "       vmrest is running on Windows: check VMWS_ENDPOINT and mirrored networking before starting anything"
    exit 1
  fi
  if $start_vmrest; then
    start_it || exit 1
    for ((i = 0; i < START_WAIT_SECONDS; i++)); do
      code="$(probe)"; [[ "$code" != 000 ]] && break; sleep 1
    done
    [[ "$code" == 000 ]] && { fail "vmrest still unreachable after ${START_WAIT_SECONDS}s"; echo "       Windows side: $(windows_vmrest_state)"; exit 1; }
  else
    echo "       Start it: bash $0 --start-vmrest  (ask the user first)"
    exit 1
  fi
fi
case "$code" in
  401) ok "vmrest answers at ${VMWS_ENDPOINT} and refuses requests without credentials (HTTP 401)" ;;
  200) fail "vmrest answered HTTP 200 without credentials: authentication is off. Configure the account with ./lab account"; exit 1 ;;
  404) fail "HTTP 404 - VMWS_ENDPOINT must end with /api"; exit 1 ;;
  *)   fail "unexpected HTTP $code from ${VMWS_ENDPOINT}"; exit 1 ;;
esac
if $interop; then
  listen=$(timeout 30 "$PS" -NoProfile -NonInteractive -Command \
    '(Get-NetTCPConnection -State Listen -LocalPort 8697 -ErrorAction SilentlyContinue).LocalAddress | Sort-Object -Unique' 2>/dev/null | tr -d '\r' | tr '\n' ' ')
  nonloop=$(tr ' ' '\n' <<<"$listen" | grep -v -E '^(127\.0\.0\.1|::1|)$' || true)
  if [[ -z "${listen// /}" ]]; then
    warn "could not read the Windows listener for port 8697; loopback-only not confirmed"
  elif [[ -n "$nonloop" ]]; then
    fail "vmrest listens on a non-loopback address: $(tr '\n' ' ' <<<"$nonloop")- other machines on the network can reach it"; exit 1
  else
    ok "vmrest listens on loopback only ($listen)"
  fi
else
  warn "no Windows interop: loopback-only listener not confirmed"
fi

# Windows side (boot tasks, firewall, power): read only, reported by
# windows/setup.ps1 Status; not part of the exit code.
if $interop; then
  echo '== Windows (windows/setup.ps1 Status)'
  timeout 90 "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$LAB_PROJECT_DIR/windows/setup.ps1")" Status 2>&1 | tr -d '\r' | sed 's/^/  /' || true
fi

if ! $have_creds; then
  fail "cannot verify the vmrest account: no secrets file with it"
  echo "       The user runs ./lab account (vmrest.exe -C + secrets file), or writes the existing"
  echo "       vmrest account into ${LAB_SECRETS_FILE:-%USERPROFILE%\\.env}: VMWS_USERNAME=... and VMWS_PASSWORD=..."
  exit 1
fi
auth_code="$(curl --connect-timeout 3 --max-time 8 -s -o /dev/null -w '%{http_code}' -K - "${VMWS_ENDPOINT%/}/vms" \
  < <(lab_curl_auth))"
if [[ "$auth_code" == 200 ]]; then
  ok "authenticated GET /vms: HTTP 200 (stored account matches vmrest)"
elif [[ "$auth_code" == 401 ]]; then
  fail "authenticated GET /vms: HTTP 401 - stored account (${VMWS_CREDENTIAL_SOURCE}) does not match vmrest"
  echo "       vmrest keeps its own account (vmrest.exe -C, vmrest.cfg); its password is not readable."
  echo "       The user corrects the secrets file, or runs ./lab account to set both again."
  echo "       Also check that vmrest runs as the same Windows user."
  exit 1
else
  fail "authenticated GET /vms: HTTP $auth_code"
  exit 1
fi
echo '== Ready: vmrest on loopback, authentication required, stored account accepted (VMs: see below)'
