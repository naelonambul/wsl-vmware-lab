#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
lab_require_credentials
curl -fsS -K - "${VMWS_ENDPOINT%/}/vms" <<<"user = \"${VMWS_USERNAME}:${VMWS_PASSWORD}\""
