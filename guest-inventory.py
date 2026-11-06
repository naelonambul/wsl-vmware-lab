"""Find each lab VM's management IP and user, and write the Ansible inventory.

Run via configure-guest.sh, which loads lib/config.sh into the environment.
Hosts are the VM names from Terraform output `vms`; each VM's `groups` become
Ansible groups, and every VM is also in the group `lab`. Exits non-zero while
any VM is not ready yet, so configure-guest.sh can retry.
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
try:
    vms = json.loads(subprocess.check_output(
        ['terraform', '-chdir=' + str(project / 'terraform'), 'output', '-json', 'vms'],
        text=True, stderr=subprocess.DEVNULL))
except subprocess.CalledProcessError:
    raise SystemExit('No Terraform output "vms"; run bash terraform-vm.sh on first')
if not vms:
    raise SystemExit('No lab VMs in the Terraform state')

private = Path(os.environ.get('LAB_PRIVATE_DIR', str(Path.home() / '.config/wsl-vmware-lab')))
key = Path(os.environ.get('LAB_SSH_KEY', str(private / 'lab_ed25519')))
if not key.is_file():
    raise SystemExit('Missing lab SSH key: ' + str(key) + ' (run prepare-cloud-init.sh)')
leases = Path(os.environ.get('LAB_DHCP_LEASES', '/mnt/c/ProgramData/VMware/vmnetdhcp.leases')).read_text()
vmrun = str(Path(os.environ.get('VMWARE_DIR', '/mnt/c/Program Files/VMware/VMware Workstation')) / 'vmrun.exe')
proxy_command = 'bash ' + shlex.quote(str(project / 'guest-proxy.sh')) + ' %h %p'

hosts, groups, waiting = {}, {}, []
for name, vm in sorted(vms.items()):
    vmx_file = Path(subprocess.check_output(['wslpath', '-u', vm['path']], text=True).strip())
    if not vmx_file.is_file():
        waiting.append(name + ': VMX missing (' + vm['path'] + '); run bash terraform-vm.sh on to reconcile')
        continue
    vmx = vmx_file.read_text()
    match = re.search(r'ethernet1.generatedAddress\s*=\s*"([^"]+)"', vmx)
    if not match:
        waiting.append(name + ': management NIC has no MAC yet')
        continue
    addresses = [ip for ip, body in re.findall(r'lease\s+(\S+)\s*\{([^}]+)\}', leases)
                 if match.group(1).lower() in body.lower()]
    if not addresses:
        waiting.append(name + ': no management DHCP lease yet')
        continue
    address = str(ipaddress.IPv4Address(addresses[-1]))
    # The guest user is the image's default user; the guest reports it through
    # VMware guestinfo on every boot (lib/cloud-config.sh).
    guest_user = subprocess.run([vmrun, '-T', 'ws', 'readVariable', vm['path'], 'guestVar',
                                 'wsl-vmware-lab.guest_user'], capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', guest_user):
        waiting.append(name + ': guest has not reported its default user through guestinfo yet '
                       '(needs open-vm-tools in the guest; Ubuntu cloud images ship it)')
        continue
    proxy = ''
    try:
        with socket.create_connection((address, 22), timeout=3):
            pass
    except OSError:
        proxy = ' -o ' + shlex.quote('ProxyCommand=' + proxy_command)
    hosts[name] = {
        'ansible_host': address, 'ansible_user': guest_user,
        'ansible_ssh_private_key_file': str(key),
        'ansible_python_interpreter': '/usr/bin/python3',
        'ansible_ssh_common_args': '-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=' +
            str(private / ('known_hosts-' + vm['id'])) + proxy,
    }
    for group in ['lab'] + list(vm.get('groups') or []):
        groups.setdefault(group, {})[name] = {}
    print('[OK] ' + name + ': ' + address + '  user (image default, from guestinfo): ' + guest_user
          + '  groups: ' + ','.join(vm.get('groups') or []))

if waiting:
    raise SystemExit('Not ready, retrying: ' + '; '.join(waiting))
inventory = {'all': {'hosts': hosts,
                     'children': {g: {'hosts': members} for g, members in sorted(groups.items())}}}
target = Path(os.environ.get('LAB_INVENTORY', str(private / 'inventory.json')))
target.write_text(json.dumps(inventory, indent=2) + '\n')
target.chmod(0o600)
print('[OK] Inventory: ' + str(target) + '  hosts: ' + str(len(hosts)))
