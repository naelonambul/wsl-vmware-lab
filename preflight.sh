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
  # Administrators). Compared by SID so localized names do not matter. The
  # path goes through the environment: powershell.exe -Command does not bind
  # trailing arguments to param().
  if $interop && [[ "$VMWS_CREDENTIAL_SOURCE" == "secrets file /mnt/"* ]]; then
    secrets_win="$(wslpath -w "${VMWS_CREDENTIAL_SOURCE#secrets file }")"
    acl="$(LAB_ACL_FILE="$secrets_win" WSLENV="LAB_ACL_FILE${WSLENV:+:$WSLENV}" \
      "$PS" -NoProfile -NonInteractive -Command '
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
      } catch { "error:" + $_.Exception.GetType().Name }' 2>/dev/null | tr -d '\r')" || acl=""
    # Printed literally for the user to paste into PowerShell; not expanded here.
    fix_cmd='icacls "'"$secrets_win"'" /inheritance:r /grant:r "$($env:USERNAME):F"'
    case "$acl" in
      private) ok "secrets file permissions: only your user, SYSTEM and Administrators are granted access" ;;
      open:*)  warn "secrets file also grants access to: ${acl#open:}; restrict it to your user (PowerShell: $fix_cmd), then re-run preflight" ;;
      *)       warn "secrets file permissions: could not be checked (${acl:-no output}); check with: icacls \"$secrets_win\"" ;;
    esac
  fi
else
  warn "vmrest account: not available"
  sed 's/^/       /' <<<"$cred_msg"
fi
ok "guest user: image default, reported by the guest via guestinfo  base: $LAB_BASE_NAME"
if [[ -f "$LAB_VMS_FILE" ]]; then
  ok "VM list: $LAB_VMS_FILE"
elif [[ "$LAB_VMS_FILE_EXPLICIT" == 1 ]]; then
  warn "VM list: LAB_VMS_FILE is set but $LAB_VMS_FILE does not exist; terraform-vm.sh will refuse to run"
else
  ok "VM list: single VM $LAB_CLONE_NAME (${LAB_CLONE_CPUS} vCPU, ${LAB_CLONE_MEMORY_MB} MB); for several VMs copy vms.tfvars.example to vms.tfvars"
