#!/usr/bin/env bash
# Run inside WSL: bash register-base.sh [VMX_PATH] [DISPLAY_NAME]
# Requires mirrored networking, running Windows vmrest, python3 and wslpath.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
lab_require_credentials
python3 "$LAB_PROJECT_DIR/register-vm.py" "${1:-$LAB_BASE_DIR/ubuntu-base.vmx}" "${2:-$LAB_BASE_NAME}"
