#!/usr/bin/env bash
# Internal: ./lab configure [PLAYBOOK] [ansible-playbook options...]
# Writes the inventory for every lab VM (waits until all are ready), then runs
# PLAYBOOK against it. Default playbook: LAB_PLAYBOOK, else the nginx example
# ansible/configure-guest.yml. PLAYBOOK may live in your own project folder;
# relative paths are taken from the directory you run this from.
# Groups: each VM's `groups` from vms.tfvars, plus `lab` (all VMs).
# Terraform must have created and powered on the VMs first (./lab up).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/config.sh"
playbook="${1:-${LAB_PLAYBOOK:-$LAB_PROJECT_DIR/ansible/configure-guest.yml}}"
[[ $# -gt 0 ]] && shift
[[ "$playbook" == /* ]] || playbook="$PWD/$playbook"
[[ -f "$playbook" ]] || { echo "[ERROR] Playbook not found: $playbook" >&2; exit 2; }
# Real deadline (#20): every attempt is itself time-limited.
wait_s="${LAB_GUEST_WAIT_SECONDS:-300}"
deadline=$((SECONDS + wait_s))
ready=false
while (( SECONDS < deadline )); do
  rc=0; timeout 120 python3 "$here/guest-inventory.py" || rc=$?
  if [[ $rc -eq 0 ]]; then ready=true; break; fi
  [[ $rc -eq 3 ]] && exit 1   # an error a retry cannot fix (message above)
  [[ $rc -eq 124 ]] && echo '[WARN] inventory attempt timed out after 120 s (vmrun or terraform hung?)' >&2
  sleep 5
done
if [[ "$ready" != true ]]; then
  echo "Guests not ready after ${wait_s} s (LAB_GUEST_WAIT_SECONDS): no current management DHCP lease, or a guest never reported its user or SSH host key through guestinfo." >&2
  echo 'The guest image must ship open-vm-tools (Ubuntu cloud images do; Debian 12 cloud images do not). Only Ubuntu cloud images are supported.' >&2
  exit 1
fi
echo "[OK] Playbook: $playbook"
export ANSIBLE_PIPELINING=true
# The default 12 s privilege-escalation wait timed out on slower hosts.
export ANSIBLE_TIMEOUT="${ANSIBLE_TIMEOUT:-60}"
ansible-playbook -i "$LAB_INVENTORY" "$playbook" "$@"
