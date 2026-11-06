#!/usr/bin/env bash
# bash check-power.sh [NAME|VM_ID]   (default: every VM in this Terraform state)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
lab_require_credentials
power() { curl -fsS -K - "${VMWS_ENDPOINT%/}/vms/$1/power" < <(lab_curl_auth) | tr -d '\n '; echo; }
vms=$(terraform -chdir="$LAB_PROJECT_DIR/terraform" output -json vms 2>/dev/null || echo '{}')
if [[ $# -gt 0 ]]; then
  id=$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]); print(v[sys.argv[2]]["id"] if sys.argv[2] in v else sys.argv[2])' "$vms" "$1")
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "[ERROR] Invalid VM name or id" >&2; exit 2; }
  power "$id"
  exit
fi
python3 -c 'import json,sys; [print(k, v["id"]) for k, v in sorted(json.loads(sys.argv[1]).items())]' "$vms" |
while read -r name id; do
  printf '%s: ' "$name"; power "$id"
done
