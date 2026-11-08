#!/usr/bin/env bash
# Read-only Terraform diagnosis: shows the VM list in use, the state, the base
# VM's power state and what a plan would change. It never applies, destroys or
# powers anything off. Use terraform-vm.sh for changes.
# WSL: bash extras/diagnose-terraform.sh [on|off]   (power_state to plan with; default off)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
lab_terraform_env
power="${1:-off}"
[[ "$power" == on || "$power" == off ]] || { echo 'Usage: bash extras/diagnose-terraform.sh [on|off]' >&2; exit 2; }

echo '== VM list'
if [[ ${#LAB_TF_VAR_ARGS[@]} -gt 0 ]]; then
  echo "[OK] $LAB_VMS_FILE"
else
  echo "[WARN] $LAB_VMS_FILE not found; using the single fallback VM $LAB_CLONE_NAME"
fi

echo '== Base VM power'
base_vmx=$(wslpath -w "${LAB_BASE_DIR}/ubuntu-base.vmx")
if running=$("${VMWARE_DIR}/vmrun.exe" -T ws list 2>&1 | tr -d '\r'); then
  if grep -Fxiq "$base_vmx" <<<"$running"; then echo "[INFO] base is running: $base_vmx"; else echo "[OK] base is not running"; fi
else
  echo "[WARN] could not list running VMs: $running"
fi

echo '== Base VM identity'
if lab_base_identity; then
  echo "[OK] exactly one VM is named $LAB_BASE_NAME: $TF_VAR_base_id"
else
  echo "[WARN] terraform-vm.sh on/off would stop here (see above); planning without the id check"
  prepared="$LAB_BASE_DIR/ubuntu-base.prepared"
  [[ -f "$prepared" ]] && TF_VAR_base_prepared=$(sha256sum < "$prepared" | cut -d' ' -f1) && export TF_VAR_base_prepared
fi

cd "$LAB_PROJECT_DIR/terraform"
# init only installs the pinned provider locally; it does not touch VMs.
terraform init -input=false >/dev/null

echo '== Terraform state'
terraform state list 2>/dev/null || echo '(empty or unreadable)'

echo "== Plan (power_state=$power, not applied; no plan file is saved)"
plan=$(mktemp); trap 'rm -f "$plan"' EXIT
rc=0
terraform plan -input=false -lock=false -json "${LAB_TF_VAR_ARGS[@]}" -var=power_state="$power" > "$plan" || rc=$?
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
for action, addr in changes:
    tag = "[WARN]" if action in ("delete", "replace") else "[INFO]"
    print(f"{tag} {action}: {addr}")
if any(a in ("delete", "replace") for a, _ in changes):
    print("[WARN] the plan deletes or replaces VMs; check the VM list before any terraform-vm.sh command")
    print("       (replacements of every clone after prepare-base.sh --recreate are expected: on --allow-destroy)")
PY
exit "$rc"
