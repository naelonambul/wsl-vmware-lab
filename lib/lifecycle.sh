#!/usr/bin/env bash
# Internal: called by ./lab (up -> on, down -> off, status, cleanup, destroy).
# up selects power-on; bare up prepares off. down requires --all or names.
# VMs come from vms.tfvars (LAB_VMS_FILE) if present, else one VM from lab.env.
# on/off check the base VM first (check-base.py) and read the plan: on refuses
# to delete or replace VMs unless --allow-destroy is given (a rebuilt base
# replaces every clone); off refuses anything but a power change.
# VMs that may be deleted are written to terraform/cleanup-pending.json first;
# their generated files are cleaned once they are gone, and a failed cleanup is
# retried by the next on/destroy/cleanup.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
operation="${1:-status}"
# Selections are VM keys, never Terraform addresses or free-form CLI options.
select_vms() {
  all=0; hard=0; allow_destroy=0; selected=()
  local arg
  for arg in "${@:2}"; do
    case "$arg" in
      --all) all=1 ;;
      --allow-destroy) [[ "$1" == on ]] || lab_fail usage_error '--allow-destroy is for up'; allow_destroy=1 ;;
      --hard) [[ "$1" == off ]] || lab_fail usage_error '--hard is for down'; hard=1 ;;
      -*) lab_fail usage_error "Unknown option: $arg" ;;
      *) [[ "$arg" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || lab_fail unknown_vm "Invalid VM name: $arg"
         selected+=("$arg") ;;
    esac
  done
  [[ "$all" == 0 || ${#selected[@]} == 0 ]] || lab_fail usage_error '--all cannot be combined with VM names'
  [[ "$1" != off || "$all" == 1 || ${#selected[@]} -gt 0 ]] || lab_fail usage_error 'Use ./lab down --all or ./lab down <vm>...'
}
case "$operation" in on|off) select_vms "$@" ;; esac
lab_terraform_env
cd "$LAB_PROJECT_DIR/terraform"
# Gate every up entry before init, cleanup replay or planning. Read instances
# from state JSON, including clones absent from stale Terraform outputs.
if [[ "${1:-status}" == on && -f terraform.tfstate ]]; then
  lan_rc=0
  terraform show -json | python3 ../lib/network-inspect.py gate || lan_rc=$?
  case "$lan_rc" in
    0) ;;
    5) lab_fail lan_vnet_mismatch 'Existing LAN VM wiring differs from LAB_LAN_VNET.' \
         'Power off for offline VMX repair; see reference/network.md. There is no bypass.' ;;
    *) lab_fail runtime_error 'Cannot inspect existing clone LAN wiring; nothing changed.' ;;
  esac
fi
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
# on/off clone or power VMs from the base: confirm it is the one VM with the
# base name first (destroy and cleanup do not need the base).
case "${1:-status}" in
  on|off) lab_base_identity || exit 1 ;;
esac
terraform init -input=false >/dev/null
if [[ ${#LAB_TF_VAR_ARGS[@]} -gt 0 ]]; then vm_list_desc="$LAB_VMS_FILE"
else vm_list_desc="single VM $LAB_CLONE_NAME (no $LAB_VMS_FILE)"; fi
echo "[OK] VM list: $vm_list_desc"

state_json() { terraform show -json; }
umask 077
mkdir -p "$LAB_PRIVATE_DIR"
chmod 700 "$LAB_PRIVATE_DIR"
# Called under the checkout lock; these are private saved plans left by SIGKILL.
case "${1:-status}" in on|off) rm -f -- "$LAB_PRIVATE_DIR"/plan.* ;; esac
before=$(mktemp); after=$(mktemp); plan=$(mktemp)
plan_file=$(mktemp "$LAB_PRIVATE_DIR/plan.XXXXXX")
shutdown_inventory=$(mktemp "$LAB_PRIVATE_DIR/down-inventory.XXXXXX.yml")
backup="$LAB_PROJECT_DIR/terraform/bootstrap-records.backup.json"
trap 'rm -f "$before" "$after" "$plan" "$plan_file" "$shutdown_inventory"' EXIT

journal="$LAB_PROJECT_DIR/terraform/cleanup-pending.json"

# Clean every journal entry that is no longer in the state (the journal keeps
# failures for the next run).
run_cleanup() {
  state_json > "$after" || return 1
  python3 ../lib/cleanup-guest.py run "$journal" "$after"
}

# Apply, then clean up after VMs the apply removed. VMs the plan deletes were
# recorded beforehand; any other VM missing afterwards is recorded too.
# Cleanup also runs when the apply fails part-way, so a VM it did delete is
# not left with its seed ISO, known_hosts and folder.
apply_and_clean() {
  local rc=0
  state_json > "$before" || return 1
  terraform apply -input=false -parallelism=1 "$plan_file" || rc=$?
  state_json > "$after" || return 1
  python3 ../lib/cleanup-guest.py record "$journal" "$before" --gone "$after" || rc=1
  run_cleanup || { [[ $rc -ne 0 ]] || rc=1; }
  return "$rc"
}

# Saved plans are private and removed by the EXIT trap; the stream contains
# action metadata only. Variable arguments belong to plan, never saved apply.
# Explicit CLI power wins over tfvars (Terraform variable precedence):
# https://developer.hashicorp.com/terraform/language/values/variables#assign-values-to-variables
run_plan() {
  if [[ "$operation" == on ]]; then
    state_json | python3 ../lib/power-map.py coverage
  fi
  if ! terraform plan -input=false -json -out="$plan_file" "${LAB_TF_VAR_ARGS[@]}" "$@" -var="power_states=$TF_VAR_power_states" > "$plan"; then
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

# Stop unless the user allowed it when $plan deletes or replaces a VM (args:
# the plan options, to plan again after removing them). A
# missing or mistyped vms.tfvars shows up here as deletions.
guard_vm_destroy() {
  local doomed
  doomed=$(plan_changes | awk -F'\t' '($1 == "delete" || $1 == "replace") && $3 == "vmworkstation_virtual_machine" { print $5 }' | sort -u)
  [[ -z "$doomed" ]] && return 0
  if [[ "$allow_destroy" == 1 ]]; then
    if [[ "${1:-}" == --check-only ]]; then
      local name
      for name in $doomed; do
        grep -Fxq "$name" <<< "$authorised_deletes" || lab_fail runtime_error "Unexpected deletion: $name"
      done
      # Replacement preparation already ran. Refuse an unexpected new replace
      # rather than apply it without its powered-off bootstrap phase.
      if plan_changes | awk -F'\t' '$1 == "replace" && $3 == "vmworkstation_virtual_machine" { f=1 } END { exit !f }'; then
        lab_fail runtime_error 'A new replacement appeared in the final plan; inspect ./lab status before retrying.'
      fi
      state_json > "$before"
      python3 ../lib/cleanup-guest.py record "$journal" "$before" $doomed
      return 0
    fi
    echo "[WARN] --allow-destroy: deleting or replacing VMs: $(tr '\n' ' ' <<<"$doomed")"
    state_json > "$before"
    # shellcheck disable=SC2086 # names are validated VM keys
    python3 ../lib/cleanup-guest.py record "$journal" "$before" $doomed
    # Replaced VMs (a rebuilt base replaces every clone) are destroyed on their
    # own first and cleaned up: Terraform would otherwise create the
    # replacement right after the destroy, into the same folder that still
    # holds the old seed ISO and .vmxf, and vmrest refuses that. VMs that are
    # only deleted stay in the main apply: a targeted destroy also takes the
    # bootstrap of every other clone with it.
    local name replaced targets=()
    replaced=$(plan_changes | awk -F'\t' '$1 == "replace" && $3 == "vmworkstation_virtual_machine" { print $5 }' | sort -u)
    for name in $replaced; do
      [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "[ERROR] Unexpected VM name from plan: $name" >&2; exit 1; }
      targets+=(-target="vmworkstation_virtual_machine.vm[\"$name\"]")
    done
    if [[ ${#targets[@]} -gt 0 ]]; then
      # The targeted destroy also drops the bootstrap record of every other
      # clone (Terraform follows the resource-level dependency). Those clones
      # are untouched, so put their records back from the state as it was
      # before: re-running their bootstrap would pin a new host key the guest
      # does not have, and a targeted apply would pull in the new clones too.
      python3 ../lib/bootstrap-records.py save "$backup" $doomed
      terraform apply -destroy -input=false -auto-approve -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" "${targets[@]}" -var="power_states=$TF_VAR_power_states" || exit 1
      python3 ../lib/bootstrap-records.py restore "$backup"
      run_cleanup || exit 1
      # Replacement clones must bootstrap off; retain all surviving seeds.
      TF_VAR_power_states=$(python3 -c 'import json,os,sys
p=json.loads(os.environ["TF_VAR_power_states"])
for name in sys.argv[1:]: p[name]="off"
print(json.dumps(p))' $replaced)
      export TF_VAR_power_states
      run_plan "$@"
    fi
    return 0
  fi
  echo "[ERROR] This would delete or replace VMs: $(tr '\n' ' ' <<<"$doomed")" >&2
  echo "        VM list in use: $vm_list_desc" >&2
  if plan_changes | awk -F'\t' '$1 == "update" && $3 == "terraform_data" && $4 == "vm_base" { f = 1 } END { exit !f }'; then
    echo "        A VM's image changed, or its base was rebuilt or re-registered at another" >&2
    echo "        id or path: those clones are rebuilt from it, losing everything inside them." >&2
  fi
  echo "        If vms.tfvars is missing or wrong, fix it. To remove these VMs on purpose:" >&2
  echo "        ./lab up --allow-destroy  (or ./lab destroy for all)" >&2
  exit 1
}

validate_selection() {
  local name
  for name in "${selected[@]}"; do
    grep -Fxq "$name" <<< "$valid" || lab_fail unknown_vm "Unknown VM: $name. Valid VMs: $(tr '\n' ' ' <<< "$valid")"
  done
}
resize_check() { terraform show -json "$plan_file" | TF_VAR_power_states="${2:-$TF_VAR_power_states}" python3 ../lib/plan-inspect.py "$1"; }
select_power() {
  TF_VAR_power_states=$(python3 -c 'import json,os,sys
p=json.loads(os.environ["TF_VAR_power_states"])
for name in sys.argv[2:]: p[name]=sys.argv[1]
print(json.dumps(p))' "$@")
  export TF_VAR_power_states
}
check_down_plan() {
  local other
  other=$(plan_changes | awk -F'\t' '!($1 == "update" && $3 == "vmworkstation_virtual_machine") &&
    !($1 == "create" && $3 == "terraform_data" && $4 == "vm_base") &&
    !($1 == "delete" && $3 == "terraform_data" && $4 == "base_identity") &&
    $1 != "no-op" && $1 != "noop" && $1 != "read" { print "  " $1 ": " $2 }')
  [[ -z "$other" ]] || lab_fail config_change_requires_off "down would do more than power off: $other" 'Fix vms.tfvars; review ./lab status --plan.'
  resize_check down
}

case "${1:-status}" in
  on)
    python3 ../lib/bootstrap-records.py restore "$backup"
    state_json > "$before"
    TF_VAR_power_states=$(python3 ../lib/power-map.py seed < "$before")
    export TF_VAR_power_states
    run_plan
    authorised_deletes=$(plan_changes | awk -F'\t' '$1 == "delete" && $3 == "vmworkstation_virtual_machine" { print $5 }' | sort -u)
    valid=$( { python3 ../lib/power-map.py names < "$before"; planned_new_vms; } | sort -u | while read -r name; do
      if ! grep -Fxq "$name" <<< "$authorised_deletes"; then echo "$name"; fi
    done)
    validate_selection
    resize_check up
    # Refuse unauthorised destruction before replay; cleanup refuses folders
    # containing VMX/disks. Recover interrupted cleanup before collision checks.
    if [[ "$allow_destroy" == 0 ]]; then guard_vm_destroy; fi
    [[ ! -f "$journal" ]] || run_cleanup
    # Check every prospective folder before replacement destroy.
    new_vms=$(planned_new_vms)
    existing=$(python3 ../lib/power-map.py names < "$before")
    root_unix=$(wslpath -u "$LAB_VM_ROOT_WIN")
    for name in $new_vms; do
      [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || lab_fail runtime_error 'Unexpected VM name in plan'
      if [[ -d "$root_unix/$name" && -n "$(ls -A "$root_unix/$name")" ]] && ! grep -Fxq "$name" <<< "$existing"; then
        lab_fail config_error "VM folder already has files but $name is absent from state; inspect ./lab status before retrying."
      fi
    done
    guard_vm_destroy
    new_vms=$(planned_new_vms)
    targets=()
    # Populate the map for newly created instances before they enter state;
    # bootstrap-only records on existing VMs retain their original seed.
    TF_VAR_power_states=$(python3 -c 'import json,os,sys
p=json.loads(os.environ["TF_VAR_power_states"])
for name in sys.argv[1:]: p.setdefault(name,"off")
print(json.dumps(p))' $new_vms)
    export TF_VAR_power_states
    for name in $new_vms; do
      targets+=(-target="vmworkstation_virtual_machine.vm[\"$name\"]" -target="terraform_data.guest_bootstrap[\"$name\"]")
    done
    if [[ ${#targets[@]} -gt 0 ]]; then
      echo "[OK] Preparing powered-off clones: $(tr '\n' ' ' <<< "$new_vms")"
      run_plan "${targets[@]}"
      resize_check up
      # No deletion may appear unexpectedly in the creation phase.
      guard_vm_destroy --check-only
      apply_and_clean
    fi
    if [[ "$all" == 1 ]]; then
      state_json > "$before"
      mapfile -t selected < <(python3 ../lib/power-map.py names < "$before")
    fi
    # Reconcile configuration while selected off VMs are still off. The
    # subsequent saved plan contains their power-on transition separately.
    run_plan
    resize_check up
    guard_vm_destroy --check-only
    if plan_changes | awk -F'\t' '$1 == "update" && $3 == "vmworkstation_virtual_machine" { f=1 } END { exit !f }'; then
      apply_and_clean
    fi
    select_power on "${selected[@]}"
    run_plan
    resize_check up
    guard_vm_destroy --check-only
    rc=0; apply_and_clean || rc=$?
    if [[ "$rc" != 0 ]]; then
      state_json | python3 ../lib/power-map.py report || true
      lab_fail runtime_error 'Apply failed; inspect ./lab status and decide how to recover before retrying.'
    fi
    state_json | python3 ../lib/power-map.py report
    ;;
  off)
    export LAB_DOWN_WAIT_SECONDS="${LAB_DOWN_WAIT_SECONDS:-120}"
    [[ "$LAB_DOWN_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || lab_fail config_error 'LAB_DOWN_WAIT_SECONDS must be a positive integer'
    state_json > "$before"
    valid=$(python3 ../lib/power-map.py names < "$before")
    validate_selection
    if [[ "$all" == 1 ]]; then
      selected=(); [[ -z "$valid" ]] || mapfile -t selected <<< "$valid"
    fi
    if [[ ${#selected[@]} == 0 ]]; then echo '[OK] No VMs in the state'; exit 0; fi
    TF_VAR_power_states=$(python3 ../lib/power-map.py seed "${selected[@]}" < "$before")
    export TF_VAR_power_states
    running=$(python3 -c 'import json,os; print(json.dumps([n for n,p in json.loads(os.environ["TF_VAR_power_states"]).items() if p=="on"]))')
    targets=()
    for name in "${selected[@]}"; do targets+=(-target="vmworkstation_virtual_machine.vm[\"$name\"]"); done
    select_power off "${selected[@]}"
    run_plan "${targets[@]}"
    check_down_plan
    if [[ "$hard" == 0 ]]; then
      # Best effort never consumes a previous shared inventory. Ansible's SSH
      # return code cannot establish shutdown; only the power API below can.
      if [[ "$running" != '[]' ]] && LAB_INVENTORY="$shutdown_inventory" LAB_INVENTORY_SELECTED="$running" \
          python3 ../lib/guest-inventory.py --best-effort &&
          python3 -c 'import json,sys; sys.exit(not bool(json.load(open(sys.argv[1]))["all"]["hosts"]))' "$shutdown_inventory"; then
        lab_ansible_env
        ansible -i "$shutdown_inventory" all -b -m ansible.builtin.command -a 'systemctl poweroff --no-block' || true
      fi
      python3 ../lib/power-map.py wait "${selected[@]}" < "$before"
    fi
    run_plan "${targets[@]}"
    check_down_plan
    apply_and_clean
    ;;
  status)
    # Short summary: each VM of this checkout and its power state (vmrest).
    vms=$(state_json | python3 ../lib/network-inspect.py status)
    while IFS=$'\t' read -r name id lan; do
      [[ -n "$name" ]] || continue
      [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
      p=$(curl --connect-timeout 3 --max-time 10 -fsS -K - "${TF_VAR_vmrest_endpoint%/}/vms/$id/power" < <(lab_curl_auth) 2>/dev/null |
          python3 -c 'import json,sys; print(json.load(sys.stdin).get("power_state", "?"))' 2>/dev/null || echo unknown)
      echo "[VM] $name: $p ethernet2=$lan"
    done <<< "$vms"
    [[ -z "$vms" ]] && echo '[OK] No VMs in this checkout'
    if [[ -f "$journal" ]]; then
      echo '[WARN] Cleanup pending for deleted VMs (run: ./lab cleanup):'
      python3 ../lib/cleanup-guest.py list "$journal" | sed 's/^/       /'
    fi
    ;;
  cleanup)
    [[ $# -le 1 ]] || { echo '[ERROR] cleanup takes no options' >&2; exit 2; }
    python3 ../lib/bootstrap-records.py restore "$backup"
    run_cleanup
    ;;
  destroy)
    [[ ! -f "$journal" ]] || run_cleanup
    state_json > "$before"
    python3 ../lib/cleanup-guest.py record "$journal" "$before" --all
    rc=0
    terraform destroy -parallelism=1 "${LAB_TF_VAR_ARGS[@]}" "${@:2}" || rc=$?
    run_cleanup || { [[ $rc -ne 0 ]] || rc=1; }
    exit "$rc"
    ;;
  *) echo 'Usage: ./lab up [--all | <vm>...] [--allow-destroy] | down (--all | <vm>...) [--hard] | status [--plan] | cleanup | destroy [terraform args]' >&2; exit 2 ;;
esac
