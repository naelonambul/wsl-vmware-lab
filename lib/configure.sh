#!/usr/bin/env bash
# Internal: ./lab configure [PLAYBOOK] [ansible-playbook options...]
# Writes the inventory for every lab VM (waits until all are ready), then runs
# PLAYBOOK against it. Default playbook: LAB_PLAYBOOK, else the nginx example
# ansible/configure-guest.yml. PLAYBOOK may live in your own project folder;
# relative paths are taken from the directory you run this from.
# Groups: each VM's `groups` from vms.tfvars, plus `lab` (all VMs).
# Terraform must have created and powered on the VMs first (./lab up --all).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
lab_require_credentials
playbook="${LAB_PLAYBOOK:-$LAB_PROJECT_DIR/ansible/configure-guest.yml}"
if [[ $# -gt 0 && "$1" != -* ]]; then playbook="$1"; shift; fi
umask 077
mkdir -p "$LAB_PRIVATE_DIR"
selection_file=$(mktemp "$LAB_PRIVATE_DIR/configure-selection.XXXXXX")
trap 'rm -f "$selection_file"' EXIT
export LAB_INVENTORY_SELECTION_FILE="$selection_file"
unset LAB_INVENTORY_SELECTED
[[ "$playbook" == /* ]] || playbook="$PWD/$playbook"
[[ -f "$playbook" ]] || { echo "[ERROR] Playbook not found: $playbook" >&2; exit 2; }
# Real deadline (#20): every attempt is itself time-limited.
wait_s="${LAB_GUEST_WAIT_SECONDS:-300}"
deadline=$((SECONDS + wait_s))
ready=false
while (( SECONDS < deadline )); do
  rc=0; timeout 120 python3 "$here/guest-inventory.py" || rc=$?
  if [[ -s "$selection_file" ]]; then
    LAB_INVENTORY_SELECTED=$(cat "$selection_file")
    export LAB_INVENTORY_SELECTED
  fi
  if [[ $rc -eq 0 ]]; then ready=true; break; fi
  [[ $rc -eq 3 ]] && exit 1   # an error a retry cannot fix (message above)
  [[ $rc -eq 124 ]] && echo '[WARN] inventory attempt timed out after 120 s (terraform or ssh hung?)' >&2
  sleep 5
done
if [[ "$ready" != true ]]; then
  echo "Guests not ready after ${wait_s} s (LAB_GUEST_WAIT_SECONDS): no current management DHCP lease, or SSH as $LAB_GUEST_USER with the pinned host key never succeeded (last reason above)." >&2
  echo 'A clone created by an older version of this lab uses another user and host key: ./lab setup --recreate, then ./lab up --allow-destroy' >&2
  exit 1
fi
echo "[OK] Playbook: $playbook"
lab_ansible_env
ansible-playbook -i "$LAB_INVENTORY" "$playbook" "$@"
