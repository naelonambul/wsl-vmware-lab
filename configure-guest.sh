#!/usr/bin/env bash
# Terraform must have created and powered on the VM first.
set -euo pipefail
cd "$(dirname "$0")"
source lib/config.sh
ready=false
for attempt in $(seq 1 30); do
  if python3 guest-inventory.py; then ready=true; break; fi
  sleep 5
done
if [[ "$ready" != true ]]; then echo 'Guest management IP not ready' >&2; exit 1; fi
export ANSIBLE_PIPELINING=true
ansible-playbook -i "$LAB_INVENTORY" ansible/configure-guest.yml
