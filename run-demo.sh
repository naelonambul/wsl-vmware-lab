#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bash ./terraform-vm.sh "${1:-status}"
