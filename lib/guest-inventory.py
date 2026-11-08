"""Find each lab VM's management IP and user, and write the Ansible inventory.

Run via configure-guest.sh, which loads lib/config.sh into the environment.
Hosts are the VM names from Terraform output `vms`; each VM's `groups` become
Ansible groups, and every VM is also in the group `lab`. Exits 1 while any VM
is not ready yet, so configure-guest.sh can retry, and 3 on errors a retry
cannot fix.

The address comes from VMware's DHCP leases: only a lease that is still
current (the last entry for its address, active, not expired), on the
management network (LAB_MGMT_VNET's subnet in vmnetdhcp.conf) and for this
VM's management NIC MAC. The leases file keeps old and expired entries, so an address
alone could reach another VM; SSH therefore accepts only the host key the
guest itself reported through VMware guestinfo (lib/cloud-config.sh).
"""
from datetime import datetime, timezone
import ipaddress
import json
import os
import re
import socket
import shlex
from pathlib import Path
import subprocess
import sys

NOT_READY, FATAL = 1, 3


def fatal(msg):
    print('[ERROR] ' + msg, file=sys.stderr)
    sys.exit(FATAL)


def lease_time(value):
    """dhcpd.leases time ("<weekday> YYYY/MM/DD HH:MM:SS", UTC; or "epoch N") or None for "never"."""
    value = value.strip()
    if value == 'never':
        return None
    if value.startswith('epoch '):
        return datetime.fromtimestamp(int(value.split()[1]), timezone.utc)
    return datetime.strptime(value.split(' ', 1)[1], '%Y/%m/%d %H:%M:%S').replace(tzinfo=timezone.utc)


def parse_leases(text):
    """List of dicts: ip, mac, starts, ends, state (binding state if present), in file order."""
    leases = []
    for ip, body in re.findall(r'(?m)^\s*lease\s+(\S+)\s*\{([^}]*)\}', text):
        fields = {}
        body = re.sub(r'#[^\n]*', '', body)  # comments (epoch dates carry one)
        for stmt in body.split(';'):
            stmt = stmt.strip()
            for key in ('starts', 'ends', 'hardware ethernet', 'binding state'):
                if stmt.startswith(key + ' '):
                    fields[key] = stmt[len(key) + 1:].strip()
        try:
            leases.append({'ip': ipaddress.IPv4Address(ip),
                           'mac': fields.get('hardware ethernet', '').lower(),
                           'starts': lease_time(fields['starts']),
                           'ends': lease_time(fields.get('ends', 'never')),
                           'state': fields.get('binding state', 'active')})
        except (KeyError, ValueError, IndexError):
            continue  # malformed entry: never used
    return leases


def mgmt_subnet(conf, vnet):
    """The subnet whose block declares `host <vnet>` in vmnetdhcp.conf."""
    parts = re.split(r'(?m)^\s*subnet\s+', conf)
    for part in parts[1:]:
        head = re.match(r'(\S+)\s+netmask\s+(\S+)', part)
        if head and re.search(r'(?m)^\s*host\s+' + re.escape(vnet) + r'\s*\{', part):
            return ipaddress.IPv4Network(head.group(1) + '/' + head.group(2))
    return None


def pick_address(leases, mac, subnet, now):
    """(address, others) for this MAC, or (None, reason).

    dhcpd.leases(5): the file is append-only and "if more than one declaration
    appears for a given lease, the last one in the file is the current one". So
    each address counts only by its last entry, which must be this MAC's, active
    and not expired; an address since handed to another MAC drops out.
    """
    last = {}
    for l in leases:
        last[l['ip']] = l
    if not any(l['mac'] == mac and l['ip'] in subnet for l in leases):
        return None, 'no management DHCP lease yet'
    current = [l for l in last.values()
               if l['mac'] == mac and l['ip'] in subnet and l['state'] == 'active'
               and (l['ends'] is None or l['ends'] > now)]
    if not current:
        return None, 'no current management DHCP lease (only expired, released or reassigned ones)'
    current.sort(key=lambda l: l['starts'])
    address = current[-1]['ip']
    others = sorted(str(l['ip']) for l in current[:-1])
    return address, others


