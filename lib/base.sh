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
  local signed=1 img_url img_file img_disk sums img_sha256 guest_os sumcmd disk_bus=scsi nic_dev=e1000 disk_key
  local mods_rpm_url='' mods_rpm_file='' mods_rpm_sha256='' mods_iso='' mods_stage=''
  local dir name vm_disk vmx prepared vmx_win new_vmx source_disk source_fmt want got power actual_value expected_value
  case "$image" in
    ubuntu-24.04)
      img_url="${LAB_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current}"
      img_file=noble-server-cloudimg-amd64.ova; img_disk=ubuntu-noble-24.04-cloudimg.vmdk
      sums=SHA256SUMS; img_sha256=''; guest_os=ubuntu-64 ;;
    ubuntu-22.04)
      img_url="${LAB_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current}"
      img_file=jammy-server-cloudimg-amd64.ova; img_disk=ubuntu-jammy-22.04-cloudimg.vmdk
      sums=SHA256SUMS; img_sha256=''; guest_os=ubuntu-64 ;;
    debian-13)
      # Debian publishes no signature for cloud images: the checksum list comes
      # over HTTPS from cloud.debian.org only.
      img_url=https://cloud.debian.org/images/cloud/trixie/latest
      img_file=debian-13-generic-amd64.qcow2; img_disk=''
      sums=SHA512SUMS; img_sha256=''; guest_os=debian12-64; signed=0 ;;
    debian-12)
      # Debian publishes no signature for cloud images: the checksum list comes
      # over HTTPS from cloud.debian.org only.
      img_url=https://cloud.debian.org/images/cloud/bookworm/latest
      img_file=debian-12-generic-amd64.qcow2; img_disk=''
      sums=SHA512SUMS; img_sha256=''; guest_os=debian12-64; signed=0 ;;
    rocky-9)
      # Rocky Linux publishes BSD-style SHA256 CHECKSUM over HTTPS (not GPG-verified here).
      img_url=https://dl.rockylinux.org/pub/rocky/9/images/x86_64
      img_file=Rocky-9-GenericCloud-Base.latest.x86_64.qcow2; img_disk=''
      sums=Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.CHECKSUM; img_sha256=''
      guest_os=rhel9-64; signed=0; disk_bus=sata; nic_dev=vmxnet3 ;;
    almalinux-9)
      # AlmaLinux publishes GNU-style SHA256 CHECKSUM over HTTPS (not GPG-verified here).
      img_url=https://repo.almalinux.org/almalinux/9/cloud/x86_64/images
      img_file=AlmaLinux-9-GenericCloud-latest.x86_64.qcow2; img_disk=''
      sums=CHECKSUM; img_sha256=''
      guest_os=rhel9-64; signed=0; disk_bus=sata; nic_dev=vmxnet3 ;;
    oraclelinux-8)
      # Oracle publishes SHA256 hashes on oracle-linux-templates.html (not signed)
      # and ships kernel-uek-core without VMware NIC modules; mods.iso carries
      # the matching kernel-uek-modules RPM for offline first-boot installation.
      img_url=https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64
      img_file=OL8U10_x86_64-kvm-b287.qcow2; img_disk=''
      sums=''; img_sha256=cf9eb243b7390311f1e2896e3e6849241e521e6592c8be9907956e3a6cee1f0c
      guest_os=oraclelinux8-64; signed=0; disk_bus=sata; nic_dev=vmxnet3
      mods_rpm_url=https://yum.oracle.com/repo/OracleLinux/OL8/UEKR7/x86_64/getPackage
      mods_rpm_file=kernel-uek-modules-5.15.0-320.202.8.5.el8uek.x86_64.rpm
      mods_rpm_sha256=c51b2181df065f85601a441fe9567831246ee206f9e2781d379657d2b5be500c ;;
    *) lab_fail config_error "Unknown image: $image (supported: ubuntu-24.04, ubuntu-22.04, debian-13, debian-12, rocky-9, almalinux-9, oraclelinux-8)" ;;
  esac
  sumcmd=sha256sum; [[ $sums == SHA512SUMS ]] && sumcmd=sha512sum
  dir="$LAB_BASE_DIR/$image"
  name="$image-base"
  vm_disk="$dir/base.vmdk"
  vmx="$dir/base.vmx"
  prepared="$dir/base.prepared"
  [[ -n "$mods_rpm_file" ]] && mods_iso="$dir/mods.iso"
  vmx_win=""

  register() {
    lab_require_credentials
    python3 "$LAB_PROJECT_DIR/lib/register-vm.py" "$vmx" "$name"
  }

  if [[ -f "$prepared" && $recreate -eq 0 && ( -z "$mods_iso" || -f "$mods_iso" ) ]]; then
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
  if [[ -n "$sums" ]]; then
    curl -fsS -o "$sums" "$img_url/$sums"
    if [[ $signed -eq 1 ]]; then
      keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
      [[ -f "$keyring" ]] || { echo "[ERROR] $keyring missing; install ubuntu-cloudimage-keyring (sudo apt-get install ubuntu-cloudimage-keyring)" >&2; exit 1; }
      curl -fsS -o "$sums.gpg" "$img_url/$sums.gpg"
      gpgv --keyring "$keyring" "$sums.gpg" "$sums"
    fi
    grep -qE "( \*?${img_file}\$|^SHA(256|512) \(${img_file}\) = )" "$sums" || { echo "[ERROR] $img_file not listed in $sums" >&2; exit 1; }
    if ! { [[ -f "$img_file" ]] && $sumcmd --ignore-missing -c "$sums" 2>/dev/null | grep -q "^${img_file}: OK$"; }; then
      curl -fSL --retry 3 -o "$img_file.part" "$img_url/$img_file"
      mv -f "$img_file.part" "$img_file"
      $sumcmd --ignore-missing -c "$sums"
    fi
    if [[ $signed -eq 1 ]]; then echo "[OK] $img_file verified (signed $sums)"
    else echo "[OK] $img_file verified ($sums from $img_url over HTTPS; not signed)"; fi
  else
    if ! { [[ -f "$img_file" ]] && printf '%s  %s\n' "$img_sha256" "$img_file" | sha256sum -c - >/dev/null 2>&1; }; then
      curl -fSL --retry 3 -o "$img_file.part" "$img_url/$img_file"
      mv -f "$img_file.part" "$img_file"
      printf '%s  %s\n' "$img_sha256" "$img_file" | sha256sum -c -
    fi
    echo "[OK] $img_file verified (pinned SHA256 from $img_url over HTTPS; not signed)"
  fi

  # 2. Disk: extract, convert to a temporary file, check, then rename.
  mkdir -p "$dir"
  [[ $recreate -eq 1 ]] && rm -f -- "$vm_disk" "$vm_disk.partial" "$prepared" ${mods_iso:+"$mods_iso" "$mods_iso.partial"}
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

  # 3. Optional offline kernel-modules ISO (shared read-only across clones).
  if [[ -n "$mods_iso" && ! -f "$mods_iso" ]]; then
    command -v genisoimage >/dev/null 2>&1 || { echo '[ERROR] genisoimage missing; run ./lab setup to install WSL tools' >&2; exit 1; }
    if ! { [[ -f "$mods_rpm_file" ]] && printf '%s  %s\n' "$mods_rpm_sha256" "$mods_rpm_file" | sha256sum -c - >/dev/null 2>&1; }; then
      curl -fSL --retry 3 -o "$mods_rpm_file.part" "$mods_rpm_url/$mods_rpm_file"
      mv -f "$mods_rpm_file.part" "$mods_rpm_file"
      printf '%s  %s\n' "$mods_rpm_sha256" "$mods_rpm_file" | sha256sum -c -
    fi
    echo "[OK] $mods_rpm_file verified (pinned SHA256 from $mods_rpm_url over HTTPS; not signed)"
    mods_stage=$(mktemp -d "$dir/mods-stage.XXXXXX")
    cp -- "$LAB_PROJECT_DIR/$mods_rpm_file" "$mods_stage/$mods_rpm_file"
    rm -f -- "$mods_iso.partial"
    if ! genisoimage -quiet -V OL8MODS -J -R -o "$mods_iso.partial" "$mods_stage"; then
      rm -rf -- "$mods_stage" "$mods_iso.partial"
      exit 1
    fi
    rm -rf -- "$mods_stage"
    mv -f -- "$mods_iso.partial" "$mods_iso"
    echo "[OK] Offline modules ISO built: $mods_iso"
  fi

  # 4. VMX: written once; an existing one (Workstation rewrites it) must still
  # name this display name and disk.
  new_vmx=$(mktemp "$vmx.XXXXXX")
  if [[ "$disk_bus" == sata ]]; then
    disk_key='sata0:0\.fileName'
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
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.fileName = "base.vmdk"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
ethernet0.present = "TRUE"
ethernet0.connectionType = "custom"
ethernet0.vnet = "${LAB_NAT_VNET}"
ethernet0.virtualDev = "${nic_dev}"
ethernet0.startConnected = "TRUE"
usb.present = "FALSE"
sound.present = "FALSE"
floppy0.present = "FALSE"
VMX
  else
    disk_key='scsi0:0\.fileName'
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
ethernet0.virtualDev = "${nic_dev}"
ethernet0.startConnected = "TRUE"
usb.present = "FALSE"
sound.present = "FALSE"
floppy0.present = "FALSE"
VMX
  fi
  if [[ -f "$vmx" && $recreate -eq 0 ]]; then
    value() { tr -d '\r' < "$1" | sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$/\1/p" | tail -n 1; }
    for key in displayName "$disk_key"; do
      actual_value=$(value "$vmx" "$key") || lab_fail config_error "Cannot read $key from $vmx"
      expected_value=$(value "$new_vmx" "$key") || lab_fail config_error "Cannot read $key from $new_vmx"
      [[ -n "$actual_value" && "$actual_value" == "$expected_value" ]] || {
        echo "[ERROR] $vmx: ${key//\\/} differs from the expected base settings; left unchanged." >&2
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
    ubuntu-24.04|ubuntu-22.04|debian-13|debian-12|rocky-9|almalinux-9|oraclelinux-8) ;;
    *) lab_fail config_error "Unknown image: $image (supported: ubuntu-24.04, ubuntu-22.04, debian-13, debian-12, rocky-9, almalinux-9, oraclelinux-8)" ;;
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
