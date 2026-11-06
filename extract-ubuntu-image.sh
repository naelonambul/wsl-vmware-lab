#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
ova="${1:-${LAB_PROJECT_DIR}/ubuntu-24.04-server-cloudimg-amd64.ova}"
mkdir -p "${LAB_BASE_DIR}"
tar -xf "${ova}" -C "${LAB_BASE_DIR}"
qemu-img info "${LAB_BASE_DIR}/ubuntu-noble-24.04-cloudimg.vmdk"
