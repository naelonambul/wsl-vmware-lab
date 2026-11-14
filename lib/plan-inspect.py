"""Inspect terraform show -json of a saved plan on stdin; never print values.

Every attribute matters: provider 2.0.1 delegates updates to UpdateVM,
which cycles power (provider/client sources):
https://github.com/elsudano/terraform-provider-vmworkstation/blob/v2.0.1/internal/provider/resource_vm.go
https://github.com/elsudano/vmware-workstation-api-client/blob/v1.10.46/wsapivm/wsapivm.go
Verified against the real terraform CLI and provider on Workstation hosts.
"""
import json
import os
import sys


def resized(plan, mode, seeds):
    names = []
    for resource in plan.get('resource_changes', []):
        change = resource['change']
        if resource['type'] != 'vmworkstation_virtual_machine' or change['actions'] != ['update']:
            continue
        name = str(resource['index'])
        before, after = change.get('before') or {}, change.get('after') or {}
        unknown = change.get('after_unknown') or {}
        changed = {k for k in set(before) | set(after) | set(unknown)
                   if before.get(k) != after.get(k) or unknown.get(k)}
        # Any UpdateVM call cycles power. Only a pure state change, or an
        # update whose live seed and planned result are both off, is safe.
        if changed - {'state'} and not (mode == 'up' and seeds.get(name) == 'off'
                                       and after.get('state') == 'off'
                                       and not unknown.get('state')):
            names.append(name)
    return names


if __name__ == '__main__':
    names = resized(json.load(sys.stdin), sys.argv[1], json.loads(os.environ['TF_VAR_power_states']))
    if names:
        print('[ERROR] config_change_requires_off: VM configuration edit: ' + ', '.join(names), file=sys.stderr)
        print('        Revert configuration edits, ./lab down <vm>, restore edits, then ./lab up <vm>.', file=sys.stderr)
        sys.exit(5)