def main():
    here = Path(__file__).resolve().parent
    project = here.parent
    try:
        vms = json.loads(subprocess.check_output(
            ['terraform', '-chdir=' + str(project / 'terraform'), 'output', '-json', 'vms'],
            text=True, stderr=subprocess.DEVNULL))
    except subprocess.CalledProcessError:
        fatal('No Terraform output "vms"; run ./lab up first')
    if not vms:
        fatal('No lab VMs in the Terraform state')

    private = Path(os.environ.get('LAB_PRIVATE_DIR', str(Path.home() / '.config/wsl-vmware-lab')))
    key = Path(os.environ.get('LAB_SSH_KEY', str(private / 'lab_ed25519')))
    if not key.is_file():
        fatal('Missing lab SSH key: ' + str(key) + ' (run ./lab setup)')
    leases = parse_leases(Path(os.environ.get('LAB_DHCP_LEASES', '/mnt/c/ProgramData/VMware/vmnetdhcp.leases')).read_text())
    conf_file = Path(os.environ.get('LAB_DHCP_CONF', '/mnt/c/ProgramData/VMware/vmnetdhcp.conf'))
    vnet = os.environ.get('LAB_MGMT_VNET', 'VMnet1')
    subnet = mgmt_subnet(conf_file.read_text(), vnet)
    if subnet is None:
        fatal('No DHCP subnet for ' + vnet + ' in ' + str(conf_file) + ' (LAB_MGMT_VNET); enable DHCP on it in the Virtual Network Editor')
    vmrun = str(Path(os.environ.get('VMWARE_DIR', '/mnt/c/Program Files/VMware/VMware Workstation')) / 'vmrun.exe')
    proxy_command = 'bash ' + shlex.quote(str(here / 'guest-proxy.sh')) + ' %h %p'
    now = datetime.now(timezone.utc)

    def guest_var(vm, name):
        try:
            return subprocess.run([vmrun, '-T', 'ws', 'readVariable', vm['path'], 'guestVar', name],
                                  capture_output=True, text=True, timeout=30).stdout.strip()
        except subprocess.TimeoutExpired:
            return ''  # a hung vmrun counts as not reported yet

    hosts, groups, known, waiting = {}, {}, {}, []
    for name, vm in sorted(vms.items()):
        if not re.fullmatch(r'[A-Za-z0-9_-]+', vm['id']):
            fatal(name + ': unexpected VM id ' + repr(vm['id']))
        vmx_file = Path(subprocess.check_output(['wslpath', '-u', vm['path']], text=True).strip())
        if not vmx_file.is_file():
            waiting.append(name + ': VMX missing (' + vm['path'] + '); run ./lab up to reconcile')
            continue
        match = re.search(r'(?m)^\s*ethernet1\.generatedAddress\s*=\s*"([0-9A-Fa-f:]{17})"', vmx_file.read_text())
        if not match:
            waiting.append(name + ': management NIC has no MAC yet')
            continue
        address, others = pick_address(leases, match.group(1).lower(), subnet, now)
        if address is None:
            waiting.append(name + ': ' + others)
            continue
        # The guest user is the image's default user; the guest reports it and
        # its SSH host key through VMware guestinfo on every boot.
        guest_user = guest_var(vm, 'wsl-vmware-lab.guest_user')
        if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', guest_user):
            waiting.append(name + ': guest has not reported its default user through guestinfo yet '
                           '(needs open-vm-tools in the guest; Ubuntu cloud images ship it)')
            continue
        host_key = guest_var(vm, 'wsl-vmware-lab.host_key')
        if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]+={0,3}', host_key):
            waiting.append(name + ': guest has not reported its SSH host key through guestinfo yet '
                           '(a clone created before host-key reporting never will; recreate it)')
            continue
        alias = 'wsl-vmware-lab-' + vm['id']
        known[vm['id']] = alias + ' ' + host_key + '\n'
        proxy = ''
        try:
            with socket.create_connection((str(address), 22), timeout=3):
                pass
        except OSError:
            proxy = ' -o ' + shlex.quote('ProxyCommand=' + proxy_command)
        hosts[name] = {
            'ansible_host': str(address), 'ansible_user': guest_user,
            'ansible_ssh_private_key_file': str(key),
            'ansible_python_interpreter': '/usr/bin/python3',
            # Only the key this VM reported is accepted, whatever answers at the address.
            'ansible_ssh_common_args': '-o StrictHostKeyChecking=yes -o HostKeyAlias=' + alias +
                ' -o UserKnownHostsFile=' + str(private / ('known_hosts-' + vm['id'])) + proxy,
        }
        for group in ['lab'] + list(vm.get('groups') or []):
            groups.setdefault(group, {})[name] = {}
        note = ('  (also current: ' + ', '.join(others) + '; using the newest)') if others else ''
        print('[OK] ' + name + ': ' + str(address) + '  user (image default, from guestinfo): ' + guest_user
              + '  groups: ' + ','.join(vm.get('groups') or []) + note)

    if waiting:
        print('Not ready, retrying: ' + '; '.join(waiting), file=sys.stderr)
        sys.exit(NOT_READY)

    def write_private(path, text):
        tmp = path.with_name(path.name + '.tmp')
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    # Written only once every VM checked out, so a failed run leaves the
    # previous files as they were.
    for vm_id, line in known.items():
        write_private(private / ('known_hosts-' + vm_id), line)
    inventory = {'all': {'hosts': hosts,
                         'children': {g: {'hosts': members} for g, members in sorted(groups.items())}}}
    target = Path(os.environ.get('LAB_INVENTORY', str(private / 'inventory.json')))
    write_private(target, json.dumps(inventory, indent=2) + '\n')
    print('[OK] Inventory: ' + str(target) + '  hosts: ' + str(len(hosts)))


if __name__ == '__main__':
    main()
