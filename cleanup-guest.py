"""After Terraform deletes clones, remove only files generated for those clones.

  python3 cleanup-guest.py BEFORE.json            # every clone in BEFORE (after destroy)
  python3 cleanup-guest.py BEFORE.json AFTER.json # clones in BEFORE that are gone from AFTER

BEFORE/AFTER are `terraform show -json` outputs. A clone that still has its VMX
or disks is never touched.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def clones(path):
    state = json.loads(Path(path).read_text() or '{}')
    resources = state.get('values', {}).get('root_module', {}).get('resources', [])
    return {r['values']['id']: r['values'] for r in resources
            if r.get('type') == 'vmworkstation_virtual_machine' and r.get('mode') == 'managed'}


def clean(vm, private):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', vm['id']):
        raise SystemExit('Invalid VM id; no cleanup performed')
    vmx = Path(subprocess.check_output(['wslpath', '-u', vm['path']], text=True).strip())
    parent = vmx.parent.resolve()
    tag = '[' + vmx.stem + '] '
    if vmx.suffix.lower() != '.vmx' or parent.name != vmx.stem:
        raise SystemExit(tag + 'Unexpected VM folder layout; no cleanup performed')
    if vmx.exists() or any(parent.glob('*.vmdk')):
        raise SystemExit(tag + 'VMX or disk still exists; refusing cleanup')
    seed = parent / ('cloud-init-' + vm['id'] + '.iso')
    if seed.exists():
        seed.unlink()
        print('[OK] ' + tag + 'Removed generated cloud-init ISO')
    # Workstation can leave the VM's .vmxf metadata behind (seen when a running
    # clone is destroyed). Remove it only if it names this clone's VMX.
    vmxf = parent / (vmx.stem + '.vmxf')
    if vmxf.is_file():
        if re.search(r'<vmxPathName[^>]*>' + re.escape(vmx.name) + r'</vmxPathName>',
                     vmxf.read_text(errors='replace')):
            vmxf.unlink()
            print('[OK] ' + tag + 'Removed leftover .vmxf')
        else:
            print('[WARN] ' + tag + str(vmxf) + ' does not name ' + vmx.name + '; left intact')

    # WSL-side files for this clone id. vmrest derives the id from the VMX path,
    # so a clone recreated at the same path reuses it; stale host keys block SSH.
    known_hosts = private / ('known_hosts-' + vm['id'])
    if known_hosts.is_file():
        known_hosts.unlink()
        print('[OK] ' + tag + 'Removed known_hosts')
    seed_dir = private / ('seed-' + vm['id'])
    expected = {'user-data', 'meta-data', 'network-config'}
    if seed_dir.is_dir():
        if {p.name for p in seed_dir.iterdir()} <= expected:
            for p in seed_dir.iterdir():
                p.unlink()
            seed_dir.rmdir()
            print('[OK] ' + tag + 'Removed WSL seed directory')
        else:
            print('[WARN] ' + tag + 'Unexpected files in ' + str(seed_dir) + '; left intact')

    if parent.is_dir():
        left = sorted(x.name for x in parent.iterdir())
        if left:
            raise SystemExit(tag + 'Other files remain; directory was left intact: ' + str(parent) + ' ' + str(left))
        parent.rmdir()
        print('[OK] ' + tag + 'Removed empty clone directory')


before = clones(sys.argv[1])
gone = before
if len(sys.argv) > 2:
    after = clones(sys.argv[2])
    gone = {k: v for k, v in before.items() if k not in after}
if not gone:
    print('[OK] No removed VM to clean')
    sys.exit(0)
private = Path(os.environ.get('LAB_PRIVATE_DIR', str(Path.home() / '.config/wsl-vmware-lab')))
failed = []
for vm in gone.values():
    try:
        clean(vm, private)
    except SystemExit as e:
        print('[ERROR] ' + str(e), file=sys.stderr)
        failed.append(vm['id'])
sys.exit(1 if failed else 0)
