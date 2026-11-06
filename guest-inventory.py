"""Find the managed guest IP from VMware DHCP leases and write Ansible inventory.

Run via configure-guest.sh, which loads lib/config.sh into the environment.
"""
import ipaddress
import json
import os
import re
import socket
import shlex
from pathlib import Path
import subprocess

project = Path(__file__).resolve().parent
state = json.loads(subprocess.check_output(
    ['terraform', '-chdir=' + str(project / 'terraform'), 'show', '-json'], text=True))
vm = next(r['values'] for r in state['values']['root_module']['resources']
          if r['address'] == 'vmworkstation_virtual_machine.ubuntu_demo')
vmx_path = subprocess.check_output(['wslpath','-u',vm['path']],text=True).strip()
vmx = Path(vmx_path).read_text()
match = re.search(r'ethernet1.generatedAddress\s*=\s*"([^"]+)"',vmx)
if not match:
    raise SystemExit('Management NIC has no MAC yet; power on and wait for boot')
leases = Path(os.environ.get('LAB_DHCP_LEASES', '/mnt/c/ProgramData/VMware/vmnetdhcp.leases')).read_text()
addresses = [ip for ip,body in re.findall(r'lease\s+(\S+)\s*\{([^}]+)\}',leases)
             if match.group(1).lower() in body.lower()]
if not addresses:
    raise SystemExit('No management DHCP lease yet; retry after guest boot')
address = str(ipaddress.IPv4Address(addresses[-1]))
proxy = ''
try:
    with socket.create_connection((address,22),timeout=3): pass
except OSError:
    command = 'bash ' + shlex.quote(str(project / 'guest-proxy.sh')) + ' %h %p'
    proxy = ' -o ' + shlex.quote('ProxyCommand=' + command)
# The guest user is the image's default user; the guest reports it through
# VMware guestinfo on every boot (lib/cloud-config.sh).
vmrun = str(Path(os.environ.get('VMWARE_DIR', '/mnt/c/Program Files/VMware/VMware Workstation')) / 'vmrun.exe')
guest_user = subprocess.run([vmrun, '-T', 'ws', 'readVariable', vm['path'], 'guestVar',
                             'wsl-vmware-lab.guest_user'], capture_output=True, text=True).stdout.strip()
if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', guest_user):
    raise SystemExit('Guest has not reported its default user through guestinfo yet; retry after boot')
private = Path(os.environ.get('LAB_PRIVATE_DIR', str(Path.home() / '.config/wsl-vmware-lab')))
key = Path(os.environ.get('LAB_SSH_KEY', str(private / 'lab_ed25519')))
if not key.is_file():
    raise SystemExit('Missing lab SSH key: ' + str(key) + ' (run prepare-cloud-init.sh)')
inventory = {'all': {'children': {'demo': {'hosts': {'ubuntu_demo': {
    'ansible_host': address, 'ansible_user': guest_user,
    'ansible_ssh_private_key_file': str(key),
    'ansible_python_interpreter': '/usr/bin/python3',
    'ansible_ssh_common_args': '-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=' +
        str(private / ('known_hosts-' + vm['id'])) + proxy
}}}}}}
target = Path(os.environ.get('LAB_INVENTORY', str(private / 'inventory.json')))
target.write_text(json.dumps(inventory, indent=2) + '\n')
target.chmod(0o600)
print('[OK] Guest IP: ' + address + '  user (image default, from guestinfo): ' + guest_user)
print('[OK] Inventory: ' + str(target))
