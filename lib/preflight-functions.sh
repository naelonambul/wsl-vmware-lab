# shellcheck shell=bash
# Read-only Workstation preference comparison.
lab_check_vm_folder() {
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
}
