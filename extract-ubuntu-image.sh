#!/usr/bin/env bash
# Extract the VMDK from the Ubuntu OVA. Default OVA: the file fetched by
# download-ubuntu-image.sh; the older blog file name is still accepted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
ova="${1:-}"
if [[ -z "$ova" ]]; then
  for candidate in noble-server-cloudimg-amd64.ova ubuntu-24.04-server-cloudimg-amd64.ova; do
    [[ -f "${LAB_PROJECT_DIR}/${candidate}" ]] && { ova="${LAB_PROJECT_DIR}/${candidate}"; break; }
  done
fi
[[ -n "$ova" && -f "$ova" ]] || { echo "No OVA found; run: bash download-ubuntu-image.sh" >&2; exit 1; }
mkdir -p "${LAB_BASE_DIR}"
tar -xf "${ova}" -C "${LAB_BASE_DIR}"
qemu-img info "${LAB_BASE_DIR}/ubuntu-noble-24.04-cloudimg.vmdk"
