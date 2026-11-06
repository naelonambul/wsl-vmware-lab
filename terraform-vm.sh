#!/usr/bin/env bash
# WSL: bash terraform-vm.sh on|off|status|destroy [terraform args]
# VMs come from vms.tfvars (LAB_VMS_FILE) if present, else one VM from lab.env.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
lab_terraform_env
cd "$LAB_PROJECT_DIR/terraform"
if [[ "${1:-status}" != status ]]; then
  if ! api_code=$(curl --connect-timeout 3 --max-time 8 -sS -o /dev/null -w '%{http_code}' \
    -K - "${TF_VAR_vmrest_endpoint%/}/vms" < <(lab_curl_auth)); then
    echo '[ERROR] vmrest API unreachable. Start vmrest on Windows and check the endpoint.' >&2
    exit 1
  fi
  if [[ "$api_code" != 200 ]]; then
    echo "[ERROR] vmrest API returned HTTP $api_code; check credentials and endpoint." >&2
    exit 1
  fi
fi
terraform init -input=false >/dev/null
[[ ${#LAB_TF_VAR_ARGS[@]} -gt 0 ]] && echo "[OK] VM list: $LAB_VMS_FILE" || echo "[OK] VM list: single VM $LAB_CLONE_NAME (no vms.tfvars)"

state_json() { terraform show -json; }
before=$(mktemp); after=$(mktemp); plan=$(mktemp)
trap 'rm -f "$before" "$after" "$plan"' EXIT

# Apply, then clean up after VMs the apply removed (dropped from the list).
# Cleanup also runs when the apply fails part-way, so a VM it did delete is
# not left with its seed ISO, known_hosts and folder.
apply_and_clean() {
  local rc=0
  state_json > "$before"
  terraform apply -input=false -auto-approve -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" "$@" || rc=$?
  state_json > "$after"
  python3 ../cleanup-guest.py "$before" "$after" || { [[ $rc -ne 0 ]] || rc=1; }
  return "$rc"
}

# Print the names Terraform would create with the current list (new entries,
# or VMs whose bootstrap never finished). `plan -json` streams messages; no
# plan file is written (a saved plan would contain the vmrest password).
planned_new_vms() {
  if ! terraform plan -input=false -lock=false -json "${LAB_TF_VAR_ARGS[@]}" -var=power_state=off > "$plan"; then
    python3 -c 'import json, sys
for line in open(sys.argv[1]):
    m = json.loads(line)
    if m.get("@level") == "error":
        print("[ERROR] " + m.get("@message", ""), file=sys.stderr)' "$plan"
    return 1
  fi
  python3 -c 'import json, sys
names = set()
for line in open(sys.argv[1]):
    m = json.loads(line)
    if m.get("type") != "planned_change":
        continue
    c = m["change"]; r = c["resource"]
    if c.get("action") in ("create", "replace") and r.get("resource_name") in ("vm", "guest_bootstrap") \
       and r.get("resource_type") in ("vmworkstation_virtual_machine", "terraform_data"):
        names.add(str(r.get("resource_key")))
sys.stdout.write("".join(n + "\n" for n in sorted(names)))' "$plan"
}

# Targets for the VMs that already exist in the state.
existing_targets() {
  terraform state list 2>/dev/null | grep -E '^vmworkstation_virtual_machine\.vm\[' | sed 's/^/-target=/' || true
}

case "${1:-status}" in
  on)
    # Bootstrap needs a powered-off clone: create new VMs off first, targeting
    # only them so VMs that are already running stay on.
    new_vms=$(planned_new_vms)
    targets=()
    root_unix=$(wslpath -u "$LAB_VM_ROOT_WIN")
    for name in $new_vms; do
      [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "[ERROR] Unexpected VM name from plan: $name" >&2; exit 1; }
      # A folder left by an earlier failed create (VM not in the state) makes
      # vmrest answer 409. Stop and let the user decide; never delete it here.
      if [[ -d "$root_unix/$name" ]] && [[ -n "$(ls -A "$root_unix/$name")" ]] \
         && ! terraform state list 2>/dev/null | grep -Fxq "vmworkstation_virtual_machine.vm[\"$name\"]"; then
        echo "[ERROR] $LAB_VM_ROOT_WIN\\$name already has files but $name is not in the Terraform state:" >&2
        ls -A "$root_unix/$name" | sed 's/^/          /' >&2
        echo "        Check 'bash api-status.sh'. Remove that VM in VMware Workstation (or rename the entry), then retry." >&2
        exit 1
      fi
      targets+=(-target="vmworkstation_virtual_machine.vm[\"$name\"]" -target="terraform_data.guest_bootstrap[\"$name\"]")
    done
    if [[ ${#targets[@]} -gt 0 ]]; then
      echo "[OK] New VMs to prepare (powered off first): $new_vms" | tr '\n' ' '; echo
      terraform apply -input=false -auto-approve -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" \
        -var=power_state=off "${targets[@]}"
    fi
    apply_and_clean -var=power_state=on
    ;;
  off)
    # Power off only the VMs that exist; never create list entries here.
    mapfile -t targets < <(existing_targets)
    if [[ ${#targets[@]} -eq 0 ]]; then echo '[OK] No VMs in the state'; exit 0; fi
    state_json > "$before"
    terraform apply -input=false -auto-approve -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" \
      -var=power_state=off "${targets[@]}"
    ;;
  status) terraform show -no-color ;;
  destroy)
    state_json > "$before"
    rc=0
    terraform destroy -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" "${@:2}" || rc=$?
    state_json > "$after"
    python3 ../cleanup-guest.py "$before" "$after" || { [[ $rc -ne 0 ]] || rc=1; }
    exit "$rc"
    ;;
  *) echo 'Usage: bash terraform-vm.sh on|off|status|destroy' >&2; exit 2 ;;
esac
