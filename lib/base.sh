#!/usr/bin/env bash
# Base VM preparation, run by ./lab setup [--recreate] (WSL).
#
# Ubuntu 24.04 cloud image (signed SHA256SUMS) -> monolithic VMDK -> base VMX
# with the cloud-init seed -> vmrest registration -> first boot until the
# guest reports its user through guestinfo -> confirmed power-off -> marker
# base/ubuntu-base.prepared. With the marker present only the (idempotent)
# registration runs. --recreate rebuilds disk and VMX from the cloud image; the
# base must be off. Clones of the old base are rebuilt by ./lab up
# --allow-destroy (terraform_data.base_identity).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$LAB_PROJECT_DIR/lib/cloud-config.sh"

recreate=0
case "${1:-}" in
  '') ;;
  --recreate) recreate=1 ;;
  *) echo 'Usage: ./lab setup [--recreate]' >&2; exit 2 ;;
esac

ova_name=noble-server-cloudimg-amd64.ova   # file name published by Ubuntu
source_disk="$LAB_BASE_DIR/ubuntu-noble-24.04-cloudimg.vmdk"
vm_disk="$LAB_BASE_DIR/ubuntu-base.vmdk"
vmx="$LAB_BASE_DIR/ubuntu-base.vmx"
prepared="$LAB_BASE_DIR/ubuntu-base.prepared"
seed_dir="$LAB_PROJECT_DIR/cloud-init"
vmrun="$VMWARE_DIR/vmrun.exe"
vmx_win=""

register() {
  lab_require_credentials
  python3 "$LAB_PROJECT_DIR/lib/register-vm.py" "$vmx" "$LAB_BASE_NAME"
}

if [[ -f "$prepared" && $recreate -eq 0 ]]; then
  register
  echo "[OK] Base already prepared ($prepared). To rebuild it: ./lab setup --recreate"
  exit 0
fi

# Never change files of a running (or possibly running) base.
if [[ -e "$vmx" ]]; then
  vmx_win=$(wslpath -w "$vmx")
  power=0; lab_vm_running "$vmx_win" || power=$?
  [[ $power -eq 0 ]] && { echo "[ERROR] The base VM is running; shut it down first: $vmx" >&2; exit 1; }
  [[ $power -eq 1 ]] || { echo '[ERROR] Could not confirm the base VM is off; nothing changed.' >&2; exit 1; }
fi

# 1. Image: the signature of SHA256SUMS must verify (#22), then the OVA checksum.
cd "$LAB_PROJECT_DIR"
url="${LAB_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current}"
keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
[[ -f "$keyring" ]] || { echo "[ERROR] $keyring missing; install ubuntu-cloudimage-keyring (sudo apt-get install ubuntu-cloudimage-keyring)" >&2; exit 1; }
curl -fsS -o SHA256SUMS "$url/SHA256SUMS"
curl -fsS -o SHA256SUMS.gpg "$url/SHA256SUMS.gpg"
gpgv --keyring "$keyring" SHA256SUMS.gpg SHA256SUMS
grep -q " \*\?${ova_name}\$" SHA256SUMS || { echo "[ERROR] $ova_name not listed in SHA256SUMS" >&2; exit 1; }
if ! { [[ -f "$ova_name" ]] && sha256sum --ignore-missing -c SHA256SUMS 2>/dev/null | grep -q "^${ova_name}: OK$"; }; then
  curl -fSL --retry 3 -o "$ova_name.part" "$url/$ova_name"
  mv -f "$ova_name.part" "$ova_name"
  sha256sum --ignore-missing -c SHA256SUMS
fi
echo "[OK] $ova_name verified (signed SHA256SUMS)"

