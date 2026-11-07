#!/usr/bin/env bash
# WSL: bash terraform-vm.sh on [--allow-destroy] | off | status | cleanup | destroy [terraform args]
# VMs come from vms.tfvars (LAB_VMS_FILE) if present, else one VM from lab.env.
# on/off read the plan first: on refuses to delete or replace VMs unless
# --allow-destroy is given; off refuses anything but a power change.
# VMs that may be deleted are written to terraform/cleanup-pending.json first;
# their generated files are cleaned once they are gone, and a failed cleanup is
# retried by the next on/destroy/cleanup.
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
if [[ ${#LAB_TF_VAR_ARGS[@]} -gt 0 ]]; then vm_list_desc="$LAB_VMS_FILE"
else vm_list_desc="single VM $LAB_CLONE_NAME (no $LAB_VMS_FILE)"; fi
echo "[OK] VM list: $vm_list_desc"

state_json() { terraform show -json; }
before=$(mktemp); after=$(mktemp); plan=$(mktemp)
trap 'rm -f "$before" "$after" "$plan"' EXIT

journal="$LAB_PROJECT_DIR/terraform/cleanup-pending.json"

# Clean every journal entry that is no longer in the state (the journal keeps
# failures for the next run).
run_cleanup() {
  state_json > "$after"
  python3 ../cleanup-guest.py run "$journal" "$after"
}

# Apply, then clean up after VMs the apply removed. VMs the plan deletes were
# recorded beforehand; any other VM missing afterwards is recorded too.
# Cleanup also runs when the apply fails part-way, so a VM it did delete is
# not left with its seed ISO, known_hosts and folder.
apply_and_clean() {
  local rc=0
  state_json > "$before"
  terraform apply -input=false -auto-approve -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" "$@" || rc=$?
  state_json > "$after"
  python3 ../cleanup-guest.py record "$journal" "$before" --gone "$after"
  run_cleanup || { [[ $rc -ne 0 ]] || rc=1; }
  return "$rc"
}

# Retry cleanup left over from an earlier failed or interrupted run.
if [[ -f "$journal" && "${1:-status}" != status && "${1:-status}" != cleanup ]]; then
  echo '[INFO] Retrying cleanup left from an earlier run'
  run_cleanup || true
fi

# Write a `plan -json` message stream to $plan (no plan file is written: a
# saved plan would contain the vmrest password). Prints plan errors.
run_plan() {
  if ! terraform plan -input=false -lock=false -json "${LAB_TF_VAR_ARGS[@]}" "$@" > "$plan"; then
    python3 -c 'import json, sys
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("@level") == "error":
        d = m.get("diagnostic", {})
        print("[ERROR] " + (d.get("summary") or m.get("@message", "")), file=sys.stderr)
        if d.get("detail"):
            print("        " + d["detail"].replace("\n", "\n        "), file=sys.stderr)
        if d.get("address"):
            print("        at " + d["address"], file=sys.stderr)' "$plan"
    return 1
  fi
}

# Planned changes in $plan, one per line: action<TAB>address<TAB>type<TAB>name<TAB>key
plan_changes() {
  python3 -c 'import json, sys
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("type") != "planned_change":
        continue
    c = m["change"]; r = c["resource"]
    print("\t".join(str(x) for x in (c.get("action"), r.get("addr"), r.get("resource_type"),
                                      r.get("resource_name"), r.get("resource_key"))))' "$plan"
}

# Names Terraform would create with the current list (new entries, or VMs
# whose bootstrap never finished), from $plan.
planned_new_vms() {
  plan_changes | awk -F'\t' '($1 == "create" || $1 == "replace") &&
    (($3 == "vmworkstation_virtual_machine" && $4 == "vm") || ($3 == "terraform_data" && $4 == "guest_bootstrap")) { print $5 }' | sort -u
}

# Stop unless the user allowed it when $plan deletes or replaces a VM. A
# missing or mistyped vms.tfvars shows up here as deletions.
guard_vm_destroy() {
  local doomed
  doomed=$(plan_changes | awk -F'\t' '($1 == "delete" || $1 == "replace") && $3 == "vmworkstation_virtual_machine" { print $5 }' | sort -u)
  [[ -z "$doomed" ]] && return 0
  if [[ "$allow_destroy" == 1 ]]; then
    echo "[WARN] --allow-destroy: deleting or replacing VMs: $(tr '\n' ' ' <<<"$doomed")"
    state_json > "$before"
    # shellcheck disable=SC2086 # names are validated VM keys
    python3 ../cleanup-guest.py record "$journal" "$before" $doomed
    return 0
  fi
  echo "[ERROR] This would delete or replace VMs: $(tr '\n' ' ' <<<"$doomed")" >&2
  echo "        VM list in use: $vm_list_desc" >&2
  echo "        If vms.tfvars is missing or wrong, fix it. To remove these VMs on purpose:" >&2
  echo "        bash terraform-vm.sh on --allow-destroy  (or terraform-vm.sh destroy for all)" >&2
  exit 1
}

# Targets for the VMs that already exist in the state.
existing_targets() {
  terraform state list 2>/dev/null | grep -E '^vmworkstation_virtual_machine\.vm\[' | sed 's/^/-target=/' || true
}

case "${1:-status}" in
  on)
    allow_destroy=0
    for arg in "${@:2}"; do
      case "$arg" in
        --allow-destroy) allow_destroy=1 ;;
        *) echo "[ERROR] Unknown option for on: $arg" >&2; exit 2 ;;
      esac
    done
    run_plan -var=power_state=on
    guard_vm_destroy
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
    [[ $# -le 1 ]] || { echo '[ERROR] off takes no options' >&2; exit 2; }
    # Power off only the VMs that exist; never create list entries here. The
    # targeted apply is still a full apply for those VMs, so check its plan
    # first and refuse anything but an in-place power change.
    mapfile -t targets < <(existing_targets)
    if [[ ${#targets[@]} -eq 0 ]]; then echo '[OK] No VMs in the state'; exit 0; fi
    run_plan -var=power_state=off "${targets[@]}"
    other=$(plan_changes | awk -F'\t' '!($1 == "update" && $3 == "vmworkstation_virtual_machine") &&
      $1 != "no-op" && $1 != "noop" && $1 != "read" { print "  " $1 ": " $2 }')
    if [[ -n "$other" ]]; then
      echo '[ERROR] off would do more than power VMs off; nothing changed:' >&2
      echo "$other" >&2
      echo "        VM list in use: $vm_list_desc. Fix vms.tfvars, or review with: bash extras/diagnose-terraform.sh off" >&2
      exit 1
    fi
    terraform apply -input=false -auto-approve -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" \
      -var=power_state=off "${targets[@]}"
    ;;
  status)
    terraform show -no-color
    if [[ -f "$journal" ]]; then
      echo '[WARN] Cleanup pending for deleted VMs (run: bash terraform-vm.sh cleanup):'
      python3 ../cleanup-guest.py list "$journal" | sed 's/^/       /'
    fi
    ;;
  cleanup)
    [[ $# -le 1 ]] || { echo '[ERROR] cleanup takes no options' >&2; exit 2; }
    run_cleanup
    ;;
  destroy)
    state_json > "$before"
    python3 ../cleanup-guest.py record "$journal" "$before" --all
    rc=0
    terraform destroy -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" "${@:2}" || rc=$?
    run_cleanup || { [[ $rc -ne 0 ]] || rc=1; }
    exit "$rc"
    ;;
  *) echo 'Usage: bash terraform-vm.sh on [--allow-destroy] | off | status | cleanup | destroy [terraform args]' >&2; exit 2 ;;
esac
