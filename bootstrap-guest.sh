#!/usr/bin/env bash
# Called by Terraform while the clone is powered off.
set -euo pipefail
cd "$(dirname "$0")"
source lib/config.sh
if "${VMWARE_DIR}/vmrun.exe" -T ws list | tr -d '\r' | grep -Fxq "$VMX_WIN"; then
  echo 'Power the clone off with Terraform before bootstrap; use terraform-vm.sh on.' >&2
  exit 1
fi
[[ "$VM_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Invalid VM id from Terraform' >&2; exit 1; }
vmx=$(wslpath -u "$VMX_WIN")
seed_dir="$LAB_PRIVATE_DIR/seed-$VM_ID"
mkdir -p "$seed_dir"
# vmrest derives the VM id from the VMX path, so a clone recreated at the same
# path gets the same id. This bootstrap only runs for a freshly created disk,
# whose cloud-init generates new SSH host keys: forget the old ones.
known_hosts="$LAB_PRIVATE_DIR/known_hosts-$VM_ID"
if [[ -e "$known_hosts" ]]; then
  rm -f -- "$known_hosts"
  echo '[OK] Reset known_hosts for the recreated clone id'
fi
pubkey=$(cat "$LAB_SSH_KEY.pub")
# The image's "default" user is already "ubuntu"; list it only for other names.
default_entry=""
[[ "$LAB_GUEST_USER" != ubuntu ]] && default_entry="  - default"
cat > "$seed_dir/user-data" <<CFG
#cloud-config
users:
${default_entry}
  - name: ${LAB_GUEST_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $pubkey
ssh_pwauth: false
disable_root: true
CFG
printf 'instance-id: %s\nlocal-hostname: %s\n' "$VM_ID" "$LAB_CLONE_NAME" > "$seed_dir/meta-data"
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
export SEED_WIN="$(wslpath -w "$seed_iso")"
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
}
for key,value in settings.items():
    line=f'{key} = "{value}"'
    pattern=r'(?m)^\s*'+re.escape(key)+r'\s*=.*$'
    if re.search(pattern,s): s=re.sub(pattern,lambda m:line,s)
    else: s+='\n'+line
p.write_text(s+'\n')
print('[OK] Cloud-init seed and management NIC configured')
PY