fi
[[ -n "${LAB_GUEST_USER:-}" ]] && warn "LAB_GUEST_USER is set but no longer used; the guest uses the image's default user"
if [[ -n "$LAB_VM_ROOT_WIN" ]]; then ok "VM folder: $LAB_VM_ROOT_WIN (one <name> folder per VM)"; else warn "VM folder unknown (LAB_VM_ROOT_WIN)"; fi
# vmrest clones into VMware Workstation's default VM folder (Preferences >
# Workspace), not into the path Terraform asks for; the two must match or the
# provider fails with "inconsistent result after apply: .path".
if [[ -n "$profile" && -n "$LAB_VM_ROOT_WIN" ]]; then
  prefs="$(wslpath -u "$profile")/AppData/Roaming/VMware/preferences.ini"
  ws_default="$profile\\Documents\\Virtual Machines"
  if [[ -f "$prefs" ]]; then
    v="$(tr -d '\r' < "$prefs" | sed -nE 's/^[[:space:]]*prefvmx\.defaultVMPath[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' | tail -n 1)"
    [[ -n "$v" ]] && ws_default="$v"
  fi
  norm() { local x="${1%\\}"; echo "${x,,}"; }
  if [[ "$(norm "$ws_default")" == "$(norm "$LAB_VM_ROOT_WIN")" ]]; then
    ok "VM folder matches VMware Workstation's default VM location"
  else
    warn "VM folder $LAB_VM_ROOT_WIN differs from Workstation's default VM location $ws_default; vmrest clones there, so Terraform will fail. Set LAB_VM_ROOT_WIN to it, or change Workstation (Edit > Preferences > Workspace) and restart vmrest"
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
# A task must run the administrator-only copy in %ProgramFiles%\wsl-vmware-lab
# (installed by the install scripts), and that copy should match this checkout.
check_task_script() {  # task name, Windows path, SHA-256 of it, script name, install command
  local task="$1" file="$2" hash="$3" name="$4" install="$5" repo_hash
  if [[ "${file,,}" != *'\program files\wsl-vmware-lab\'"${name,,}" ]]; then
    warn "task '$task' runs $file, which non-administrators may be able to change; re-run $install (elevated) to install the protected copy"
    return
  fi
  repo_hash="$(sha256sum "$LAB_PROJECT_DIR/windows/$name" | cut -d' ' -f1)"
  if [[ "${repo_hash^^}" == "${hash^^}" ]]; then
    ok "task '$task' runs the protected copy $file (matches this repository)"
  else
    warn "task '$task' runs $file, which differs from this repository's windows/$name; re-run $install (elevated) to update it"
  fi
}

if $interop; then
  # vmrest must come up at BOOT, before any logon: the task needs a boot
  # trigger and S4U (run whether the user is logged on or not).
  extra="$("$PS" -NoProfile -NonInteractive -Command '
    $t = Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue
    $c = Test-Path (Join-Path $env:USERPROFILE "vmrest.cfg")
    $q = [char]34
    $file = if ($t -and ("$($t.Actions.Arguments)" -match ("-File " + $q + "([^" + $q + "]+)" + $q))) { $Matches[1] } else { "" }
    $fileok = [bool]($file -and (Test-Path -LiteralPath $file))
    $hash = if ($fileok) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } else { "" }
    $boot = [bool]($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskBootTrigger" })
    $others = (Get-ScheduledTask | Where-Object { $_.TaskName -ne "VMware vmrest API" -and $_.Settings.Enabled -and
      ($_.Actions | Where-Object { "$($_.Execute) $($_.Arguments)" -match "vmrest" }) }).TaskName -join ";"
    "task=$(if ($t) { $(if ($t.Settings.Enabled) { "enabled" } else { "disabled" }) } else { "absent" }) boot=$boot logon=$($t.Principal.LogonType) cfg=$c fileok=$fileok hash=$hash others=[$others] file=<$file>"' 2>/dev/null | tr -d '\r')"
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
  task_file="$(sed -nE 's/.*file=<([^>]*)>.*/\1/p' <<<"$extra")"
  if [[ "$extra" != *"task=absent"* && "$extra" == *"fileok=False"* ]]; then
    warn "task 'VMware vmrest API' runs a missing script (${task_file:-unknown}); the repository moved? re-run windows/install-vmrest-task.ps1 (elevated)"
  elif [[ -n "$task_file" ]]; then
    check_task_script "VMware vmrest API" "$task_file" "$(sed -nE 's/.*hash=([0-9A-F]*) .*/\1/p' <<<"$extra")" \
      start-vmrest.ps1 "windows/install-vmrest-task.ps1"
  fi
  [[ -n "$others" ]] && warn "other enabled task(s) also start vmrest: ${others} (keep one launcher; disable the others)"
  # WSL SSH keep-alive task (windows/wsl2-ssh-forward.ps1 InstallTask): boot + S4U, script present.
  ssh_task="$("$PS" -NoProfile -NonInteractive -Command '
    $t = Get-ScheduledTask -TaskName "WSL2 SSH Service Start" -ErrorAction SilentlyContinue
    if (-not $t) { "absent"; exit }
    $boot = [bool]($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq "MSFT_TaskBootTrigger" })
    $q = [char]34
    $file = if ("$($t.Actions.Arguments)" -match ("-File " + $q + "([^" + $q + "]+)" + $q)) { $Matches[1] } else { "" }
    $fileok = [bool]($file -and (Test-Path -LiteralPath $file))
    $hash = if ($fileok) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } else { "" }
    "state=$($t.State) boot=$boot logon=$($t.Principal.LogonType) fileok=$fileok hash=$hash file=<$file>"' 2>/dev/null | tr -d '\r')"
  case "$ssh_task" in
    absent|"") warn "SSH task 'WSL2 SSH Service Start' absent: WSL SSH from other PCs is not set up (windows/wsl2-ssh-forward.ps1 InstallTask, elevated)" ;;
    *fileok=False*) warn "SSH task runs a missing script; re-run windows/wsl2-ssh-forward.ps1 InstallTask (elevated) from this repository" ;;
    *"boot=True logon=S4U"*) ok "SSH task 'WSL2 SSH Service Start': boot trigger, runs without logon (S4U), ${ssh_task%% *}" ;;
    *) warn "SSH task 'WSL2 SSH Service Start' does not start at boot without logon (${ssh_task%% hash=*}); re-run wsl2-ssh-forward.ps1 InstallTask (elevated)" ;;
  esac
  ssh_file="$(sed -nE 's/.*file=<([^>]*)>.*/\1/p' <<<"$ssh_task")"
  if [[ -n "$ssh_file" && "$ssh_task" == *fileok=True* ]]; then
    check_task_script "WSL2 SSH Service Start" "$ssh_file" "$(sed -nE 's/.*hash=([0-9A-F]*) .*/\1/p' <<<"$ssh_task")" \
      wsl2-ssh-forward.ps1 "windows/wsl2-ssh-forward.ps1 InstallTask"
  fi
  if [[ "$extra" == *"cfg=False"* ]]; then
    warn "no vmrest.cfg in the Windows user profile: the API account may not be set up (the user runs vmrest.exe -C)"
  elif [[ "$extra" == *"cfg=True"* ]]; then
    ok "vmrest account file present in the Windows user profile (not read)"
  fi

  # Sleep or hibernation stops WSL SSH, vmrest and the VMs; from another PC it
  # looks like an SSH timeout on port 22. Read only here: values come from
  # windows/configure-power.ps1 (by GUID, so localized powercfg output is fine).
  power="$("$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$LAB_PROJECT_DIR/windows/configure-power.ps1")" -Machine 2>/dev/null | tr -d '\r')"
  power_value() { tr ' ' '\n' <<<"$power" | sed -n "s/^$1=//p"; }
  # Prints what makes the PC stop answering, or nothing when the value is safe.
  power_risk() {
    local v="$2"
    [[ -z "$v" || "$v" == n/a || "$v" == 0 ]] && return
    if [[ "$1" == lid ]]; then
      case "$v" in 1) echo "closing the lid sleeps" ;; 2) echo "closing the lid hibernates" ;;
                   3) echo "closing the lid shuts down" ;; *) echo "lid action $v" ;; esac
      return
    fi
    (( v >= 31536000 )) && return   # a year or more never fires in practice
    echo "$1 after $(( (v + 59) / 60 )) min"
  }
  power_fix="windows/configure-power.ps1 -Action Apply in Windows PowerShell (no -Action: show only; -Action Restore: undo)"
  if [[ "$power" != *sleep_ac=* ]]; then
    warn "power settings could not be read; make sure Windows does not sleep while the lab is used remotely"
  else
    ac_risks=() dc_risks=()
    for k in sleep hibernate lid; do
      r="$(power_risk "$k" "$(power_value "${k}_ac")")"; [[ -n "$r" ]] && ac_risks+=("$r")
      r="$(power_risk "$k" "$(power_value "${k}_dc")")"; [[ -n "$r" ]] && dc_risks+=("$r")
    done
    if (( ${#ac_risks[@]} )); then
      warn "power (plugged in): $(printf '%s; ' "${ac_risks[@]}")SSH, vmrest and the VMs stop while Windows sleeps. Fix: $power_fix"
    else
      ok "power (plugged in): no sleep or hibernation timeout, closing the lid (if any) does nothing"
    fi
    if [[ "$(power_value battery)" == True ]] && (( ${#dc_risks[@]} )); then
      warn "power (on battery): $(printf '%s; ' "${dc_risks[@]}")keep the PC plugged in, or add -IncludeBattery to the fix above"
    fi
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
