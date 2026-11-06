#!/usr/bin/env bash
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
echo '--- VMX log error lines ---'
grep -inE 'error|warn|panic|failed|unable|assert|exception|unsupported' "${LAB_BASE_DIR}/vmware.log" | tail -n 80 || true
echo '--- VMX log last messages ---'
grep -E 'Msg_Post|DISKLIB|DISK|SCSI|IDE|CDROM|VMDK|EFI|firmware|Error|error|WARN' "${LAB_BASE_DIR}/vmware.log" | tail -n 80 || true
echo '--- vdiskmanager help ---'
"${VMWARE_DIR}/vmware-vdiskmanager.exe" -h 2>&1 | head -n 40 || true
