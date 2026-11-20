"""Offline tests for debian-12, rocky-9, and almalinux-9 cloud image support."""
import hashlib
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


class CloudImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def _run_base(self, image, img_file, checksum_body):
        proj = self.root / f'repo-{image}'
        (proj / 'lib').mkdir(parents=True)
        for name in ('base.sh', 'config.sh', 'config-functions.sh', 'envelope.py'):
            shutil.copyfile(ROOT / 'lib' / name, proj / 'lib' / name)
        (proj / 'lib/register-vm.py').write_text('pass\n')

        bin_dir = self.root / f'bin-{image}'
        bin_dir.mkdir()
        (bin_dir / 'curl').write_text(
            '#!/bin/bash\n'
            'out=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi\n'
            'done\n'
            'if [[ "$out" == *.part ]]; then\n'
            '  printf "fake-cloud-image-bytes" > "$out"\n'
            'else\n'
            '  printf "%s\\n" "$FIXTURE_CHECKSUM_BODY" > "$out"\n'
            'fi\n'
        )
        (bin_dir / 'curl').chmod(0o700)
        (bin_dir / 'qemu-img').write_text(
            '#!/bin/bash\n'
            'if [[ "$1" == "convert" ]]; then touch "${@: -1}"; exit 0; fi\n'
            'if [[ "$1" == "info" ]]; then echo \'{"format":"vmdk","virtual-size":1024}\'; exit 0; fi\n'
            'exit 1\n'
        )
        (bin_dir / 'qemu-img').chmod(0o700)
        (bin_dir / 'wslpath').write_text('#!/bin/bash\nprintf "%s\\n" "$2"\n')
        (bin_dir / 'wslpath').chmod(0o700)

        private = self.root / f'private-{image}'
        private.mkdir(mode=0o700)
        key = private / 'lab_ed25519'
        key.write_text('fake-key')
        key.chmod(0o600)

        env = os.environ.copy()
        env.update(
            PATH=f"{bin_dir}:{env['PATH']}",
            LAB_ENV_FILE=str(self.root / 'absent.env'),
            LAB_WINDOWS_PROFILE='',
            LAB_PRIVATE_DIR=str(private),
            LAB_BASE_DIR=str(self.root / f'base-{image}'),
            LAB_IMAGE=image,
            VMWS_USERNAME='user',
            VMWS_PASSWORD='password',
            FIXTURE_CHECKSUM_BODY=checksum_body,
        )
        run = subprocess.run(['bash', str(proj / 'lib/base.sh')], env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(run.returncode, 0, run.stderr)
        base = self.root / f'base-{image}' / image
        self.assertTrue((base / 'base.vmdk').is_file())
        self.assertTrue((base / 'base.prepared').is_file())
        self.assertFalse((base / 'mods.iso').exists())
        return (base / 'base.vmx').read_text()

    def test_base_sh_prepares_debian12_rocky9_almalinux9(self):
        payload = b'fake-cloud-image-bytes'
        sha256 = hashlib.sha256(payload).hexdigest()
        sha512 = hashlib.sha512(payload).hexdigest()

        deb_vmx = self._run_base(
            'debian-12',
            'debian-12-generic-amd64.qcow2',
            f'{sha512}  debian-12-generic-amd64.qcow2',
        )
        self.assertIn('guestOS = "debian12-64"', deb_vmx)
        self.assertIn('scsi0:0.fileName = "base.vmdk"', deb_vmx)
        self.assertIn('ethernet0.virtualDev = "e1000"', deb_vmx)

        rocky_vmx = self._run_base(
            'rocky-9',
            'Rocky-9-GenericCloud-Base.latest.x86_64.qcow2',
            f'# Rocky-9-GenericCloud-Base.latest.x86_64.qcow2: 22 bytes\n'
            f'SHA256 (Rocky-9-GenericCloud-Base.latest.x86_64.qcow2) = {sha256}',
        )
        self.assertIn('guestOS = "rhel9-64"', rocky_vmx)
        self.assertIn('sata0:0.fileName = "base.vmdk"', rocky_vmx)
        self.assertIn('pciBridge4.virtualDev = "pcieRootPort"', rocky_vmx)
        self.assertIn('ethernet0.virtualDev = "vmxnet3"', rocky_vmx)

        alma_vmx = self._run_base(
            'almalinux-9',
            'AlmaLinux-9-GenericCloud-latest.x86_64.qcow2',
            f'{sha256}  AlmaLinux-9-GenericCloud-latest.x86_64.qcow2',
        )
        self.assertIn('guestOS = "rhel9-64"', alma_vmx)
        self.assertIn('sata0:0.fileName = "base.vmdk"', alma_vmx)
        self.assertIn('pciBridge4.virtualDev = "pcieRootPort"', alma_vmx)
        self.assertIn('ethernet0.virtualDev = "vmxnet3"', alma_vmx)

    def test_bootstrap_rhel9_uses_vmxnet3_and_en_match_without_mods_iso(self):
        proj = self.root / 'repo-boot'
        (proj / 'lib').mkdir(parents=True)
        for name in ('bootstrap-guest.sh', 'cloud-config.sh', 'config.sh', 'config-functions.sh'):
            shutil.copyfile(ROOT / 'lib' / name, proj / 'lib' / name)

        bin_dir = self.root / 'bin-boot'
        bin_dir.mkdir()
        (bin_dir / 'vmrun.exe').write_text('#!/bin/bash\necho "Total running VMs: 0"\n')
        (bin_dir / 'vmrun.exe').chmod(0o700)
        (bin_dir / 'wslpath').write_text('#!/bin/bash\nprintf "%s\\n" "$2"\n')
        (bin_dir / 'wslpath').chmod(0o700)
        (bin_dir / 'cloud-localds').write_text('#!/bin/bash\ntouch "${@: -3:1}"\n')
        (bin_dir / 'cloud-localds').chmod(0o700)

        private = self.root / 'private-boot'
        private.mkdir(mode=0o700)
        (private / 'lab_ed25519.pub').write_text('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeLabKey lab\n')

        for image, vm_id in (('rocky-9', 'R9VM01'), ('almalinux-9', 'A9VM01')):
            with self.subTest(image=image):
                clone_dir = self.root / 'clones' / image
                clone_dir.mkdir(parents=True)
                vmx = clone_dir / f'{image}.vmx'
                vmx.write_text(f'displayName = "{image}"\nsata0:0.fileName = "{image}.vmdk"\n')
                env = os.environ.copy()
                env.update(
                    PATH=f"{bin_dir}:{env['PATH']}",
                    LAB_ENV_FILE=str(self.root / 'absent.env'),
                    LAB_WINDOWS_PROFILE='',
                    LAB_PRIVATE_DIR=str(private),
                    LAB_BASE_DIR=str(self.root / 'base'),
                    VMWARE_DIR=str(bin_dir),
                    VMX_WIN=str(vmx),
                    VM_ID=vm_id,
                    VM_NAME=image,
                    VM_IMAGE=image,
                    VM_LAN='dhcp',
                )
                run = subprocess.run(['bash', str(proj / 'lib/bootstrap-guest.sh')], env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(run.returncode, 0, run.stderr)
                vmx_text = vmx.read_text()
                self.assertIn('ethernet1.virtualDev = "vmxnet3"', vmx_text)
                self.assertIn('pciBridge4.virtualDev = "pcieRootPort"', vmx_text)
                self.assertNotIn('ide1:1.fileName', vmx_text)
                net_cfg = (private / f'seed-{vm_id}/network-config').read_text()
                self.assertIn('name: "en*"', net_cfg)
                self.assertNotIn('driver: e1000', net_cfg)
                user_data = (private / f'seed-{vm_id}/user-data').read_text()
                self.assertNotIn('OL8MODS', user_data)
