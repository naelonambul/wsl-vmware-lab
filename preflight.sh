#!/usr/bin/env bash
# Session preflight for the WSL + VMware lab. Run inside WSL, from anywhere:
#   bash <repo>/preflight.sh                 # report only, changes nothing
#   bash <repo>/preflight.sh --start-vmrest  # also start vmrest if it is down
# Exit code 0 = vmrest reachable AND the stored vmrest account accepted; 1 = not ready.
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
else
  ok "settings file: none (defaults; optional lab.env from lab.env.example)"
fi
have_creds=false
cred_msg="$(lab_require_credentials 2>&1 >/dev/null)"
if lab_require_credentials 2>/dev/null; then
  have_creds=true
  ok "vmrest account: from ${VMWS_CREDENTIAL_SOURCE} (values not shown)"
  # The secrets file must not be readable by other Windows users. Checked by
  # well-known SIDs so localized group names do not matter.
  if $interop && [[ "$VMWS_CREDENTIAL_SOURCE" == "secrets file /mnt/"* ]]; then
    acl="$("$PS" -NoProfile -NonInteractive -Command '
      param($f)
      $wide = "S-1-1-0","S-1-5-11","S-1-5-32-545"
      $hit = (Get-Acl -LiteralPath $f).Access | Where-Object {
        $_.AccessControlType -eq "Allow" -and
        $wide -contains $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
      if ($hit) { "open:" + (($hit.IdentityReference.Value | Select-Object -Unique) -join ",") } else { "private" }'       -f "$(wslpath -w "${VMWS_CREDENTIAL_SOURCE#secrets file }")" 2>/dev/null | tr -d '\r')"
    case "$acl" in
      private) ok "secrets file permissions: not readable by other Windows users" ;;
      open:*)  warn "secrets file readable by ${acl#open:}; restrict it to your user (icacls <file> /inheritance:r /grant:r %USERNAME%:F)" ;;
    esac
  fi
else
  warn "vmrest account: not available"
  sed 's/^/       /' <<<"$cred_msg"
fi
ok "guest user: image default, reported by the guest via guestinfo  base: $LAB_BASE_NAME"
if [[ -f "$LAB_VMS_FILE" ]]; then
  ok "VM list: $LAB_VMS_FILE"
else
  ok "VM list: single VM $LAB_CLONE_NAME (${LAB_CLONE_CPUS} vCPU, ${LAB_CLONE_MEMORY_MB} MB); for several VMs copy vms.tfvars.example to vms.tfvars"
fi
[[ -n "${LAB_GUEST_USER:-}" ]] && warn "LAB_GUEST_USER is set but no longer used; the guest uses the image's default user"
if [[ -n "$LAB_VM_ROOT_WIN" ]]; then ok "VM folder: $LAB_VM_ROOT_WIN (one <name> folder per VM)"; else warn "VM folder unknown (LAB_VM_ROOT_WIN)"; fi
[[ -n "${LAB_CLONE_VMX_WIN:-}" ]] && warn "LAB_CLONE_VMX_WIN is deprecated; set LAB_VM_ROOT_WIN instead (derived from it for now)"
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
    "process=$p listener8697=$l startupTask=$(if ($t) { $t.State } else { "absent" })"' 2>/dev/null | tr -d '\r'
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
    warn "startup task absent; running windows/start-vmrest.ps1 once (install the task with windows/install-vmrest-task.ps1)"
    "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$launcher" -NoWait -VmrestPath "$(wslpath -w "$VMWARE_DIR/vmrest.exe")" \
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
  # vmrest must come up at BOOT, before any logon: the task needs a boot
  # trigger and S4U (run whether the user is logged on or not).
  extra="$("$PS" -NoProfile -NonInteractive -Command '
    $t = Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue
    $c = Test-Path (Join-Path $env:USERPROFILE "vmrest.cfg")
    $boot = [bool]($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskBootTrigger" })
    $others = (Get-ScheduledTask | Where-Object { $_.TaskName -ne "VMware vmrest API" -and $_.Settings.Enabled -and
      ($_.Actions | Where-Object { "$($_.Execute) $($_.Arguments)" -match "vmrest" }) }).TaskName -join ";"
    "task=$(if ($t) { $(if ($t.Settings.Enabled) { "enabled" } else { "disabled" }) } else { "absent" }) boot=$boot logon=$($t.Principal.LogonType) cfg=$c others=[$others]"' 2>/dev/null | tr -d '\r')"
  others="$(sed -nE 's/.*others=\[([^]]*)\].*/\1/p' <<<"$extra")"
  if [[ "$extra" == *"task=absent"* ]]; then
    warn "startup task 'VMware vmrest API' absent: vmrest will not start at boot (install with windows/install-vmrest-task.ps1, elevated)"
  elif [[ "$extra" == *"task=disabled"* ]]; then
    warn "startup task 'VMware vmrest API' is disabled: vmrest will not start at boot"
  elif [[ "$extra" == *"boot=True logon=S4U"* ]]; then
    ok "startup task 'VMware vmrest API': boot trigger, runs without logon (S4U)"
  elif [[ -n "$extra" ]]; then
    warn "task 'VMware vmrest API' does not start vmrest at boot without logon; re-run windows/install-vmrest-task.ps1 (elevated)"
  fi
  [[ -n "$others" ]] && warn "other enabled task(s) also start vmrest: ${others} (keep one launcher; disable the others)"
  if [[ "$extra" == *"cfg=False"* ]]; then
    warn "no vmrest.cfg in the Windows user profile: the API account may not be set up (the user runs vmrest.exe -C)"
  elif [[ "$extra" == *"cfg=True"* ]]; then
    ok "vmrest account file present in the Windows user profile (not read)"
  fi
fi

if ! $have_creds; then
  fail "cannot verify the vmrest account: no secrets file with it"
  echo "       The user writes the vmrest.exe -C account into ${LAB_SECRETS_FILE:-%USERPROFILE%\\.env}:"
  echo "         VMWS_USERNAME=<account>"
  echo "         VMWS_PASSWORD=<password>"
  exit 1
fi
auth_code="$(curl --connect-timeout 3 --max-time 8 -s -o /dev/null -w '%{http_code}' -K - "${VMWS_ENDPOINT%/}/vms" \
  < <(lab_curl_auth))"
if [[ "$auth_code" == 200 ]]; then
  ok "authenticated GET /vms: HTTP 200 (stored account matches vmrest)"
elif [[ "$auth_code" == 401 ]]; then
  fail "authenticated GET /vms: HTTP 401 - stored account (${VMWS_CREDENTIAL_SOURCE}) does not match vmrest"
  echo "       vmrest keeps its own account (vmrest.exe -C, vmrest.cfg); its password is not readable."
  echo "       The user corrects the secrets file, or re-runs vmrest.exe -C, writes the same values"
  echo "       there and restarts vmrest. Also check that vmrest runs as the same Windows user."
  exit 1
else
  fail "authenticated GET /vms: HTTP $auth_code"
  exit 1
fi
echo '== Ready: vmrest reachable and credentials accepted'
