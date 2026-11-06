"""Remove only our seed ISO after Terraform successfully deletes its clone."""
import json
from pathlib import Path
import re
import subprocess
import sys

state = json.loads(Path(sys.argv[1]).read_text())
resources = state.get('values', {}).get('root_module', {}).get('resources', [])
vm = next((r['values'] for r in resources
           if r['address'] == 'vmworkstation_virtual_machine.ubuntu_demo'), None)
if vm is None:
    print('[OK] No managed VM seed to clean')
    sys.exit(0)
if not re.fullmatch(r'[A-Za-z0-9_-]+', vm['id']):
    raise SystemExit('Invalid VM id; no cleanup performed')
vmx = Path(subprocess.check_output(['wslpath','-u',vm['path']],text=True).strip())
parent = vmx.parent.resolve()
if vmx.suffix.lower() != '.vmx' or parent.name != vmx.stem:
    raise SystemExit('Unexpected VM folder layout; no cleanup performed')
if vmx.exists() or any(parent.glob('*.vmdk')):
    raise SystemExit('VMX or disk still exists; refusing seed cleanup')
seed = parent / ('cloud-init-' + vm['id'] + '.iso')
if seed.exists():
    seed.unlink()
    print('[OK] Removed generated cloud-init ISO')
if parent.is_dir():
    if any(parent.iterdir()):
        raise SystemExit('Other files remain; directory was left intact: ' + str(parent))
    parent.rmdir()
    print('[OK] Removed empty clone directory')
