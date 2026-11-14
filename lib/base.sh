#!/usr/bin/env bash
# Base VM preparation, run by ./lab setup [--recreate] (WSL).
#
# One base per image the VM list uses (lab_used_images: LAB_IMAGE plus every
# image = "..." in vms.tfvars). Per image: cloud image -> checksum (and
# signature where the distribution publishes one) -> monolithic VMDK ->
# base/<image>/base.vmx, VM "<image>-base" -> vmrest registration -> marker
# base/<image>/base.prepared. Bases are never booted: every clone gets its own
# cloud-init seed (bootstrap-guest.sh), so its first boot is the image's first
# boot. With the marker present only the (idempotent) registration runs.
# --recreate rebuilds every base in use from its cloud image; bases must be
# off. Clones of a rebuilt base are rebuilt by ./lab up --allow-destroy
# (terraform_data.vm_base).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

recreate=0
case "${1:-}" in
  '') ;;
  --recreate) recreate=1 ;;
  *) echo 'Usage: ./lab setup [--recreate]' >&2; exit 2 ;;
esac

prepare_base() {
  local image=$1
  # Supported guest images. Guests need cloud-init, an SSH server, sudo and
  # python3 (no VMware Tools). img_disk: the VMDK inside an OVA, empty for qcow2.
  local signed=1 img_url img_file img_disk sums guest_os sumcmd dir name vm_disk vmx prepared vmx_win new_vmx source_disk source_fmt want got power actual_value expected_value
  case "$image" in
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
    *) lab_fail config_error "Unknown image: $image (supported: ubuntu-24.04, ubuntu-22.04, debian-13)" ;;
  esac
  sumcmd=sha256sum; [[ $sums == SHA512SUMS ]] && sumcmd=sha512sum
  dir="$LAB_BASE_DIR/$image"
  name="$image-base"
  vm_disk="$dir/base.vmdk"
  vmx="$dir/base.vmx"
  prepared="$dir/base.prepared"
  vmx_win=""

  register() {
    lab_require_credentials
    python3 "$LAB_PROJECT_DIR/lib/register-vm.py" "$vmx" "$name"
  }

  if [[ -f "$prepared" && $recreate -eq 0 ]]; then
    register
    echo "[OK] Base $name already prepared ($prepared). To rebuild it: ./lab setup --recreate"
    return 0
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
  lab_require_credentials
  cd "$LAB_PROJECT_DIR"
  python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
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
  mkdir -p "$dir"
  [[ $recreate -eq 1 ]] && rm -f -- "$vm_disk" "$vm_disk.partial" "$prepared"
  if [[ ! -f "$vm_disk" ]]; then
    if [[ -n "$img_disk" ]]; then
      tar -xf "$img_file" -C "$dir"
      source_disk="$dir/$img_disk"; source_fmt=vmdk
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

  # 4. VMX: written once; an existing one (Workstation rewrites it) must still
  # name this display name and disk.
  new_vmx=$(mktemp "$vmx.XXXXXX")
  cat > "$new_vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "10"
displayName = "${name}"
annotation = "${image} base template for Terraform"
guestOS = "${guest_os}"
firmware = "efi"
memsize = "1024"
numvcpus = "2"
cpuid.coresPerSocket = "2"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "base.vmdk"
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
      actual_value=$(value "$vmx" "$key") || lab_fail config_error "Cannot read $key from $vmx"
      expected_value=$(value "$new_vmx" "$key") || lab_fail config_error "Cannot read $key from $new_vmx"
      [[ -n "$actual_value" && "$actual_value" == "$expected_value" ]] || {
        echo "[ERROR] $vmx has ${key//\\/} = \"$(value "$vmx" "$key")\", expected \"$(value "$new_vmx" "$key")\"; left unchanged." >&2
        echo '        Rebuild the base: ./lab setup --recreate' >&2
        exit 1; }
    done
  else
    chmod 644 "$new_vmx"
    mv -f -- "$new_vmx" "$vmx"
    echo "[OK] Base VMX written: $vmx"
  fi
  rm -f -- "$new_vmx"

  # 5. Register with vmrest and mark the base prepared. The base stays off.
  register
  printf 'image=%s\nboot=never\nprepared=%s\n' "$image" "$(date -Is)" > "$prepared"
  echo "[OK] Base $name prepared (not booted; clones boot the image fresh): $vmx"
}

# The lab SSH key that clones authorize for the guest user.
# Resolve and validate the entire image set before creating keys or files.
images=$(lab_used_images) || lab_fail config_error 'Cannot read the configured image set.'
[[ -n "$images" ]] || lab_fail config_error 'The configured image set is empty.'
for image in $images; do
  case "$image" in
    ubuntu-24.04|ubuntu-22.04|debian-13) ;;
    *) lab_fail config_error "Unknown image: $image (supported: ubuntu-24.04, ubuntu-22.04, debian-13)" ;;
  esac
done
lab_require_credentials
if [[ ! -d "$LAB_PRIVATE_DIR" ]]; then
  python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
  mkdir -p "$LAB_PRIVATE_DIR"
fi
if [[ "$(stat -c %a "$LAB_PRIVATE_DIR")" != 700 ]]; then
  python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
  chmod 700 "$LAB_PRIVATE_DIR"
fi
if [[ ! -f "$LAB_SSH_KEY" ]]; then
  python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
  ssh-keygen -q -t ed25519 -N '' -C wsl-vmware-lab -f "$LAB_SSH_KEY"
fi
if [[ "$(stat -c %a "$LAB_SSH_KEY")" != 600 ]]; then
  python3 "$LAB_PROJECT_DIR/lib/envelope.py" changed
  chmod 600 "$LAB_SSH_KEY"
fi

for image in $images; do
  echo "== Base for $image"
  prepare_base "$image"
done
old="$LAB_BASE_DIR/ubuntu-base.vmx"
if [[ -f "$old" ]]; then
  echo "[INFO] $old (VM ubuntu24-base) is from an earlier version and no longer used."
  echo '       Once no clone needs it, remove it from VMware Workstation and delete base/ubuntu-base.*'
fi
