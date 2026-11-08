#!/usr/bin/env bash
# Create the base disk and VMX from the extracted Ubuntu cloud image.
# Usage: bash create-base-template.sh [--recreate]
# Safe to re-run: the disk is converted to a temporary file and renamed only
# after it checks out (marker ubuntu-base.vmdk.complete), and an existing VMX
# that differs is never overwritten. --recreate rebuilds disk and VMX from the
# cloud image; the base must be powered off.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

recreate=0
for arg in "$@"; do
  case "$arg" in
    --recreate) recreate=1 ;;
    *) echo "Usage: bash create-base-template.sh [--recreate]" >&2; exit 2 ;;
  esac
done

source_disk="${LAB_BASE_DIR}/ubuntu-noble-24.04-cloudimg.vmdk"
vm_disk="${LAB_BASE_DIR}/ubuntu-base.vmdk"
disk_marker="${vm_disk}.complete"
partial="${vm_disk}.partial"
vmx="${LAB_BASE_DIR}/ubuntu-base.vmx"
prepared="${LAB_BASE_DIR}/ubuntu-base.prepared"
seed="${LAB_PROJECT_DIR}/cloud-init/seed.iso"

if [[ ! -f "${source_disk}" ]]; then
  echo "Missing the extracted Ubuntu cloud image: ${source_disk}" >&2
  exit 1
fi
if [[ ! -f "${seed}" ]]; then
  echo "Create the cloud-init seed first: bash prepare-cloud-init.sh" >&2
  exit 1
fi

# Never change files of a running (or possibly running) base.
if [[ -e "$vmx" || -e "$vm_disk" ]]; then
  power=0; lab_vm_running "$(wslpath -w "$vmx")" || power=$?
  if [[ $power -eq 0 ]]; then
    echo "[ERROR] The base VM is running; shut it down before changing it: $vmx" >&2
    exit 1
  elif [[ $power -ne 1 ]]; then
    echo "[ERROR] Could not confirm the base VM is powered off; nothing changed." >&2
    exit 1
  fi
fi

if [[ $recreate -eq 1 ]]; then
  rm -f -- "$vm_disk" "$disk_marker" "$partial" "$prepared"
  echo "[OK] --recreate: removed the old base disk; rebuilding from the cloud image"
fi

if [[ -f "$vm_disk" && ! -f "$disk_marker" ]]; then
  echo "[ERROR] $vm_disk exists without $disk_marker: it may be a partial conversion." >&2
  echo "        Rebuild it: ./lab setup --recreate" >&2
  echo "        (A base prepared by an older version that works: touch \"$disk_marker\" \"$prepared\")" >&2
  exit 1
fi

if [[ ! -f "$vm_disk" ]]; then
  rm -f -- "$partial"
  qemu-img convert -p -f vmdk -O vmdk -o subformat=monolithicSparse "${source_disk}" "${partial}"
  # The converted disk must read back as a VMDK of the source's virtual size.
  read -r want < <(qemu-img info --output=json "$source_disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
  read -r got_fmt got_size < <(qemu-img info --output=json -f vmdk "$partial" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["format"], d["virtual-size"])')
  if [[ "$got_fmt" != vmdk || "$got_size" != "$want" ]]; then
    echo "[ERROR] Converted disk does not check out (format $got_fmt, size $got_size, expected $want); left at $partial" >&2
    exit 1
  fi
  mv -f -- "$partial" "$vm_disk"
  printf 'source=%s\nvirtual_size=%s\nconverted=%s\n' "$(basename "$source_disk")" "$want" "$(date -Is)" > "$disk_marker"
  echo "[OK] Base disk converted: $vm_disk"
fi

seed_rel="$(realpath --relative-to="${LAB_BASE_DIR}" "${seed}")"
new_vmx=$(mktemp "${vmx}.XXXXXX")
trap 'rm -f -- "$new_vmx"' EXIT
cat > "${new_vmx}" <<VMX
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
  # Keep an existing VMX: Workstation rewrites it (CRLF, its own values and
  # extra lines). Only the values the lab relies on must match.
  vmx_value() { tr -d '\r' < "$1" | sed -nE 's/^[[:space:]]*'"$2"'[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' | tail -n 1; }
  mismatch=""
  for key in displayName 'scsi0:0\.fileName' 'ide1:0\.fileName'; do
    have=$(vmx_value "$vmx" "$key"); want=$(vmx_value "$new_vmx" "$key")
    [[ "$have" == "$want" ]] || mismatch+="${key//\\/} = \"$have\" (expected \"$want\")"$'\n'
  done
  if [[ -n "$mismatch" ]]; then
    echo "[ERROR] $vmx exists with different settings; left unchanged:" >&2
    printf '%s' "$mismatch" | sed 's/^/        /' >&2
    echo "        Fix lab.env (LAB_BASE_NAME), or rebuild the base: ./lab setup --recreate" >&2
    exit 1
  fi
  echo "[OK] Base VMX already in place: $vmx"
else
  chmod 644 "$new_vmx"
  mv -f -- "$new_vmx" "$vmx"
  echo "Base VMX created: ${vmx}"
fi
qemu-img info "${vm_disk}" | sed -n '1,8p'
