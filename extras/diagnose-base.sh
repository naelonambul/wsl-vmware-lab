#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
echo '--- VM files ---'
ls -lh "${LAB_BASE_DIR}/ubuntu-base.vmx" "${LAB_BASE_DIR}/ubuntu-base.vmdk" 2>&1
echo '--- VMX ---'
cat "${LAB_BASE_DIR}/ubuntu-base.vmx" 2>&1
echo '--- VMware log tail ---'
tail -n 100 "${LAB_BASE_DIR}/vmware.log" 2>&1
echo '--- running VMs ---'
"${VMWARE_DIR}/vmrun.exe" -T ws list 2>&1 || true
echo '--- VMware processes ---'
ps -ef | grep -E '[v]mware-vmx|[v]mware.exe|[v]mware-vmx-debug' || true
