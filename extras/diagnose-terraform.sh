#!/usr/bin/env bash
# WARNING: soft-stops the BASE VM and applies power_state=off to the Terraform clone.
# Review before running; this is a troubleshooting record, not part of the workflow.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
lab_terraform_env
vmx=$(wslpath -w "${LAB_BASE_DIR}/ubuntu-base.vmx")
"${VMWARE_DIR}/vmrun.exe" -T ws stop "$vmx" soft || true
cd "$LAB_PROJECT_DIR/terraform"
terraform apply -input=false -auto-approve -parallelism=1 -var=power_state=off -no-color
