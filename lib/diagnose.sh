#!/usr/bin/env bash
# Read-only Terraform diagnosis: shows the VM list in use, the state, the base
# VM's power state and what a plan would change. It never applies, destroys or
# powers anything off. Use ./lab up/down/destroy for changes.
# ./lab status --plan (preserve live power)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
lab_terraform_env
[[ $# -eq 0 ]] || { echo 'Usage: ./lab status --plan' >&2; exit 2; }

echo '== VM list'
if [[ ${#LAB_TF_VAR_ARGS[@]} -gt 0 ]]; then
  echo "[OK] $LAB_VMS_FILE"
else
  echo "[WARN] $LAB_VMS_FILE not found; using the single fallback VM $LAB_CLONE_NAME"
fi

echo '== Base VMs (one per image in use)'
running=$(timeout 60 "${VMWARE_DIR}/vmrun.exe" -T ws list 2>&1 | tr -d '\r') || { echo "[WARN] could not list running VMs: $running"; running=''; }
for image in $(lab_used_images); do
  base_vmx=$(wslpath -w "$LAB_BASE_DIR/$image/base.vmx")
  if grep -Fxiq "$base_vmx" <<<"$running"; then echo "[INFO] $image-base is running: $base_vmx"; else echo "[OK] $image-base is not running"; fi
done
if lab_base_identity; then
  echo "[OK] every base in use is registered exactly once: $TF_VAR_bases"
else
  echo "[WARN] ./lab up/down would stop here (see above); planning without the base checks"
fi

cd "$LAB_PROJECT_DIR/terraform"
# init only installs the pinned provider locally; it does not touch VMs.
terraform init -input=false >/dev/null

echo '== Terraform state'
terraform state list 2>/dev/null || echo '(empty or unreadable)'

TF_VAR_power_states=$(terraform show -json | python3 ../lib/power-map.py seed)
export TF_VAR_power_states
echo '== Plan (live power preserved, not applied; no plan file is saved)'
plan=$(mktemp); trap 'rm -f "$plan"' EXIT
rc=0
terraform plan -input=false -lock=false -json "${LAB_TF_VAR_ARGS[@]}" -var="power_states=$TF_VAR_power_states" > "$plan" || rc=$?
python3 - "$plan" <<'PY'
import json, sys
changes, errors = [], []
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("@level") == "error":
        d = m.get("diagnostic", {})
        msg = d.get("summary") or m.get("@message", "")
        if d.get("detail"):
            msg += ": " + d["detail"]
        if d.get("address"):
            msg += " (at " + d["address"] + ")"
        errors.append(msg)
    if m.get("type") == "planned_change":
        c = m["change"]
        changes.append((c.get("action"), c["resource"].get("addr")))
for e in errors:
    print("[ERROR] " + e)
if not changes and not errors:
    print("[OK] no changes")
def vm_loss(action, addr):
    return action in ("delete", "replace") and addr.startswith("vmworkstation_virtual_machine.")
for action, addr in changes:
    tag = "[WARN]" if vm_loss(action, addr) else "[INFO]"
    print(f"{tag} {action}: {addr}")
if any(vm_loss(a, addr) for a, addr in changes):
    print("[WARN] the plan deletes or replaces VMs; check the VM list before ./lab up --allow-destroy")
    print("       (after ./lab setup --recreate or an image change, those clones are expected to be replaced)")
PY
exit "$rc"
