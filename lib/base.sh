#!/usr/bin/env bash
# Base VM preparation, run by ./lab setup [--recreate] (WSL).
#
# Cloud image LAB_IMAGE (default ubuntu-24.04; table below) -> checksum (and
# signature where the distribution publishes one) -> monolithic VMDK -> base VMX
# -> vmrest registration -> marker base/ubuntu-base.prepared. The base is never
# booted: every clone gets its own cloud-init seed (bootstrap-guest.sh), so its
# first boot is the image's first boot (no base host keys, users or cloud-init
# state carried over). With the marker present only the (idempotent)
# registration runs. --recreate rebuilds disk and VMX from the cloud image; the
# base must be off. Clones of the old base are rebuilt by ./lab up
# --allow-destroy (terraform_data.base_identity).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

recreate=0
case "${1:-}" in
  '') ;;
  --recreate) recreate=1 ;;
  *) echo 'Usage: ./lab setup [--recreate]' >&2; exit 2 ;;
esac

# Supported guest images. Guests need cloud-init, an SSH server, sudo and
# python3 (no VMware Tools). img_disk: the VMDK inside an OVA, empty for qcow2.
signed=1
case "$LAB_IMAGE" in
  ubuntu-24.04)
    img_url="${LAB_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current}"
    img_file=noble-server-cloudimg-amd64.ova; img_disk=ubuntu-noble-24.04-cloudimg.vmdk
    sums=SHA256SUMS; guest_os=ubuntu-64 ;;
  ubuntu-22.04)
    img_url="${LAB_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current}"
    img_file=jammy-server-cloudimg-amd64.ova; img_disk=ubuntu-jammy-22.04-cloudimg.vmdk
    sums=SHA256SUMS; guest_os=ubuntu-64 ;;
  debian-13)
    # Debian publishes no signature for cloud images: the checksum list comes
    # over HTTPS from cloud.debian.org only.
    img_url=https://cloud.debian.org/images/cloud/trixie/latest
    img_file=debian-13-generic-amd64.qcow2; img_disk=''
    sums=SHA512SUMS; guest_os=debian12-64; signed=0 ;;
  *) echo "[ERROR] Unknown LAB_IMAGE '$LAB_IMAGE' (supported: ubuntu-24.04, ubuntu-22.04, debian-13)" >&2; exit 2 ;;
esac
sumcmd=sha256sum; [[ $sums == SHA512SUMS ]] && sumcmd=sha512sum
vm_disk="$LAB_BASE_DIR/ubuntu-base.vmdk"
vmx="$LAB_BASE_DIR/ubuntu-base.vmx"
prepared="$LAB_BASE_DIR/ubuntu-base.prepared"
vmx_win=""

register() {
  lab_require_credentials
  python3 "$LAB_PROJECT_DIR/lib/register-vm.py" "$vmx" "$LAB_BASE_NAME"
}

if [[ -f "$prepared" && $recreate -eq 0 ]]; then
  built=$(sed -n 's/^image=//p' "$prepared"); built=${built:-ubuntu-24.04}   # older markers: 24.04
  if [[ "$built" != "$LAB_IMAGE" ]]; then
    echo "[ERROR] The base was built from $built, but LAB_IMAGE is $LAB_IMAGE. Rebuild it: ./lab setup --recreate" >&2
    echo '        (then ./lab up --allow-destroy replaces the clones; their contents are lost)' >&2
    exit 1
  fi
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

# 1. Image: for Ubuntu the signature of SHA256SUMS must verify (#22); then the
# image checksum.
cd "$LAB_PROJECT_DIR"
curl -fsS -o "$sums" "$img_url/$sums"
if [[ $signed -eq 1 ]]; then
  keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
  [[ -f "$keyring" ]] || { echo "[ERROR] $keyring missing; install ubuntu-cloudimage-keyring (sudo apt-get install ubuntu-cloudimage-keyring)" >&2; exit 1; }
  curl -fsS -o "$sums.gpg" "$img_url/$sums.gpg"
  gpgv --keyring "$keyring" "$sums.gpg" "$sums"
fi
grep -q " \*\?${img_file}\$" "$sums" || { echo "[ERROR] $img_file not listed in $sums" >&2; exit 1; }
if ! { [[ -f "$img_file" ]] && $sumcmd --ignore-missing -c "$sums" 2>/dev/null | grep -q "^${img_file}: OK$"; }; then
  curl -fSL --retry 3 -o "$img_file.part" "$img_url/$img_file"
  mv -f "$img_file.part" "$img_file"
  $sumcmd --ignore-missing -c "$sums"
fi
if [[ $signed -eq 1 ]]; then echo "[OK] $img_file verified (signed $sums)"
else echo "[OK] $img_file verified ($sums from $img_url over HTTPS; not signed)"; fi

# 2. Disk: extract, convert to a temporary file, check, then rename.
mkdir -p "$LAB_BASE_DIR"
[[ $recreate -eq 1 ]] && rm -f -- "$vm_disk" "$vm_disk.partial" "$prepared"
if [[ ! -f "$vm_disk" ]]; then
  if [[ -n "$img_disk" ]]; then
    tar -xf "$img_file" -C "$LAB_BASE_DIR"
    source_disk="$LAB_BASE_DIR/$img_disk"; source_fmt=vmdk
  else
    source_disk="$LAB_PROJECT_DIR/$img_file"; source_fmt=qcow2
  fi
  rm -f -- "$vm_disk.partial"
  qemu-img convert -p -f "$source_fmt" -O vmdk -o subformat=monolithicSparse "$source_disk" "$vm_disk.partial"
  want=$(qemu-img info --output=json -f "$source_fmt" "$source_disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
  got=$(qemu-img info --output=json -f vmdk "$vm_disk.partial" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["format"], d["virtual-size"])')
  [[ "$got" == "vmdk $want" ]] || { echo "[ERROR] Converted disk does not check out ($got, expected vmdk $want); left at $vm_disk.partial" >&2; exit 1; }
  mv -f -- "$vm_disk.partial" "$vm_disk"
  echo "[OK] Base disk converted: $vm_disk"
fi

# 3. The lab SSH key that clones authorize for the guest user.
mkdir -p "$LAB_PRIVATE_DIR"
chmod 700 "$LAB_PRIVATE_DIR"
[[ -f "$LAB_SSH_KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C wsl-vmware-lab -f "$LAB_SSH_KEY"
chmod 600 "$LAB_SSH_KEY"

# 4. VMX: written once; an existing one (Workstation rewrites it) must still
# name this display name and disk.
new_vmx=$(mktemp "$vmx.XXXXXX")
trap 'rm -f -- "$new_vmx"' EXIT
cat > "$new_vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "10"
displayName = "${LAB_BASE_NAME}"
annotation = "${LAB_IMAGE} base template for Terraform"
guestOS = "${guest_os}"
firmware = "efi"
memsize = "1024"
numvcpus = "2"
cpuid.coresPerSocket = "2"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "ubuntu-base.vmdk"
scsi0:0.deviceType = "scsi-hardDisk"
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
  for key in displayName 'scsi0:0\.fileName'; do
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

# 5. Register with vmrest and mark the base prepared. The base stays off.
register
printf 'image=%s\nboot=never\nprepared=%s\n' "$LAB_IMAGE" "$(date -Is)" > "$prepared"
echo "[OK] Base prepared (not booted; clones boot the image fresh): $vmx"
