#!/usr/bin/env bash
# Read-only evidence, before setup: no lock, credentials, init or vmrest.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[[ -x "$ps" ]] || lab_fail runtime_error 'Windows PowerShell interop is unavailable.'
windows=$(mktemp)
trap 'rm -f -- "$windows"' EXIT
"$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \
  "$(wslpath -w "$LAB_PROJECT_DIR/windows/setup.ps1")" Network </dev/null | tr -d '\r' > "$windows"
# A new checkout has no state and needs no installed Terraform. Existing
# state is read through Terraform's public JSON representation, never outputs.
if [[ -f "$LAB_PROJECT_DIR/terraform/terraform.tfstate" ]]; then
  terraform -chdir="$LAB_PROJECT_DIR/terraform" show -json
else
  printf '{}\n'
fi | python3 "$LAB_PROJECT_DIR/lib/network-inspect.py" report "$windows"
