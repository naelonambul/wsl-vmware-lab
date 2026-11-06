#!/usr/bin/env bash
# Diagnostic record only. Note: `vmrun listRegisteredVM` is unsupported on current
# Workstation; use ../api-status.sh to check registration.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
echo "OVF hardware:"
grep -E 'VirtualSystemType|ElementName|ResourceType|VirtualQuantity|HostResource|Parent|AddressOnParent|Connection' \
  "${LAB_BASE_DIR}/ubuntu-noble-24.04-cloudimg.ovf" | head -n 60
echo "Registered VMs:"
"${VMWARE_DIR}/vmrun.exe" listRegisteredVM 2>&1 | head -n 15
echo "Workstation tools:"
ls -l "${VMWARE_DIR}/vmware-vdiskmanager.exe" "${VMWARE_DIR}/vmrest.exe"
