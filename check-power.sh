#!/usr/bin/env bash
# bash check-power.sh [VM_ID]   (default: the clone in this Terraform state)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
lab_require_credentials
vm_id="${1:-$(terraform -chdir="$LAB_PROJECT_DIR/terraform" output -raw ubuntu_demo_id)}"
curl -fsS -K - "${VMWS_ENDPOINT%/}/vms/${vm_id}/power" < <(lab_curl_auth)
