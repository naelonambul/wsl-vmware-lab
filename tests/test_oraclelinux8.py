"""Offline tests for Oracle Linux 8 (oraclelinux-8) base and bootstrap support."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

os.environ.setdefault('PYTHONDONTWRITEBYTECODE', '1')

ROOT = Path(__file__).resolve().parents[1]


def setUpModule():
    if sys.platform != 'linux':
        raise unittest.SkipTest('requires Linux (WSL Ubuntu or ubuntu-latest); never run with Git Bash')


class OracleLinux8Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def _run_cloud_config(self, image='', lan='none', lan_mac=''):
        key = self.root / 'host_ed25519'
        key.write_text('-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n')
        (self.root / 'host_ed25519.pub').write_text('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKey test\n')
        cmd = [
            'bash', '-euo', 'pipefail', '-c',
            'source "$1"; LAB_GUEST_USER=lab; lab_cloud_config_user_data "$2" "$3" "$4" "$5" "$6"',
            '--',
            str(ROOT / 'lib/cloud-config.sh'),
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeLabKey lab',
            str(key),
            image,
            lan,
            lan_mac,
        ]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15)

    def test_cloud_config_ol8_vs_ubuntu(self):
        ubuntu = self._run_cloud_config('ubuntu-24.04', 'none', '')
        self.assertEqual(ubuntu.returncode, 0, ubuntu.stderr)
        self.assertNotIn('OL8MODS', ubuntu.stdout)
        self.assertNotIn('runcmd:', ubuntu.stdout)

        ol8_none = self._run_cloud_config('oraclelinux-8', 'none', '')
        self.assertEqual(ol8_none.returncode, 0, ol8_none.stderr)
        self.assertIn('runcmd:', ol8_none.stdout)
        self.assertIn('/dev/disk/by-label/OL8MODS', ol8_none.stdout)
        self.assertIn('rpm -ivh --nodeps /mnt/ol8mods/kernel-uek-modules-*.rpm', ol8_none.stdout)
        self.assertIn('depmod -a', ol8_none.stdout)
        self.assertIn('modprobe vmxnet3', ol8_none.stdout)
        self.assertIn("lan='none'", ol8_none.stdout)

        ol8_dhcp = self._run_cloud_config('oraclelinux-8', 'dhcp', '00:50:56:12:34:56')
        self.assertEqual(ol8_dhcp.returncode, 0, ol8_dhcp.stderr)
        self.assertIn("lan='dhcp'", ol8_dhcp.stdout)
        self.assertIn("lan_mac='00:50:56:12:34:56'", ol8_dhcp.stdout)
        self.assertIn('ipv4.never-default yes', ol8_dhcp.stdout)

        ol8_static = self._run_cloud_config('oraclelinux-8', '192.0.2.50/24', '00:50:56:12:34:56')
        self.assertEqual(ol8_static.returncode, 0, ol8_static.stderr)
        self.assertIn("lan='192.0.2.50/24'", ol8_static.stdout)
        self.assertIn('ipv4.method manual', ol8_static.stdout)

        bad_mac = self._run_cloud_config('oraclelinux-8', 'dhcp', 'not-a-mac')
        self.assertNotEqual(bad_mac.returncode, 0)

    def test_bootstrap_guest_attaches_mods_iso_and_vmxnet3(self):
        proj = self.root / 'repo'
        (proj / 'lib').mkdir(parents=True)
        for name in ('bootstrap-guest.sh', 'cloud-config.sh', 'config.sh', 'config-functions.sh'):
            shutil.copyfile(ROOT / 'lib' / name, proj / 'lib' / name)

        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'vmrun.exe').write_text('#!/bin/bash\necho "Total running VMs: 0"\n')
        (bin_dir / 'vmrun.exe').chmod(0o700)
        (bin_dir / 'wslpath').write_text('#!/bin/bash\nprintf "%s\\n" "$2"\n')
        (bin_dir / 'wslpath').chmod(0o700)
        (bin_dir / 'cloud-localds').write_text('#!/bin/bash\ntouch "${@: -3:1}"\n')
        (bin_dir / 'cloud-localds').chmod(0o700)

        private = self.root / 'private'
        private.mkdir(mode=0o700)
        (private / 'lab_ed25519.pub').write_text('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeLabKey lab\n')

        base_dir = self.root / 'base'
        (base_dir / 'oraclelinux-8').mkdir(parents=True)
        mods_iso = base_dir / 'oraclelinux-8/mods.iso'

        clone_dir = self.root / 'clones/ol8-node'
        clone_dir.mkdir(parents=True)
        vmx = clone_dir / 'ol8-node.vmx'
        vmx.write_text('displayName = "ol8-node"\nsata0:0.fileName = "ol8-node.vmdk"\n')

        env = os.environ.copy()
        env.update(
            PATH=f"{bin_dir}:{env['PATH']}",
            LAB_ENV_FILE=str(self.root / 'absent.env'),
            LAB_WINDOWS_PROFILE='',
            LAB_PRIVATE_DIR=str(private),
            LAB_BASE_DIR=str(base_dir),
            VMWARE_DIR=str(bin_dir),
            VMX_WIN=str(vmx),
            VM_ID='OL8VM01',
            VM_NAME='ol8-node',
            VM_IMAGE='oraclelinux-8',
            VM_LAN='none',
        )

        # Missing mods.iso must fail before editing VMX.
        missing = subprocess.run(['bash', str(proj / 'lib/bootstrap-guest.sh')], env=env, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('mods.iso', missing.stderr)
        self.assertNotIn('ide1:0.fileName', vmx.read_text())

        # With mods.iso present, VMX gets ide1:1, vmxnet3, PCIe root port, and OL8MODS user-data.
        mods_iso.write_text('fake-iso')
        ok = subprocess.run(['bash', str(proj / 'lib/bootstrap-guest.sh')], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        vmx_text = vmx.read_text()
        self.assertIn(f'ide1:1.fileName = "{mods_iso}"', vmx_text)
        self.assertIn('ide1:1.present = "TRUE"', vmx_text)
        self.assertIn('ethernet1.virtualDev = "vmxnet3"', vmx_text)
        self.assertIn('pciBridge4.virtualDev = "pcieRootPort"', vmx_text)
        user_data = (private / 'seed-OL8VM01/user-data').read_text()
        self.assertIn('/dev/disk/by-label/OL8MODS', user_data)

    def test_base_sh_prepares_ol8_mods_iso_and_sata_vmx(self):
        proj = self.root / 'repo'
        (proj / 'lib').mkdir(parents=True)
        for name in ('base.sh', 'config.sh', 'config-functions.sh', 'envelope.py'):
            shutil.copyfile(ROOT / 'lib' / name, proj / 'lib' / name)
        (proj / 'lib/register-vm.py').write_text('pass\n')

        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'curl').write_text(
            '#!/bin/bash\n'
            'out=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi\n'
            'done\n'
            'printf "fake-download" > "$out"\n'
        )
        (bin_dir / 'curl').chmod(0o700)
        (bin_dir / 'sha256sum').write_text('#!/bin/bash\nexit 0\n')
        (bin_dir / 'sha256sum').chmod(0o700)
        (bin_dir / 'qemu-img').write_text(
            '#!/bin/bash\n'
            'if [[ "$1" == "convert" ]]; then touch "${@: -1}"; exit 0; fi\n'
            'if [[ "$1" == "info" ]]; then echo \'{"format":"vmdk","virtual-size":1024}\'; exit 0; fi\n'
            'exit 1\n'
        )
        (bin_dir / 'qemu-img').chmod(0o700)
        (bin_dir / 'genisoimage').write_text(
            '#!/bin/bash\n'
            'echo "$*" > "$FIXTURE_GENISO_ARGS"\n'
            'out=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi\n'
            'done\n'
            'printf "fake-mods-iso" > "$out"\n'
        )
        (bin_dir / 'genisoimage').chmod(0o700)
        (bin_dir / 'wslpath').write_text('#!/bin/bash\nprintf "%s\\n" "$2"\n')
        (bin_dir / 'wslpath').chmod(0o700)

        private = self.root / 'private'
        private.mkdir(mode=0o700)
        key = private / 'lab_ed25519'
        key.write_text('fake-key')
        key.chmod(0o600)

        geniso_args = self.root / 'geniso.args'
        env = os.environ.copy()
        env.update(
            PATH=f"{bin_dir}:{env['PATH']}",
            LAB_ENV_FILE=str(self.root / 'absent.env'),
            LAB_WINDOWS_PROFILE='',
            LAB_PRIVATE_DIR=str(private),
            LAB_BASE_DIR=str(self.root / 'base'),
            LAB_IMAGE='oraclelinux-8',
            VMWS_USERNAME='user',
            VMWS_PASSWORD='password',
            FIXTURE_GENISO_ARGS=str(geniso_args),
        )
        run = subprocess.run(['bash', str(proj / 'lib/base.sh')], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(run.returncode, 0, run.stderr)

        base = self.root / 'base/oraclelinux-8'
        self.assertTrue((base / 'base.vmdk').is_file())
        self.assertTrue((base / 'mods.iso').is_file())
        self.assertTrue((base / 'base.prepared').is_file())
        self.assertIn('-V OL8MODS', geniso_args.read_text())

        vmx = (base / 'base.vmx').read_text()
        self.assertIn('guestOS = "oraclelinux8-64"', vmx)
        self.assertIn('firmware = "efi"', vmx)
        self.assertIn('sata0.present = "TRUE"', vmx)
        self.assertIn('sata0:0.fileName = "base.vmdk"', vmx)
        self.assertIn('pciBridge4.virtualDev = "pcieRootPort"', vmx)
        self.assertIn('ethernet0.virtualDev = "vmxnet3"', vmx)
