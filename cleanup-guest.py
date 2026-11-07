"""Remove only the files generated for clones that Terraform deleted.

A journal of clones that may be deleted makes cleanup replayable: they are
recorded before Terraform runs, cleaned once they are gone from the state, and
dropped from the journal only when cleanup succeeded (or the clone still
exists). A failed or interrupted cleanup is retried by the next run.

  python3 cleanup-guest.py record JOURNAL STATE.json --all
  python3 cleanup-guest.py record JOURNAL STATE.json NAME...   # for_each keys
  python3 cleanup-guest.py record JOURNAL BEFORE.json --gone AFTER.json
  python3 cleanup-guest.py run JOURNAL STATE.json
  python3 cleanup-guest.py list JOURNAL

STATE/BEFORE/AFTER are `terraform show -json` outputs. A clone that still has
its VMX or disks is never touched.
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
    return {r['values']['id']: dict(r['values'], key=str(r.get('index', '')))
            for r in resources
            if r.get('type') == 'vmworkstation_virtual_machine' and r.get('mode') == 'managed'}


def load_journal(path):
    p = Path(path)
    if not p.exists():
        return {}
    data = json.loads(p.read_text() or '{}')
    return {vm_id: entry for vm_id, entry in data.get('pending', {}).items()}


def save_journal(path, pending):
    p = Path(path)
    if not pending:
        if p.exists():
            p.unlink()
        return
    tmp = p.with_name(p.name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump({'pending': pending}, f, indent=2, sort_keys=True)
        f.write('\n')
    os.replace(tmp, p)


class CleanupError(Exception):
    pass


def clean(vm, private):
    if not re.fullmatch(r'[A-Za-z0-9_-]+', vm['id']):
        raise CleanupError('Invalid VM id; no cleanup performed')
    vmx = Path(subprocess.check_output(['wslpath', '-u', vm['path']], text=True).strip())
    parent = vmx.parent.resolve()
    tag = '[' + vmx.stem + '] '
    if vmx.suffix.lower() != '.vmx' or parent.name != vmx.stem:
        raise CleanupError(tag + 'Unexpected VM folder layout; no cleanup performed')
    if vmx.exists() or any(parent.glob('*.vmdk')):
        raise CleanupError(tag + 'VMX or disk still exists; refusing cleanup')
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
            raise CleanupError(tag + 'Other files remain; directory was left intact: ' + str(parent) + ' ' + str(left))
        parent.rmdir()
        print('[OK] ' + tag + 'Removed empty clone directory')


def entry(vm):
    return {'id': vm['id'], 'path': vm['path'], 'name': vm.get('key') or vm.get('denomination', '')}


def cmd_record(journal, state_file, args):
    vms = clones(state_file)
    if args == ['--all']:
        chosen = list(vms.values())
    elif len(args) == 2 and args[0] == '--gone':
        after = clones(args[1])
        chosen = [vm for vm_id, vm in vms.items() if vm_id not in after]
    else:
        names = set(args)
        chosen = [vm for vm in vms.values() if vm['key'] in names]
    pending = load_journal(journal)
    for vm in chosen:
        pending[vm['id']] = entry(vm)
    save_journal(journal, pending)
    return 0


def cmd_run(journal, state_file):
    pending = load_journal(journal)
    if not pending:
        print('[OK] No removed VM to clean')
        return 0
    current = clones(state_file)
    private = Path(os.environ.get('LAB_PRIVATE_DIR', str(Path.home() / '.config/wsl-vmware-lab')))
    failed = []
    for vm_id, vm in sorted(pending.items()):
        if vm_id in current:
            del pending[vm_id]  # not deleted after all; nothing to clean
            continue
        try:
            clean(vm, private)
            del pending[vm_id]
        except (CleanupError, OSError, subprocess.CalledProcessError) as e:
            print('[ERROR] ' + (vm.get('name') or vm_id) + ': ' + str(e), file=sys.stderr)
            failed.append(vm.get('name') or vm_id)
    save_journal(journal, pending)
    if failed:
        print('[ERROR] Cleanup still pending for: ' + ' '.join(failed) +
              '. Fix the cause above, then run: bash terraform-vm.sh cleanup', file=sys.stderr)
        return 1
    return 0


def cmd_list(journal):
    for vm in sorted(load_journal(journal).values(), key=lambda v: v.get('name', '')):
        print((vm.get('name') or vm['id']) + '\t' + vm['path'])
    return 0


def main(argv):
    if len(argv) >= 4 and argv[1] == 'record':
        return cmd_record(argv[2], argv[3], argv[4:])
    if len(argv) == 4 and argv[1] == 'run':
        return cmd_run(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == 'list':
        return cmd_list(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
