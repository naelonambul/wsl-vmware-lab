#!/usr/bin/env bash
# vmrest API account, run by ./lab account [--lock] (WSL, interactive only).
#
# 1. Official `vmrest.exe -C`: the person types the username and the password
#    (twice) at vmrest's own prompts; vmrest checks the password rules and
#    writes %USERPROFILE%\vmrest.cfg. An existing vmrest.cfg is backed up first.
# 2. The username is taken from the `username=` line of vmrest.cfg (no other
#    line is read); the password is asked once more for the secrets file.
# 3. The secrets file (default %USERPROFILE%\.env) gets VMWS_USERNAME and
#    VMWS_PASSWORD; other lines are kept. Access: your user, SYSTEM and
#    Administrators only (inheritance off, every other entry removed).
# 4. vmrest is restarted through task 'VMware vmrest API' (when registered)
#    and an authenticated request must answer HTTP 200.
# --lock only does the access part of step 3 for an existing secrets file.
#
# Never echo the password, pass it as an argument or enable `set -x` here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
lock_only=0
case "${1:-}" in
  '') ;;
  --lock) lock_only=1 ;;
  *) echo 'Usage: ./lab account [--lock]' >&2; exit 2 ;;
esac

[[ -x "$PS" && -n "$LAB_WINDOWS_PROFILE" ]] || { echo '[ERROR] Windows interop is needed (powershell.exe, user profile).' >&2; exit 1; }
[[ -n "$LAB_SECRETS_FILE" ]] || { echo '[ERROR] No secrets file location; set LAB_SECRETS_FILE.' >&2; exit 1; }

# Access: your user + SYSTEM + Administrators, inheritance off, nothing else.
lock_secrets_file() {
  LAB_ACL_FILE="$(wslpath -w "$LAB_SECRETS_FILE")" WSLENV="LAB_ACL_FILE${WSLENV:+:$WSLENV}" \
    "$PS" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, "S-1-5-18", "S-1-5-32-544")) {
      $id = New-Object System.Security.Principal.SecurityIdentifier $sid
      $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule $id, "FullControl", "Allow"))
    }
    Set-Acl -LiteralPath $env:LAB_ACL_FILE -AclObject $acl' </dev/null
  local state; state="$(lab_secrets_acl "$LAB_SECRETS_FILE")"
  [[ "$state" == private ]] || { echo "[ERROR] Could not restrict $LAB_SECRETS_FILE ($state)" >&2; return 1; }
  echo "[OK] $LAB_SECRETS_FILE: only your user, SYSTEM and Administrators have access"
}

if [[ $lock_only -eq 1 ]]; then
  [[ -f "$LAB_SECRETS_FILE" ]] || lab_fail secrets_missing 'Secrets file not found.' 'The user runs ./lab account first.'
  python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
  lock_secrets_file
  exit 0
fi

# vmrest.exe -C reads the console directly; piped input does not work, and the
# password must be typed by a person.
[[ -t 0 && -t 2 ]] || lab_fail needs_user './lab account requires a terminal.' 'Run ./lab account in your own terminal and type the password yourself.'
vmrest="$VMWARE_DIR/vmrest.exe"
[[ -f "$vmrest" ]] || { echo "[ERROR] vmrest.exe not found in VMWARE_DIR=$VMWARE_DIR" >&2; exit 1; }
cfg="$(wslpath -u "$LAB_WINDOWS_PROFILE")/vmrest.cfg"

# 1. Official account setup.
if [[ -f "$cfg" ]]; then
  read -rp "A vmrest account already exists ($cfg). Replace it? [y/N] " answer
  [[ "$answer" == [yY] ]] || { echo 'Nothing changed.'; exit 0; }
  backup="$cfg.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$cfg" "$backup"
  echo "[OK] Backed up to $backup"
