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
# First-boot cloud-init reports the guest user through guestinfo from its final
# stage (lib/cloud-config.sh); wait for that instead of a fixed delay.
echo 'Waiting for first-boot cloud-init (guestinfo user report, up to 10 minutes)...'
reported=""
for _ in $(seq 1 120); do
  reported="$("$vmrun" -T ws readVariable "$vmx" guestVar "${LAB_GUESTINFO_USER_VAR:-wsl-vmware-lab.guest_user}" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$reported" ]] && break
  sleep 5
done
if [[ -z "$reported" ]]; then
  echo "[ERROR] the guest did not report its user within 10 minutes; check the VM console and cloud-init" >&2
  exit 1
fi
echo "[OK] cloud-init reported guest user: $reported"
sleep 15   # let the remaining runcmd steps finish before the soft shutdown
"$vmrun" -T ws stop "$vmx" soft
