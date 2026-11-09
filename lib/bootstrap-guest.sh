#!/usr/bin/env bash
# Called by Terraform while the clone is powered off.
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/config.sh
source lib/cloud-config.sh
# A clone whose record only had to be restored (lib/lifecycle.sh, after a
# targeted destroy of another clone) is left exactly as it is.
for keep in ${LAB_BOOTSTRAP_KEEP:-}; do
  if [[ "$keep" == "${VM_NAME:-}" ]]; then
    echo "[OK] $VM_NAME: existing clone left unchanged (bootstrap record restored)"
    exit 0
  fi
done
# Refuse unless the clone is positively known to be off: a failed or garbled
# vmrun answer must stop here, before any file is changed.
power=0; lab_vm_running "$VMX_WIN" || power=$?
if [[ $power -eq 0 ]]; then
  echo 'Power the clone off with Terraform before bootstrap; use ./lab up.' >&2
  exit 1
elif [[ $power -ne 1 ]]; then
  echo '[ERROR] Could not confirm the clone is powered off; not editing it.' >&2
  exit 1
fi
[[ "$VM_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Invalid VM id from Terraform' >&2; exit 1; }
vmx=$(wslpath -u "$VMX_WIN")
seed_dir="$LAB_PRIVATE_DIR/seed-$VM_ID"
umask 077
mkdir -p "$seed_dir"
# A fresh SSH host key for this disk, pinned before the guest ever runs. vmrest
# derives the VM id from the VMX path, so a clone recreated at the same path
# gets the same id: this bootstrap only runs for a freshly created disk and
# replaces the pin. The private key stays only in the seed (user-data here and
# the ISO next to the clone's disk, which holds the same key once booted).
keydir=$(mktemp -d "$LAB_PRIVATE_DIR/hostkey.XXXXXX")
trap 'rm -rf -- "$keydir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "wsl-vmware-lab-$VM_ID" -f "$keydir/key"
lab_cloud_config_user_data "$(cat "$LAB_SSH_KEY.pub")" "$keydir/key" > "$seed_dir/user-data"
known_hosts="$LAB_PRIVATE_DIR/known_hosts-$VM_ID"
printf 'wsl-vmware-lab-%s %s\n' "$VM_ID" "$(cut -d' ' -f1,2 "$keydir/key.pub")" > "$known_hosts.tmp"
mv -f -- "$known_hosts.tmp" "$known_hosts"
echo "[OK] Pinned a new SSH host key for ${VM_NAME:-$LAB_CLONE_NAME}"
printf 'instance-id: %s\nlocal-hostname: %s\n' "$VM_ID" "${VM_NAME:-$LAB_CLONE_NAME}" > "$seed_dir/meta-data"
cat > "$seed_dir/network-config" <<'CFG'
version: 2
ethernets:
  demo_interfaces:
    match:
      name: "en*"
    dhcp4: true
    dhcp-identifier: mac
CFG
# The ISO must reside on a Windows drive so Workstation can open it.
seed_iso="$(dirname "$vmx")/cloud-init-$VM_ID.iso"
cloud-localds --network-config="$seed_dir/network-config" "$seed_iso" "$seed_dir/user-data" "$seed_dir/meta-data"
SEED_WIN="$(wslpath -w "$seed_iso")"
export SEED_WIN
export VMX_LINUX="$vmx"
python3 - <<'PY'
import os, re
from pathlib import Path
p=Path(os.environ['VMX_LINUX'])
s=p.read_text()
settings={
 'ide1:0.fileName': os.environ['SEED_WIN'],
 'ide1:0.present':'TRUE', 'ide1:0.startConnected':'TRUE',
 'ide1:0.deviceType':'cdrom-image', 'ethernet0.startConnected':'TRUE',
 'ethernet1.present':'TRUE', 'ethernet1.startConnected':'TRUE',
 'ethernet1.connectionType':'custom', 'ethernet1.vnet':os.environ['LAB_MGMT_VNET'],
 'ethernet1.virtualDev':'e1000', 'ethernet1.addressType':'generated',
 # vmrest copies the base VMX verbatim: drop its BIOS UUID and NIC MACs so this
 # clone gets its own on first power-on (otherwise several clones share the
 # base's NAT MAC and receive the same DHCP address).
 'uuid.action':'create',
}
s=re.sub(r'(?mi)^\s*(uuid\.bios|uuid\.location|vc\.uuid|ethernet\d+\.generatedAddress(Offset)?)\s*=.*\n?','',s)
for key,value in settings.items():
    line=f'{key} = "{value}"'
    pattern=r'(?m)^\s*'+re.escape(key)+r'\s*=.*$'
    if re.search(pattern,s): s=re.sub(pattern,lambda m:line,s)
    else: s+='\n'+line
# Write a sibling temp file and rename it over the VMX, so an interrupted
# write never leaves a truncated VMX.
tmp=p.with_name(p.name+'.tmp')
tmp.write_text(s+'\n')
os.replace(tmp,p)
print('[OK] Cloud-init seed, management NIC and a fresh UUID/MAC for this clone configured')
PY
