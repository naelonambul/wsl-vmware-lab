#!/usr/bin/env bash
# One-time template preparation, before Terraform clones it.
# Usage: bash prepare-base.sh [--recreate]
# A finished base is marked with base/ubuntu-base.prepared; running this again
# then does nothing. --recreate rebuilds the base from the cloud image (the
# base must be powered off). Existing clones stay until the next
# ./lab up, which then asks for --allow-destroy to rebuild them.
set -euo pipefail
cd "$(dirname "$0")"
source lib/config.sh

recreate=()
for arg in "$@"; do
  case "$arg" in
    --recreate) recreate=(--recreate) ;;
    *) echo "Usage: bash prepare-base.sh [--recreate]" >&2; exit 2 ;;
  esac
done

prepared="${LAB_BASE_DIR}/ubuntu-base.prepared"
if [[ -f "$prepared" && ${#recreate[@]} -eq 0 ]]; then
  echo "[OK] Base already prepared ($prepared); nothing to do. To rebuild it: ./lab setup --recreate"
  exit 0
fi

bash create-base-template.sh "${recreate[@]}"
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
  echo "[ERROR] the guest did not report its user within 10 minutes; the base is still running." >&2
  echo "        Check the VM console and cloud-init, then shut it down and run: ./lab setup --recreate" >&2
  exit 1
fi
if [[ ! "$reported" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "[ERROR] the guest reported an unexpected user name: $reported (the base is still running)" >&2
  exit 1
fi
echo "[OK] cloud-init reported guest user: $reported"
sleep 15   # let the remaining runcmd steps finish before the soft shutdown
"$vmrun" -T ws stop "$vmx" soft
# The base counts as prepared only once it is confirmed off.
for _ in $(seq 1 60); do
  power=0; lab_vm_running "$vmx" || power=$?
  [[ $power -eq 1 ]] && break
  sleep 2
done
if [[ $power -ne 1 ]]; then
  echo "[ERROR] the base did not confirm it is powered off; not marking it prepared: $vmx" >&2
  exit 1
fi
printf 'guest_user=%s\nprepared=%s\n' "$reported" "$(date -Is)" > "$prepared"
echo "[OK] Base prepared and powered off: $vmx"
