"""Read network evidence from VMX files and terraform show -json on stdin.

No API calls or writes. Shared by network, status and the pre-up LAN gate.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def vm_instances(state):
    def walk(module):
        for resource in module.get('resources', []):
            if (resource.get('mode') == 'managed'
                    and resource.get('type') == 'vmworkstation_virtual_machine'):
                values = resource['values']
                yield dict(name=str(resource.get('index', values.get('denomination', ''))),
                           id=values['id'], path=values['path'])
        for child in module.get('child_modules', []):
            yield from walk(child)
    return sorted(walk(state.get('values', {}).get('root_module', {})),
                  key=lambda vm: vm['name'])


def read_vmx(path):
    try:
        # State paths are Windows paths; native paths make offline fixtures easy.
        if os.name != 'nt' and re.match(r'^[A-Za-z]:[\\/]|^\\\\', str(path)):
            path = subprocess.check_output(['wslpath', '-u', str(path)],
                                           text=True, stdin=subprocess.DEVNULL).strip()
        settings = {}
        for n, line in enumerate(Path(path).read_text(encoding='utf-8-sig').splitlines(), start=1):
            if re.fullmatch(r'\s*(?:#.*)?', line):
                continue
            match = re.fullmatch(r'\s*([^#\s=]+)\s*=\s*"([^"]*)"\s*(?:#.*)?', line)
            if match is None:
                raise ValueError(f'malformed VMX line {n}')
            key, value = match.groups()
            key = key.lower()
            if key in settings:
                raise ValueError('duplicate VMX key: ' + key)
            settings[key] = value
        return settings, None
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, str(exc)


def desired_lan():
    vnet = os.environ.get('LAB_LAN_VNET') or 'VMnet0'
    return {'connectionType': 'bridged' if vnet == 'VMnet0' else 'custom',
            'vnet': None if vnet == 'VMnet0' else vnet}


def lan_evidence(vm):
    settings, error = read_vmx(vm['path'])
    actual = None if settings is None else {
        'present': settings.get('ethernet2.present'),
        'connectionType': settings.get('ethernet2.connectiontype'),
        'vnet': settings.get('ethernet2.vnet')}
    lan = None if actual is None else (actual['present'] or '').upper() == 'TRUE'
    desired = 'none' if lan is False else desired_lan()
    mismatch = None if actual is None else lan and any(
        actual[key] != value for key, value in desired.items())
    return dict(vm, lan=lan, desired=desired, actual=actual,
                mismatch=mismatch, error=error)


def evidence(state):
    bases = []
    for path in sorted(Path(os.environ['LAB_BASE_DIR']).glob('*/base.vmx')):
        settings, error = read_vmx(path)
        actual = None if settings is None else settings.get('ethernet0.vnet')
        bases.append(dict(path=str(path), desired=os.environ['LAB_NAT_VNET'],
                          actual=actual, mismatch=None if settings is None else
                          actual != os.environ['LAB_NAT_VNET'], error=error))
    return dict(roles={'nat': os.environ['LAB_NAT_VNET'],
                       'management': os.environ['LAB_MGMT_VNET'],
                       'lan': os.environ.get('LAB_LAN_VNET') or 'VMnet0'},
                bases=bases, vms=[lan_evidence(vm) for vm in vm_instances(state)])


def main():
    mode = sys.argv[1]
    state = json.load(sys.stdin)
    report = evidence(state)
    if mode == 'gate':
        mismatches = [vm for vm in report['vms'] if vm['mismatch']]
        unknown = [vm for vm in report['vms'] if vm['error']]
        if mismatches or unknown:
            print(json.dumps(mismatches + unknown), file=sys.stderr)
            return 5 if mismatches else 1
    elif mode == 'status':
        for vm in report['vms']:
            print('\t'.join((vm['name'], vm['id'], json.dumps(
                {key: vm[key] for key in ('desired', 'actual', 'mismatch', 'error')}))))
    elif mode == 'report':
        # The Windows collector is one JSON document, including null reasons.
        report['windows'] = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8-sig'))
        import envelope
        envelope.record('data', report)
        if not os.environ.get('LAB_RESULT_FILE'):
            print(json.dumps(report, indent=2))
    else:
        raise ValueError('unknown mode: ' + mode)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print('[ERROR] Cannot inspect network evidence: ' + str(exc), file=sys.stderr)
        sys.exit(1)
