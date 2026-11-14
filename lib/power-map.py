"""Live power, using the curl interface previously used by lifecycle status.

GET /vms/<id>/power and power_state are from lifecycle.sh at PR 1 (94cfd9a).
The on/off provider inputs are from terraform/variables.tf at that revision.
No provider state attribute is used as evidence of live power.
"""
import importlib
import json
import os
import re
import subprocess
import sys
import time

vm_instances = importlib.import_module('network-inspect').vm_instances


def power(vm, max_time=10):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', vm['id']):
        raise ValueError('unexpected VM id')
    def escape(value):
        return value.replace('\\', '\\\\').replace('"', '\\"')
    auth = 'user = "{}:{}"\n'.format(escape(os.environ['VMWS_USERNAME']),
                                      escape(os.environ['VMWS_PASSWORD']))
    endpoint = os.environ['VMWS_ENDPOINT'].rstrip('/')
    # Same 3 s connect / 10 s total limits as the existing status call;
    # polling caps both to the remaining shutdown deadline.
    run = subprocess.run(['curl', '--connect-timeout', str(min(3, max_time)),
                          '--max-time', str(max_time), '-fsS', '-K', '-',
                          endpoint + '/vms/' + vm['id'] + '/power'],
                         input=auth, capture_output=True, text=True)
    if run.returncode:
        raise ValueError('power API failed')
    value = json.loads(run.stdout)['power_state']
    if value not in ('poweredOn', 'poweredOff'):
        raise ValueError('unsupported power: ' + str(value))
    return 'on' if value == 'poweredOn' else 'off'


def seed(vms):
    result = {}
    for vm in vms:
        try:
            result[vm['name']] = power(vm)
        except (ValueError, KeyError, OSError) as exc:
            raise ValueError(vm['name'] + ': ' + str(exc)) from exc
    if set(result) != {vm['name'] for vm in vms}:
        raise ValueError('incomplete power map')
    return result


def wait_off(vms, seconds):
    deadline = time.monotonic() + seconds
    pending = list(vms)
    while pending:
        remaining = []
        for vm in pending:
            budget = deadline - time.monotonic()
            if budget <= 0:
                remaining.append(vm)
                continue
            try:
                if power(vm, min(10, budget)) == 'off':
                    continue
            except (ValueError, KeyError, OSError):
                pass  # unknown never counts as shutdown success
            remaining.append(vm)
        pending = remaining
        if not pending or time.monotonic() >= deadline:
            break
        time.sleep(min(5, deadline - time.monotonic()))  # existing readiness interval
    return [vm['name'] for vm in pending]


def main():
    mode, *names = sys.argv[1:]
    vms = vm_instances(json.load(sys.stdin))
    if names:
        unknown = set(names) - {v['name'] for v in vms}
        if unknown:
            raise ValueError('unknown VM: ' + ', '.join(sorted(unknown)))
        vms = [vm for vm in vms if vm['name'] in names]
    if mode == 'names':
        print('\n'.join(vm['name'] for vm in vms))
    elif mode == 'coverage':
        values = json.loads(os.environ['TF_VAR_power_states'])
        if any(values.get(vm['name']) not in ('on', 'off') for vm in vms):
            raise ValueError('incomplete power map')
    elif mode == 'seed':
        print(json.dumps(seed(vms)))
    elif mode == 'report':
        for vm in vms:
            try:
                value = power(vm)
            except (ValueError, KeyError, OSError):
                value = 'unknown'
            print('[VM] {}: {}{}'.format(vm['name'], value,
                  ' (start: ./lab up ' + vm['name'] + ' or ./lab up --all)' if value == 'off' else ''))
    elif mode == 'wait':
        # Approved shutdown budget: 90 s for service stops plus 30 s margin;
        # configurable because guest stop policies may require longer.
        seconds = int(os.environ.get('LAB_DOWN_WAIT_SECONDS', '120'))
        if seconds <= 0:
            raise ValueError('LAB_DOWN_WAIT_SECONDS must be positive')
        pending = wait_off(vms, seconds)
        if pending:
            print('[ERROR] guest_not_ready: power off not confirmed: ' + ', '.join(pending), file=sys.stderr)
            print('        Review ./lab status; explicit hard stop: ./lab down --hard ' + ' '.join(pending), file=sys.stderr)
            return 1
    else:
        raise ValueError('unknown mode')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError):
        print('[ERROR] vm_power_unknown: cannot establish live power; nothing further changed', file=sys.stderr)
        sys.exit(5)
