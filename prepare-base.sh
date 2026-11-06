#!/usr/bin/env bash
# One-time template preparation, before Terraform clones it.
set -euo pipefail
cd "$(dirname "$0")"
source lib/config.sh
bash create-base-template.sh
bash register-base.sh
vmx=$(wslpath -w "${LAB_BASE_DIR}/ubuntu-base.vmx")
vmrun="${VMWARE_DIR}/vmrun.exe"
"$vmrun" -T ws start "$vmx" nogui
# A fixed wait does not prove cloud-init finished; check the guest if in doubt.
echo 'Waiting 45 seconds for the initial cloud-init setup...'
sleep 45
"$vmrun" -T ws stop "$vmx" soft