# 2. Disk: extract, convert to a temporary file, check, then rename.
mkdir -p "$LAB_BASE_DIR"
[[ $recreate -eq 1 ]] && rm -f -- "$vm_disk" "$vm_disk.partial" "$prepared"
if [[ ! -f "$vm_disk" ]]; then
  tar -xf "$ova_name" -C "$LAB_BASE_DIR"
  rm -f -- "$vm_disk.partial"
  qemu-img convert -p -f vmdk -O vmdk -o subformat=monolithicSparse "$source_disk" "$vm_disk.partial"
  want=$(qemu-img info --output=json "$source_disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
  got=$(qemu-img info --output=json -f vmdk "$vm_disk.partial" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["format"], d["virtual-size"])')
  [[ "$got" == "vmdk $want" ]] || { echo "[ERROR] Converted disk does not check out ($got, expected vmdk $want); left at $vm_disk.partial" >&2; exit 1; }
  mv -f -- "$vm_disk.partial" "$vm_disk"
  echo "[OK] Base disk converted: $vm_disk"
fi

# 3. cloud-init seed for the base (each clone gets its own in bootstrap-guest.sh).
mkdir -p "$LAB_PRIVATE_DIR" "$seed_dir"
chmod 700 "$LAB_PRIVATE_DIR"
[[ -f "$LAB_SSH_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C wsl-vmware-lab -f "$LAB_SSH_KEY"
chmod 600 "$LAB_SSH_KEY"
{
  echo '#cloud-config'
  lab_cloud_config_users "$(cat "$LAB_SSH_KEY.pub")"
  echo 'package_update: false'
  echo 'package_upgrade: false'
  echo 'runcmd:'
  echo '  - [systemctl, enable, --now, ssh]'
  lab_cloud_config_runcmd
} > "$seed_dir/user-data"
printf 'instance-id: ubuntu-wsl-vmware-lab-001\nlocal-hostname: ubuntu-wsl-lab\n' > "$seed_dir/meta-data"
cloud-localds "$seed_dir/seed.iso" "$seed_dir/user-data" "$seed_dir/meta-data"
chmod 644 "$seed_dir/seed.iso"

# 4. VMX: written once; an existing one (Workstation rewrites it) must still
# name this display name, disk and seed.
seed_rel=$(realpath --relative-to="$LAB_BASE_DIR" "$seed_dir/seed.iso")
new_vmx=$(mktemp "$vmx.XXXXXX")
trap 'rm -f -- "$new_vmx"' EXIT
cat > "$new_vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "10"
displayName = "${LAB_BASE_NAME}"
annotation = "Ubuntu 24.04 base template for Terraform"
guestOS = "ubuntu-64"
firmware = "efi"
memsize = "1024"
numvcpus = "2"
cpuid.coresPerSocket = "2"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "ubuntu-base.vmdk"
scsi0:0.deviceType = "scsi-hardDisk"
ide1:0.present = "TRUE"
ide1:0.deviceType = "cdrom-image"
ide1:0.fileName = "${seed_rel}"
ide1:0.startConnected = "TRUE"
ethernet0.present = "TRUE"
ethernet0.connectionType = "custom"
ethernet0.vnet = "${LAB_NAT_VNET}"
ethernet0.virtualDev = "e1000"
ethernet0.startConnected = "TRUE"
usb.present = "FALSE"
sound.present = "FALSE"
floppy0.present = "FALSE"
VMX
if [[ -f "$vmx" && $recreate -eq 0 ]]; then
  value() { tr -d '\r' < "$1" | sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$/\1/p" | tail -n 1; }
  for key in displayName 'scsi0:0\.fileName' 'ide1:0\.fileName'; do
    [[ "$(value "$vmx" "$key")" == "$(value "$new_vmx" "$key")" ]] || {
      echo "[ERROR] $vmx has ${key//\\/} = \"$(value "$vmx" "$key")\", expected \"$(value "$new_vmx" "$key")\"; left unchanged." >&2
      echo '        Fix LAB_BASE_NAME in lab.env, or rebuild the base: ./lab setup --recreate' >&2
      exit 1; }
  done
else
  chmod 644 "$new_vmx"
  mv -f -- "$new_vmx" "$vmx"
  echo "[OK] Base VMX written: $vmx"
fi

# 5. Register, first boot, wait for the guest's report, confirmed power-off.
register
vmx_win=$(wslpath -w "$vmx")
timeout 120 "$vmrun" -T ws start "$vmx_win" nogui
echo 'Waiting for first-boot cloud-init (guestinfo user report, up to 10 minutes)...'
reported=""
for _ in $(seq 1 120); do
  reported=$(timeout 30 "$vmrun" -T ws readVariable "$vmx_win" guestVar "$LAB_GUESTINFO_USER_VAR" 2>/dev/null | tr -d '\r' || true)
  [[ -n "$reported" ]] && break
  sleep 5
done
[[ -n "$reported" ]] || { echo '[ERROR] The guest did not report its user within 10 minutes; the base is still running. Check the VM console, shut it down, then: ./lab setup --recreate' >&2; exit 1; }
[[ "$reported" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "[ERROR] The guest reported an unexpected user name: $reported (the base is still running)" >&2; exit 1; }
echo "[OK] cloud-init reported guest user: $reported"
sleep 15   # let the remaining runcmd steps finish before the soft shutdown
timeout 120 "$vmrun" -T ws stop "$vmx_win" soft
for _ in $(seq 1 60); do
  power=0; lab_vm_running "$vmx_win" || power=$?
  [[ $power -eq 1 ]] && break
  sleep 2
done
[[ $power -eq 1 ]] || { echo "[ERROR] The base did not confirm it is off; not marking it prepared: $vmx" >&2; exit 1; }
printf 'guest_user=%s\nprepared=%s\n' "$reported" "$(date -Is)" > "$prepared"
echo "[OK] Base prepared and powered off: $vmx"