fi
echo '== vmrest.exe -C: choose the API username and password (8+ characters, upper and lower case, digit, special character)'
before="$(stat -c %Y "$cfg" 2>/dev/null || echo 0)"
python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
"$vmrest" -C
after="$(stat -c %Y "$cfg" 2>/dev/null || echo 0)"
[[ -f "$cfg" && "$after" != "$before" ]] || { echo '[ERROR] vmrest.cfg was not written; nothing else changed.' >&2; exit 1; }
user="$(tr -d '\r' < "$cfg" | sed -n 's/^username=//p' | head -n 1)"
[[ -n "$user" ]] || { echo "[ERROR] No username= line in $cfg" >&2; exit 1; }

# vmrest.exe runs through a Windows console that can leave terminal replies
# (escape sequences) in the input; drop them so they are neither read as the
# password nor echoed later.
flush_input() { while read -rs -t 0.2 -n 256 _; do :; done; }

# 2. Same password once more, for the secrets file.
echo "== Secrets file $LAB_SECRETS_FILE (username: $user)"
flush_input
read -rsp 'Type the same vmrest password once more: ' pass; echo
[[ -n "$pass" ]] || { echo '[ERROR] Empty password; the secrets file was not changed.' >&2; exit 1; }

# 3. Replace only the VMWS_* lines, write next to the file, then rename.
tmp="$(mktemp "$LAB_SECRETS_FILE.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
if [[ -f "$LAB_SECRETS_FILE" ]]; then
  # A sentinel keeps command substitution from dropping trailing newlines.
  other_lines=$(tr -d '\r' < "$LAB_SECRETS_FILE" && printf '\001') || lab_fail config_error 'Cannot read the existing secrets file; left unchanged.'
  other_lines="${other_lines%$'\001'}"
  filter_rc=0
  printf '%s' "$other_lines" | grep -Ev '^[[:space:]]*(export[[:space:]]+)?(VMWS_USERNAME|VMWS_USER|VMWS_PASSWORD)[[:space:]]*=' >> "$tmp" || filter_rc=$?
  [[ "$filter_rc" == 0 || "$filter_rc" == 1 ]] || lab_fail config_error 'Cannot preserve existing secrets file lines; left unchanged.'
  unset other_lines
fi
printf 'VMWS_USERNAME=%s\nVMWS_PASSWORD=%s\n' "$user" "$pass" >> "$tmp"
mv -f -- "$tmp" "$LAB_SECRETS_FILE"
trap - EXIT
echo "[OK] Wrote VMWS_USERNAME and VMWS_PASSWORD (other lines kept)"
lock_secrets_file

# 4. Restart vmrest so it loads the new account, then authenticate.
restarted="$("$PS" -NoProfile -NonInteractive -Command '
  $t = Get-ScheduledTask -TaskName "VMware vmrest API" -ErrorAction SilentlyContinue
  if (-not $t) { "no-task"; exit }
  Stop-ScheduledTask -TaskName "VMware vmrest API"
  Get-Process vmrest -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-ScheduledTask -TaskName "VMware vmrest API"; "restarted"' </dev/null 2>/dev/null | tr -d '\r' || true)"
if [[ "$restarted" != restarted ]]; then
  echo '[INFO] Task "VMware vmrest API" is not registered (windows\setup.cmd Install, elevated). Restart vmrest yourself, then: ./lab status'
  exit 0
fi
export VMWS_USERNAME="$user" VMWS_PASSWORD="$pass"   # read by lab_curl_auth
unset pass
flush_input
code=000
for _ in $(seq 1 15); do
  code="$(lab_curl_auth | curl -sS -K - --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "$VMWS_ENDPOINT/vms" 2>/dev/null || true)"
  [[ "$code" == 000 ]] || break
  sleep 1
done
case "$code" in
  200) echo '[OK] vmrest restarted; authenticated request: HTTP 200. Account ready.' ;;
  401) lab_fail vmrest_auth 'The secrets file account differs from vmrest.' 'The user runs ./lab account again.' ;;
  *)   echo "[ERROR] vmrest did not answer as expected (HTTP $code); check with ./lab status" >&2; exit 1 ;;
esac
