#!/usr/bin/env bash
# Legacy entry point kept for older blog instructions; prefer register-base.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
bash register-base.sh "$@"
