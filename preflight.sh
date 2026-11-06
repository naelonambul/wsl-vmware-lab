#!/usr/bin/env bash
# Session preflight for the WSL + VMware lab. Run inside WSL, from anywhere:
#   bash <repo>/preflight.sh                 # report only, changes nothing
#   bash <repo>/preflight.sh --start-vmrest  # also start vmrest if it is down
# Exit code 0 = vmrest reachable AND lab.env credentials accepted; 1 = not ready.
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
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

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
  warn "Windows interop unavailable; set LAB_CLONE_VMX_WIN in lab.env and check vmrest on Windows yourself"
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
elif [[ -n "${VMWS_CREDENTIALS_FILE:-}" && -f "$VMWS_CREDENTIALS_FILE" ]]; then
  ok "settings file: none; legacy credentials file: $VMWS_CREDENTIALS_FILE"
else
  warn "no settings file at $LAB_ENV_FILE (copy lab.env.example to lab.env, or set LAB_ENV_FILE)"
fi
have_creds=false
if [[ -n "${VMWS_USERNAME:-}" && -n "${VMWS_PASSWORD:-}" ]]; then
  have_creds=true
  ok "vmrest credentials: set (values not shown)"
else
  warn "vmrest credentials: VMWS_USERNAME / VMWS_PASSWORD not set"
fi
ok "guest user: $LAB_GUEST_USER  base: $LAB_BASE_NAME  clone: $LAB_CLONE_NAME"
if [[ -n "$LAB_CLONE_VMX_WIN" ]]; then ok "clone VMX: $LAB_CLONE_VMX_WIN"; else warn "clone VMX path unknown (LAB_CLONE_VMX_WIN)"; fi
ok "private dir: $LAB_PRIVATE_DIR$([[ -d "$LAB_PRIVATE_DIR" ]] || echo ' (not created yet)')"

echo '== Tools'
for tool in terraform ansible-playbook python3 qemu-img cloud-localds curl; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else warn "$tool missing (sudo bash setup-wsl-tools.sh)"; fi
done
for exe in vmrun.exe vmrest.exe; do
  if [[ -f "$VMWARE_DIR/$exe" ]]; then ok "$exe in $VMWARE_DIR"; else fail "$exe not found in VMWARE_DIR=$VMWARE_DIR"; fi
done

echo '== vmrest API'
probe() {
  curl --connect-timeout 3 --max-time 8 -s -o /dev/null -w '%{http_code}' "${VMWS_ENDPOINT%/}/vms" 2>/dev/null
}
windows_vmrest_state() {
  $interop || { echo 'unknown (no interop)'; return; }
  "$PS" -NoProfile -NonInteractive -Command '
    $p = [bool](Get-Process vmrest -ErrorAction SilentlyContinue)
    $t = Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue
    $l = [bool](Get-NetTCPConnection -State Listen -LocalPort 8697 -ErrorAction SilentlyContinue)
    "process=$p listener8697=$l logonTask=$(if ($t) { $t.State } else { "absent" })"' 2>/dev/null | tr -d '\r'
}
start_it() {
  $interop || { fail "cannot start vmrest without Windows interop"; return 1; }
  if "$PS" -NoProfile -NonInteractive -Command \
      'if (Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName "VMware vmrest API"; exit 0 } else { exit 3 }' \
      >/dev/null 2>&1; then
    ok "started scheduled task 'VMware vmrest API'"
  else
    local launcher
    launcher="$(wslpath -w "$LAB_PROJECT_DIR/windows/start-vmrest.ps1")"
    warn "logon task absent; running windows/start-vmrest.ps1 once (install it with windows/install-vmrest-task.ps1)"
    "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$launcher" -VmrestPath "$(wslpath -w "$VMWARE_DIR/vmrest.exe")" \
      || { fail "start-vmrest.ps1 failed; check %LOCALAPPDATA%\\WSL-VMware\\vmrest-error.log"; return 1; }
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
  401) ok "vmrest answers at ${VMWS_ENDPOINT} (HTTP 401 without credentials = running)" ;;
  200) warn "vmrest answered 200 without credentials; authentication may be disabled" ;;
  404) fail "HTTP 404 - VMWS_ENDPOINT must end with /api"; exit 1 ;;
  *)   fail "unexpected HTTP $code from ${VMWS_ENDPOINT}"; exit 1 ;;
esac

# Windows-side setup that matters after a reboot or for authentication.
# vmrest.cfg (written by `vmrest.exe -C`) holds the API account; observed in
# %USERPROFILE% of the Windows user running vmrest. Only its presence is checked.
if $interop; then
  extra="$("$PS" -NoProfile -NonInteractive -Command '
    $t = Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue
    $c = Test-Path (Join-Path $env:USERPROFILE "vmrest.cfg")
    "task=$(if ($t) { $t.State } else { "absent" }) cfg=$c"' 2>/dev/null | tr -d '\r')"
  if [[ "$extra" == *"task=absent"* ]]; then
    warn "logon task 'VMware vmrest API' absent: vmrest will not start after a reboot (install with windows/install-vmrest-task.ps1)"
  elif [[ -n "$extra" ]]; then
    ok "logon task 'VMware vmrest API' present"
  fi
  if [[ "$extra" == *"cfg=False"* ]]; then
    warn "no vmrest.cfg in the Windows user profile: the API account may not be set up (the user runs vmrest.exe -C)"
  elif [[ "$extra" == *"cfg=True"* ]]; then
    ok "vmrest account file present in the Windows user profile (not read)"
  fi
fi

if ! $have_creds; then
  fail "cannot verify the vmrest account: VMWS_USERNAME / VMWS_PASSWORD not set"
  echo "       The user puts the account created with vmrest.exe -C into lab.env (see lab.env.example)."
  exit 1
fi
auth_code="$(curl --connect-timeout 3 --max-time 8 -s -o /dev/null -w '%{http_code}' -K - "${VMWS_ENDPOINT%/}/vms" \
  <<<"user = \"${VMWS_USERNAME}:${VMWS_PASSWORD}\"")"
if [[ "$auth_code" == 200 ]]; then
  ok "authenticated GET /vms: HTTP 200 (lab.env matches the vmrest account)"
elif [[ "$auth_code" == 401 ]]; then
  fail "authenticated GET /vms: HTTP 401 - lab.env does not match the vmrest account"
  echo "       vmrest keeps its own account (vmrest.exe -C); the password is not stored in readable form."
  echo "       The user either corrects lab.env, or re-runs vmrest.exe -C, updates lab.env to match"
  echo "       and restarts vmrest. Also check that vmrest runs as the same Windows user."
  exit 1
else
  fail "authenticated GET /vms: HTTP $auth_code"
  exit 1
fi
echo '== Ready: vmrest reachable and credentials accepted'
