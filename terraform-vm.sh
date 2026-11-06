#!/usr/bin/env bash
# WSL: bash terraform-vm.sh on|off|status|destroy
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
lab_terraform_env
cd "$LAB_PROJECT_DIR/terraform"
if [[ "${1:-status}" != status ]]; then
  if ! api_code=$(curl --connect-timeout 3 --max-time 8 -sS -o /dev/null -w '%{http_code}' \
    -K - "${TF_VAR_vmrest_endpoint%/}/vms" <<<"user = \"${VMWS_USERNAME}:${VMWS_PASSWORD}\""); then
    echo '[ERROR] vmrest API unreachable. Start vmrest on Windows and check the endpoint.' >&2
    exit 1
  fi
  if [[ "$api_code" != 200 ]]; then
    echo "[ERROR] vmrest API returned HTTP $api_code; check credentials and endpoint." >&2
    exit 1
  fi
fi
terraform init -input=false
case "${1:-status}" in
  on)
    if [[ ! -f terraform.tfstate ]] || ! terraform state list | grep -qx 'terraform_data.guest_bootstrap'; then
      terraform apply -input=false -auto-approve -parallelism=1 -var=power_state=off
    fi
    terraform apply -input=false -auto-approve -parallelism=1 -var=power_state=on
    ;;
  off) terraform apply -input=false -auto-approve -parallelism=1 -var=power_state=off ;;
  status) terraform show -no-color ;;
  destroy)
    (
      metadata=$(mktemp)
      trap 'rm -f "$metadata"' EXIT
      terraform show -json > "$metadata"
      terraform destroy -parallelism=1 "${@:2}"
      python3 ../cleanup-guest.py "$metadata"
    )
    ;;
  *) echo 'Usage: bash terraform-vm.sh on|off|status|destroy' >&2; exit 2 ;;
esac
