"""PR 1 offline checks. Never invokes lab, Terraform or live infrastructure."""
import ast
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('network_inspect', ROOT / 'lib/network-inspect.py')
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.env = patch.dict(os.environ, {
            'LAB_BASE_DIR': str(self.folder / 'base'), 'LAB_NAT_VNET': 'VMnet8',
            'LAB_MGMT_VNET': 'VMnet1', 'LAB_LAN_VNET': ''})
        self.env.start()
        self.addCleanup(self.env.stop)

    def vm(self, text):
        path = self.folder / 'fixture.vmx'
        path.write_text(text, encoding='utf-8')
        return dict(name='fixture', id='fixture-id', path=str(path))

    def state(self, vm):
        return {'values': {'root_module': {'child_modules': [{
            'resources': [dict(mode='managed', type='vmworkstation_virtual_machine',
                               index=vm['name'], values=vm)]}]}},
                'outputs': {'vms': {'value': {}}}}

    def gate(self, vm):
        err = io.StringIO()
        with patch.object(network.sys, 'argv', ['network-inspect.py', 'gate']), \
                patch.object(network.sys, 'stdin', io.StringIO(json.dumps(self.state(vm)))), \
                redirect_stderr(err):
            result = network.main()
        return result, err.getvalue()

    def test_bridged_custom_and_no_lan(self):
        for configured, connection, vnet in [('', 'bridged', ''), ('VMnet0', 'bridged', ''),
                                               ('VMnet2', 'custom', 'ethernet2.vnet = "VMnet2"')]:
            with self.subTest(configured=configured):
                os.environ['LAB_LAN_VNET'] = configured
                vm = self.vm(f'ethernet2.present = "TRUE"\nethernet2.connectionType = "{connection}"\n{vnet}\n')
                self.assertEqual(self.gate(vm)[0], 0)
        self.assertEqual(self.gate(self.vm('ethernet2.present = "FALSE"'))[0], 0)

    def test_mismatch_lists_desired_actual_and_ignores_stale_outputs(self):
        vm = self.vm('ethernet2.present = "TRUE"\nethernet2.connectionType = "custom"\nethernet2.vnet = "VMnet2"')
        rc, error = self.gate(vm)
        self.assertEqual(rc, 5)
        self.assertEqual(json.loads(error)[0]['desired']['connectionType'], 'bridged')
        self.assertEqual(json.loads(error)[0]['actual']['vnet'], 'VMnet2')
        os.environ['LAB_LAN_VNET'] = 'VMnet3'
        self.assertEqual(self.gate(vm)[0], 5)

    def test_stale_vnet_missing_and_duplicate_vmx_fail_closed(self):
        self.assertEqual(self.gate(self.vm('ethernet2.present = "TRUE"\n'
            'ethernet2.connectionType = "bridged"\nethernet2.vnet = "VMnet2"'))[0], 5)
        vm = self.vm('ethernet2.present = "TRUE"\nethernet2.present = "FALSE"')
        self.assertEqual(self.gate(vm)[0], 1)
        (self.folder / 'fixture.vmx').unlink()
        self.assertEqual(self.gate(vm)[0], 1)

    def test_malformed_vmx_fails_closed(self):
        for line in ['ethernet2.present = TRUE', "ethernet2.vnet = 'VMnet2'",
                     'ethernet2.vnet = "VMnet2', 'ethernet2.vnet "VMnet2"',
                     'ethernet2.vnet = "VMnet2" trailing', 'not an assignment',
                     'displayName = unquoted',
                     'ETHERNET2.PRESENT = FALSE']:
            with self.subTest(line=line):
                vm = self.vm('ethernet2.present = "TRUE"\n' + line)
                rc, error = self.gate(vm)
                self.assertEqual(rc, 1)
                self.assertIn('malformed VMX line', json.loads(error)[0]['error'])

    def test_mixed_case_keys_and_case_colliding_duplicates(self):
        vm = self.vm('Ethernet2.Present = "true"\nETHERNET2.ConnectionType = "bridged"')
        self.assertEqual(self.gate(vm)[0], 0)
        self.assertTrue(network.lan_evidence(vm)['lan'])
        vm = self.vm('ethernet2.present = "TRUE"\nETHERNET2.PRESENT = "FALSE"')
        rc, error = self.gate(vm)
        self.assertEqual(rc, 1)
        self.assertIn('duplicate VMX key', json.loads(error)[0]['error'])

    def test_absent_ethernet2_is_no_lan(self):
        vm = self.vm('\n  # comment\ndisplayName = "fixture" # comment\n')
        self.assertEqual(self.gate(vm)[0], 0)
        actual = network.lan_evidence(vm)
        self.assertFalse(actual['lan'])
        self.assertFalse(actual['mismatch'])
        self.assertIsNone(actual['error'])
        self.assertEqual(actual['desired'],'none')

    def test_status_desired_none_for_disabled_lan(self):
        vm=self.vm('ethernet2.present = "FALSE"\nethernet2.connectionType = "custom"')
        out=io.StringIO()
        with patch.object(network.sys,'argv',['network-inspect.py','status']), \
                patch.object(network.sys,'stdin',io.StringIO(json.dumps(self.state(vm)))), redirect_stdout(out):
            self.assertEqual(network.main(),0)
        report=json.loads(out.getvalue().split('\t')[2])
        self.assertEqual(report['desired'],'none')
        self.assertFalse(report['mismatch'])

    def test_preflight_vm_folder_only_compares_explicit_preference(self):
        source=(ROOT/'lib/preflight.sh').read_text()
        block=source[source.index('if $interop && [[ -n "$LAB_VM_ROOT_WIN" ]]'):source.index('[[ -n "${LAB_CLONE_VMX_WIN:-}"')]
        (self.folder/'VMware').mkdir()
        prefs=self.folder/'VMware/preferences.ini'
        prefix='''
interop=true
PS=fake_powershell
fake_powershell() { printf '%s' "$FIXTURE_APPDATA"; }
wslpath() { printf '%s' "$2"; }
warn() { printf '[WARN] %s\\n' "$*"; }
ok() { printf '[OK] %s\\n' "$*"; }
'''
        env=dict(os.environ,FIXTURE_APPDATA=self.folder.as_posix(),LAB_VM_ROOT_WIN='C:\\VMs')
        for content,expected in [(None,''),('other.key = "value"',''),
                ('prefvmx.defaultVMPath = "c:/vms/"','[OK]'),
                ('prefvmx.defaultVMPath = "C:\\Other"','[WARN]')]:
            if content is not None: prefs.write_text(content)
            script=self.folder/'preflight-fixture.sh'
            script.write_text('set -euo pipefail\n'+prefix+block,newline='\n')
            run=subprocess.run(['bash',script.as_posix()],env=env,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            if expected: self.assertIn(expected,run.stdout)
            else: self.assertEqual(run.stdout,'')

    def test_report_base_difference_and_null_reason(self):
        base = self.folder / 'base' / 'example'
        base.mkdir(parents=True)
        (base / 'base.vmx').write_text('ethernet0.vnet = "VMnet2"')
        result = network.evidence({})
        self.assertTrue(result['bases'][0]['mismatch'])
        vm = self.vm('')
        (self.folder / 'fixture.vmx').unlink()
        actual = network.lan_evidence(vm)
        self.assertIsNone(actual['actual'])
        self.assertTrue(actual['error'])

    def test_json_report_and_status_include_state_instances(self):
        vm = self.vm('ethernet2.present = "TRUE"\nethernet2.connectionType = "bridged"')
        windows = self.folder / 'windows.json'
        windows_data = {'netmap': {'data': None, 'reason': '자료 없음'},
                        'adapters': {'data': [{'Name': '이더넷'}], 'reason': None},
                        'bridgeBindings': {'data': [], 'reason': None}}
        windows.write_bytes(json.dumps(windows_data, ensure_ascii=False).encode('utf-8'))
        for mode in ['report', 'status']:
            out = io.StringIO()
            with patch.object(network.sys, 'argv', ['network-inspect.py', mode, str(windows)]), \
                    patch.object(network.sys, 'stdin', io.StringIO(json.dumps(self.state(vm)))), \
                    redirect_stdout(out):
                self.assertEqual(network.main(), 0)
            if mode == 'report':
                report = json.loads(out.getvalue())
                self.assertEqual(report['vms'][0]['name'], 'fixture')
                self.assertIsNone(report['windows']['netmap']['data'])
                self.assertEqual(report['windows'], windows_data)
            else:
                name, vm_id, lan = out.getvalue().strip().split('\t')
                self.assertEqual((name, vm_id), ('fixture', 'fixture-id'))
                self.assertFalse(json.loads(lan)['mismatch'])

    def test_validation_before_any_host_discovery(self):
        # Only execute the config prefix ending before profile discovery.
        prefix = (ROOT / 'lib/config.sh').read_text().split('# Windows user profile')[0]
        # BASH_SOURCE is unset with bash -c, so replace only project detection.
        prefix = prefix.replace('LAB_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"',
                                'LAB_PROJECT_DIR="$PWD"')
        for lan in ['', 'VMnet0', 'VMnet2', 'VMnet9', 'VMnet10', 'VMnet19',
                    'VMnet20', 'VMnet01', 'vmnet2', 'VMnet-1', 'VMnet2x', 'VMnet1', 'VMnet8']:
            env = dict(os.environ, LAB_LAN_VNET=lan, LAB_ENV_FILE='nonexistent-fixture.env')
            result = subprocess.run(['bash', '-c', prefix], cwd=ROOT, env=env, capture_output=True, text=True)
            expected = 0 if lan in ['', 'VMnet0', 'VMnet2', 'VMnet9', 'VMnet10', 'VMnet19'] else 2
            self.assertEqual(result.returncode, expected, (lan, result.stderr))
            if expected:
                self.assertIn('config_error', result.stderr)
        for role in ['LAB_NAT_VNET', 'LAB_MGMT_VNET']:
            env = dict(os.environ, LAB_LAN_VNET='', LAB_ENV_FILE='nonexistent-fixture.env')
            env[role] = 'VMnet0'
            self.assertEqual(subprocess.run(['bash', '-c', prefix], cwd=ROOT, env=env,
                capture_output=True).returncode, 2)

    def test_bootstrap_python_bridged_custom_preserves_mac(self):
        source = (ROOT / 'lib/bootstrap-guest.sh').read_text().split("python3 - <<'PY'\n")[1].split('\nPY')[0]
        tree = ast.parse(source)
        # Execute the production VMX transformation only; stop before writes.
        tree.body = tree.body[:next(i for i, node in enumerate(tree.body)
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'tmp' for t in node.targets))]
        for lan in ['', 'VMnet0', 'VMnet2', 'VMnet19']:
            vm = self.vm('ethernet2.vnet = "VMnet7"\n')
            env = dict(VMX_LINUX=vm['path'], VM_LAN='dhcp', LAN_MAC='00:50:56:00:00:01', SEED_WIN='fixture.iso', LAB_LAN_VNET=lan)
            with patch.dict(os.environ, env):
                scope = {}
                exec(compile(tree, '<bootstrap VMX transformation>', 'exec'), scope)
            self.assertIn('ethernet2.address = "00:50:56:00:00:01"', scope['s'])
            if lan in ['', 'VMnet0']:
                self.assertIn('ethernet2.connectionType = "bridged"', scope['s'])
                self.assertNotIn('ethernet2.vnet', scope['s'])
            else:
                self.assertIn('ethernet2.connectionType = "custom"', scope['s'])
                self.assertIn(f'ethernet2.vnet = "{lan}"', scope['s'])

    def test_mismatch_blocks_up_variants_but_allows_down(self):
        # Execute lifecycle control flow only, substituting its config boundary.
        # All infrastructure commands are shell functions; none can reach a host.
        source = (ROOT / 'lib/lifecycle.sh').read_text()
        config = (ROOT / 'lib/config.sh').read_text()
        fail_function = config[config.index('lab_fail() {'):config.index('\nLAB_ENV_FILE=')]
        mocks = r'''
cd "$FIXTURE_DIR"
LAB_PROJECT_DIR="$PWD"
LAB_TF_VAR_ARGS=()
LAB_VMS_FILE=fixture.tfvars
LAB_CLONE_NAME=fixture
TF_VAR_vmrest_endpoint=offline
lab_terraform_env() { :; }
lab_base_identity() { echo base >> "$LAB_PROJECT_DIR/calls"; }
lab_curl_auth() { :; }
curl() { echo curl >> "$LAB_PROJECT_DIR/calls"; printf 200; }
terraform() {
  echo "terraform $*" >> "$LAB_PROJECT_DIR/calls"
  case "$1 $2" in
    'show -json') printf '{}';;
    'state list') echo 'vmworkstation_virtual_machine.vm["fixture"]';;
  esac
}
python3() {
  case "$1" in
    ../lib/network-inspect.py)
      cat >/dev/null
      echo gate >> "$LAB_PROJECT_DIR/calls"
      return 5;;
    ../lib/cleanup-guest.py)
      echo cleanup >> "$LAB_PROJECT_DIR/calls";;
    -c) :;;
    *) echo 'Unexpected Python boundary' >&2; exit 99;;
  esac
}
'''
        source = source.replace('source "$(dirname "${BASH_SOURCE[0]}")/config.sh"',
                                fail_function + mocks, 1)
        terraform_dir = self.folder / 'terraform'
        terraform_dir.mkdir()
        # Fake files only, to make both the LAN gate and cleanup replay eligible.
        (terraform_dir / 'terraform.tfstate').write_text('{}')
        (terraform_dir / 'cleanup-pending.json').write_text('[]')
        calls = self.folder / 'calls'
        for action, args in [('up', ['on']), ('up --allow-destroy', ['on', '--allow-destroy']),
                             ('down', ['off', '--all'])]:
            with self.subTest(action=action):
                calls.write_text('')
                entry = source if action.startswith('up') else source.split('terraform init -input=false')[0] + '\nexit 0\n'
                result = subprocess.run(['bash', '-s', '--', *args], input=entry,
                                        cwd=ROOT, env=dict(os.environ, FIXTURE_DIR=self.folder.as_posix()),
                                        capture_output=True, text=True)
                reached = calls.read_text().splitlines()
                if action.startswith('up'):
                    self.assertEqual(result.returncode, 5, result.stderr)
                    self.assertIn('lan_vnet_mismatch', result.stderr)
                    self.assertEqual(reached, ['terraform show -json', 'gate'])
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn('gate', reached)
                    self.assertIn('base', reached)


if __name__ == '__main__':
    unittest.main()
