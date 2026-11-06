#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

source_disk="${LAB_BASE_DIR}/ubuntu-noble-24.04-cloudimg.vmdk"
vm_disk="${LAB_BASE_DIR}/ubuntu-base.vmdk"
vmx="${LAB_BASE_DIR}/ubuntu-base.vmx"
seed="${LAB_PROJECT_DIR}/cloud-init/seed.iso"

if [[ ! -f "${source_disk}" ]]; then
  echo "Missing the extracted Ubuntu cloud image: ${source_disk}" >&2
  exit 1
fi
if [[ ! -f "${seed}" ]]; then
  echo "Create the cloud-init seed first: bash prepare-cloud-init.sh" >&2
  exit 1
fi

if [[ ! -f "${vm_disk}" ]]; then
  qemu-img convert -p -f vmdk -O vmdk -o subformat=monolithicSparse "${source_disk}" "${vm_disk}"
fi

seed_rel="$(realpath --relative-to="${LAB_BASE_DIR}" "${seed}")"
cat > "${vmx}" <<VMX
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

echo "Base VMX created: ${vmx}"
qemu-img info "${vm_disk}" | sed -n '1,8p'
