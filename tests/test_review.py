"""Review regressions: production command bodies, disposable external fakes."""
import json
import os
import shutil
import signal
import subprocess
import time
import unittest

import test_envelope as envelope_tests
from test_envelope import ROOT


class ReviewTests(envelope_tests.EnvelopeFixture, unittest.TestCase):
    # Reuse the fixture and assertions, without rerunning its dispatch tests.
    def setUp(self):
        super().setUp()
        for name in ('config.sh', 'config-functions.sh', 'preflight.sh', 'preflight-functions.sh', 'network.sh', 'configure.sh',
                     'lifecycle.sh', 'power-map.py', 'guest-inventory.py', 'check-base.py'):
            shutil.copyfile(ROOT/'lib'/name, self.root/'lib'/name)
        self.env.update(LAB_ENV_FILE=(self.root/'absent.env').as_posix(),
                        LAB_WINDOWS_PROFILE='C:\\fixture',
                        LAB_VM_ROOT_WIN=(self.root/'clones').as_posix(),
                        LAB_SECRETS_FILE=(self.root/'absent-secret').as_posix(),
                        LAB_PRIVATE_DIR=(self.root/'private').as_posix(),
                        LAB_BASE_DIR=(self.root/'base').as_posix(),
                        LAB_PLAYBOOK=(self.root/'playbook.yml').as_posix(),
                        LAB_GUEST_WAIT_SECONDS='2',
                        VMWS_ENDPOINT='http://127.0.0.1:8697/api')
        (self.root/'playbook.yml').write_text('---\n')
        base=self.root/'base/ubuntu-24.04'
        base.mkdir(parents=True)
        (base/'base.prepared').write_text('synthetic-marker')
        (base/'base.vmx').write_text('synthetic-vmx')
        # Replace only the absolute external executable path, never a body.
        ps = self.root/'fake-ps'
        ps.write_text('''#!/bin/bash
"$FIXTURE_PYTHON" "$FIXTURE_NATIVE/audit.py" argv powershell.exe "$@"
case "$*" in
  *Start-ScheduledTask*) /usr/bin/touch "$FIXTURE_NATIVE/started" ;;
  *UserProfile*) : ;;
  *Network) printf '{"adapters":[]}' ;;
  *LocalAddress*) echo 127.0.0.1 ;;
  *Get-Process*) echo 'process=False listener8697=False' ;;
esac
''', newline='\n')
        ps.chmod(0o700)
        for name in ('config-functions', 'preflight', 'network'):
            path = self.root/f'lib/{name}.sh'
            path.write_text(path.read_text().replace(
                '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
                ps.as_posix()), newline='\n')
        # Intercept Python's external process and HTTP boundaries too.
        (self.root/'external.py').write_text(r'''
import io, json, os, runpy, subprocess, sys, urllib.request
from pathlib import Path
real_run = subprocess.run
root = Path(os.environ['FIXTURE_NATIVE'])
secret = os.environ['VMWS_PASSWORD']
def fake_run(args, **kw):
    with (root/'argv.jsonl').open('a') as out:
        out.write(json.dumps(args)+'\n')
    assert secret not in ' '.join(args)
    if args[0] == 'curl':
        body = json.dumps(dict(power_state='poweredOff' if args[-1].split('/')[-2] in
            json.loads(os.environ.get('POWER_OFF','[]')) else 'poweredOn'))
        return subprocess.CompletedProcess(args, 0, body, '')
    if args[0] == 'terraform':
        if 'output' in args:
            body = json.dumps(dict(a=dict(id='a',path=str(root/'a.vmx'),groups=[])))
            return subprocess.CompletedProcess(args, 0, body, '')
        assert os.environ['TF_VAR_vmrest_password'] == secret
        return real_run([sys.executable,str(root/'fake-tf.py'),*args[1:]], **kw)
    if args[0] == 'wslpath':
        return subprocess.CompletedProcess(args,0,args[-1]+'\n','')
    if args[0] == 'ssh':
        return subprocess.CompletedProcess(args,0,'','')
    raise AssertionError('Unfaked external command: '+str(args))
subprocess.run = fake_run
def urlopen(request, **kwargs):
    # check-base's HTTP boundary only; never opens a socket.
    if request.full_url.endswith('/vms'):
        body=[dict(id='base',path=sys.argv[1])]
    elif request.full_url.endswith('/params/displayName'):
        body=dict(value='ubuntu-24.04-base')
    else:
        raise AssertionError('Unfaked HTTP request')
    return io.BytesIO(json.dumps(body).encode())
urllib.request.urlopen = urlopen
script, *sys.argv = sys.argv[1:]
sys.argv.insert(0, script)
sys.path.insert(0, str(root/'lib'))
runpy.run_path(script, run_name='__main__')
''', newline='\n')
        # Check temporary files before cleanup too; keep all temp paths here.
        (self.root/'scratch').mkdir()
        self.env['TMPDIR']=(self.root/'scratch').as_posix()
        (self.root/'audit.py').write_text(r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ['FIXTURE_NATIVE'])
secret = os.environ['VMWS_PASSWORD']
if sys.argv[1] == 'argv':
    with (root/'argv.jsonl').open('a') as out:
        out.write(json.dumps(sys.argv[2:])+'\n')
    assert all(secret not in arg for arg in sys.argv[2:])
elif sys.argv[1] == 'saved-plan':
    path = Path(sys.argv[2])
    assert path.parent == root/'private', str(path)
    assert secret.encode() in path.read_bytes()
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700
    with (root/'plan-audit.jsonl').open('a') as out:
        out.write(json.dumps(str(path))+'\n')
else:
    for path in root.rglob('*'):
        if path.is_file() and not path.is_symlink() and root/'private' not in path.parents:
            assert secret.encode() not in path.read_bytes(), str(path)
''', newline='\n')
        with (self.root/'bash-env').open('a') as out:
            out.write(r'''
fixture_argv() { "$FIXTURE_PYTHON" "$FIXTURE_NATIVE/audit.py" argv "$@"; }
python3() {
  fixture_argv python3 "$@"
  local script="$1"; shift
  if [[ "$script" == *.py ]]; then
    "$FIXTURE_PYTHON" "$FIXTURE_NATIVE/external.py" "$script" "$@"
  else
    "$FIXTURE_PYTHON" "$script" "$@"
  fi
}

timeout() { fixture_argv timeout "$@"; shift; "$@"; }
terraform() { fixture_argv terraform "$@"; python3 "$FIXTURE_NATIVE/fake-tf.py" "$@"; }
curl() {
  fixture_argv curl "$@"
  if [[ "$*" == *'-K -'* ]]; then
    local auth
    auth=$(cat) || return
    [[ "$auth" == *"$VMWS_PASSWORD"* ]] || return 99
    [[ "${AUTH_FAIL:-0}" != 1 ]] || return 7
    printf 200
  elif [[ "${PROBE_DOWN:-0}" == 1 && ! -f "$FIXTURE_NATIVE/started" ]]; then printf 000
  else printf 401; fi
}
wslpath() { fixture_argv wslpath "$@"; printf '%s\n' "$2"; }
ip() { fixture_argv ip "$@"; return 1; }
ansible-playbook() { fixture_argv ansible-playbook "$@"; echo 'Ansible fixture diagnostic' >&2; return "${ANSIBLE_RC:-0}"; }
rm() {
  fixture_argv rm "$@"
  "$FIXTURE_PYTHON" "$FIXTURE_NATIVE/audit.py" files || return
  command rm "$@"
}
''')

    def assert_confidential(self, run):
        secret=self.env['VMWS_PASSWORD']
        self.assertEqual(secret,envelope_tests.CANARY)
        self.assertNotIn(secret,run.stdout+run.stderr)
        invocations=[json.loads(line) for line in (self.root/'argv.jsonl').read_text().splitlines()]
        self.assertTrue(invocations)
        for args in invocations:
            self.assertTrue(all(secret not in arg for arg in args), args)
        for path in self.root.rglob('*'):
            if path.is_file() and not path.is_symlink() and self.root/'private' not in path.parents:
                self.assertNotIn(secret.encode(),path.read_bytes(),str(path))
        self.assertNotIn('AssertionError',run.stderr)

    def test_production_status_readonly_once(self):
        shutil.rmtree(self.root/'private')
        run, value = self.run_lab('status')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(value['data']['sections'], dict(preflight=0, vms=0))
        self.assertEqual(len(value['data']['vms']), 2)
        self.assertEqual(run.stderr.count('[VM] a:'), 1)
        self.assertFalse((self.root/'private').exists())
        self.assertIn(['init', '-input=false'], self.calls())
        self.assertFalse(value['changed'])

    def test_fresh_checkout_initializes_dry_runs_and_status_without_change(self):
        self.env['REQUIRE_TF_INIT']='1'
        commands=[('up','--dry-run'), ('down','--all','--dry-run'),
                  ('destroy','--dry-run'), ('status',)]
        for args, existing_state in [(args, present) for args in commands for present in (False, True)]:
            with self.subTest(args=args, existing_state=existing_state):
                self.reset(live=('a','b') if existing_state else (), desired=('a','b','new'))
                terraform_dir=self.root/'terraform'
                shutil.rmtree(terraform_dir/'.terraform', ignore_errors=True)
                self.assertFalse((terraform_dir/'.terraform').exists())
                state=terraform_dir/'terraform.tfstate'
                if existing_state:
                    state.write_text('{"fixture":"existing-state"}\n')
                else:
                    state.unlink(missing_ok=True)
                original_state=state.read_bytes() if existing_state else None
                original=(self.root/'fake.json').read_bytes()
                run,value=self.run_lab(*args)
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertFalse(value['changed'])
                self.assertEqual(value['dry_run'], '--dry-run' in args)
                calls=self.calls()
                self.assertEqual(calls[0], ['init','-input=false'])
                self.assertTrue(any(c[0]=='show' for c in calls))
                if args[0]=='up' or (existing_state and args[0]!='status'):
                    self.assertTrue(any(c[0]=='plan' for c in calls))
                self.assertFalse(any(c[0] in ('apply','destroy','state') for c in calls))
                self.assertEqual((self.root/'fake.json').read_bytes(),original)
                if existing_state:
                    self.assertEqual(state.read_bytes(),original_state)
                else:
                    self.assertFalse(state.exists())
                for name in ('cleanup-pending.json','bootstrap-records.backup.json'):
                    self.assertFalse((terraform_dir/name).exists())
                self.assertFalse((self.root/'events').exists())

    def test_production_credentials_probe_and_multi_section_error(self):
        del self.env['VMWS_USERNAME']
        # Keep the secret canary for the external fake's audit, but no username.
        self.env['PROBE_DOWN']='1'
        run, value = self.run_lab('status')
        self.assertEqual(run.returncode, 4, run.stderr)
        self.assertEqual(value['error']['code'], 'vmrest_unreachable')
        self.assertEqual(value['data']['sections'], dict(preflight=4, vms=3))
        self.assertIn('== Tools', run.stderr)
        self.assertIn('== vmrest API', run.stderr)

    def test_production_network_report(self):
        run, value = self.run_lab('network')
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(value['data']['windows'], dict(adapters=[]))
        self.assertEqual(value['data']['roles']['management'], 'VMnet1')
        self.assertFalse(value['changed'])

    def test_sensitive_terraform_failure_paths(self):
        variables=(ROOT/'terraform/variables.tf').read_text()
        self.assertRegex(variables,r'variable "vmrest_password"\s*\{[^}]*sensitive\s*=\s*true')
        for setting,args,diagnostic in [
                ('PLAN_FAIL',('up','--dry-run'),'Invalid fake configuration'),
                ('APPLY_FAIL',('up','new'),'Apply fixture diagnostic'),
                ('DESTROY_RC',('destroy','--confirm=a,b'),'Terraform destroy fixture diagnostic')]:
            with self.subTest(setting=setting):
                self.reset()
                self.env[setting]='1'
                run,value=self.run_lab(*args)
                self.assertEqual(run.returncode,1,run.stderr)
                self.assertIn(diagnostic,run.stderr)
                self.assertEqual(run.stderr.count('[VM] a:'),1)
                self.assertFalse(list((self.root/'private').glob('plan.*')))
                self.assert_confidential(run)
                del self.env[setting]

    def test_successful_dry_run_saved_plan_is_private_and_removed(self):
        # Audit immediately after the fake saves the canary-bearing plan,
        # before lifecycle cleanup can hide a misplaced temporary file.
        with (self.root/'fake-tf.py').open('a') as out:
            out.write('''
if args[0] == 'plan':
    import runpy
    for arg in args:
        if arg.startswith('-out='):
            sys.argv = [str(root/'audit.py'), 'saved-plan', arg[5:]]
            runpy.run_path(sys.argv[0], run_name='__main__')
    sys.argv = [str(root/'audit.py'), 'files']
    runpy.run_path(sys.argv[0], run_name='__main__')
''')
        for missing_private in (False, True):
            with self.subTest(missing_private=missing_private):
                if missing_private:
                    shutil.rmtree(self.root/'private')
                else:
                    (self.root/'private').chmod(0o700)
                audit=self.root/'plan-audit.jsonl'
                audit.write_text('')
                run,value=self.run_lab('up','--dry-run')
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertTrue(value['dry_run'])
                self.assertFalse(value['changed'])
                paths=[json.loads(line) for line in audit.read_text().splitlines()]
                self.assertTrue(paths, 'successful saved-plan audit did not run')
                for path in paths:
                    self.assertFalse(os.path.exists(path),path)
                self.assertEqual((self.root/'private').stat().st_mode & 0o777,0o700)
                self.assertFalse(list((self.root/'private').glob('plan.*')))
                self.assertFalse(any(c[0] in ('apply','destroy') for c in self.calls()))
                self.assert_confidential(run)

    def test_start_vmrest_attempt_marks_change(self):
        self.env['PROBE_DOWN']='1'
        run, value = self.run_lab('status', '--start-vmrest')
        self.assertTrue(value['changed'], run.stderr)
        self.assertTrue((self.root/'started').exists())

    def test_authenticated_connection_failure_after_startup(self):
        self.env.update(PROBE_DOWN='1', AUTH_FAIL='1')
        run,value=self.run_lab('status','--start-vmrest')
        self.assertTrue((self.root/'started').exists())
        self.assertTrue(value['changed'])
        self.assertEqual(run.returncode,1,run.stderr)
        self.assertEqual(value['error']['code'],'runtime_error')

    def test_refused_precheck_skips_per_vm_requests(self):
        self.env['AUTH_FAIL']='1'
        run,value=self.run_lab('up','--dry-run')
        self.assertEqual(run.returncode,4,run.stderr)
        self.assertEqual(value['error']['code'],'vmrest_unreachable')
        self.assertNotIn('[VM]',run.stderr)
        calls=[json.loads(line) for line in (self.root/'argv.jsonl').read_text().splitlines()]
        self.assertFalse(any(arg.endswith('/power') for args in calls for arg in args))

    def test_setup_missing_key_requires_credentials_before_creation(self):
        shutil.copyfile(ROOT/'lib/base.sh',self.root/'lib/base.sh')
        # The base is already prepared; fake only keygen and registration.
        (self.root/'lib/register-vm.py').write_text('pass\n',newline='\n')
        with (self.root/'bash-env').open('a') as out:
            out.write('''
ssh-keygen() {
  fixture_argv ssh-keygen "$@"
  printf fixture-key > "${@: -1}"
  printf fixture-public-key > "${@: -1}.pub"
}
''')
        shutil.rmtree(self.root/'private')
        username=self.env.pop('VMWS_USERNAME')
        run,value=self.run_lab('setup')
        self.assertEqual(run.returncode,3,run.stderr)
        self.assertEqual(value['error']['code'],'secrets_missing')
        self.assertFalse(value['changed'])
        self.assertFalse((self.root/'private').exists())
        self.env['VMWS_USERNAME']=username
        run,value=self.run_lab('setup')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertTrue(value['changed'])
        self.assertTrue((self.root/'private/lab_ed25519').is_file())
        # Key creation alone must mark a change too, with the dir present.
        (self.root/'private/lab_ed25519').unlink()
        run,value=self.run_lab('setup')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertTrue(value['changed'])
        self.assertTrue((self.root/'private/lab_ed25519').is_file())
        run,value=self.run_lab('setup')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertFalse(value['changed'])
        # Permission-only corrections count, independently for each path.
        private=self.root/'private'
        key=private/'lab_ed25519'
        for dir_mode,key_mode in ((0o755,0o600),(0o700,0o644),(0o755,0o644)):
            with self.subTest(dir_mode=dir_mode,key_mode=key_mode):
                private.chmod(dir_mode)
                key.chmod(key_mode)
                run,value=self.run_lab('setup')
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertTrue(value['changed'])
                self.assertEqual(private.stat().st_mode & 0o777,0o700)
                self.assertEqual(key.stat().st_mode & 0o777,0o600)

    def test_symlinked_vm_folder_refused(self):
        target=self.root/'untracked-vm'
        target.mkdir()
        (target/'disk.vmdk').write_text('existing disk')
        (self.root/'clones').mkdir()
        (self.root/'clones/new').symlink_to(target,target_is_directory=True)
        run,value=self.run_lab('up','new','--dry-run')
        self.assertEqual(run.returncode,2,run.stderr)
        self.assertEqual(value['error']['code'],'config_error')
        self.assertIn('Symlinked VM folder',run.stderr)
        self.assertFalse(value['changed'])
        self.assertFalse(any(c[0] in ('apply','destroy') for c in self.calls()))

    def test_config_errors_before_mutation(self):
        self.env['LAB_VM_ROOT_WIN']=''
        self.env['LAB_WINDOWS_PROFILE']=''
        run,value=self.run_lab('status')
        self.assertEqual(run.returncode,2,run.stderr)
        self.assertEqual(value['error']['code'],'config_error')
        self.assertFalse(value['changed'])
        shutil.copyfile(ROOT/'lib/base.sh',self.root/'lib/base.sh')
        (self.root/'lib/network.sh').write_text('bash "$FIXTURE_NATIVE/lib/base.sh"\n',newline='\n')
        self.env['LAB_IMAGE']='unknown-fixture'
        shutil.rmtree(self.root/'private')
        run,value=self.run_lab('network')
        self.assertEqual(run.returncode,2,run.stderr)
        self.assertEqual(value['error']['code'],'config_error')
        self.assertFalse(value['changed'])
        self.assertIn('Unknown image: unknown-fixture',run.stderr)
        self.assertFalse((self.root/'private').exists())

    def test_production_configure_ansible_failure_canary(self):
        # Synthetic DHCP, key and VMX fixtures, all under system temp.
        private=self.root/'private'
        (private/'lab_ed25519').write_text('fake-key')
        (private/'known_hosts-a').write_text('wsl-vmware-lab-a fake-public-key')
        (self.root/'a.vmx').write_text('ethernet1.generatedAddress = "00:11:22:33:44:55"\n')
        leases=self.root/'leases'
        leases.write_text('lease 192.0.2.10 {\n starts 0 2020/01/01 00:00:00;\n ends never;\n hardware ethernet 00:11:22:33:44:55;\n binding state active;\n}\n')
        conf=self.root/'dhcp.conf'
        conf.write_text('# Virtual ethernet segment 1\nsubnet 192.0.2.0 netmask 255.255.255.0 {\n host VMnet1 { }\n}\n')
        self.env.update(LAB_DHCP_LEASES=str(leases), LAB_DHCP_CONF=str(conf), ANSIBLE_RC='7')
        run,value=self.run_lab('configure')
        self.assertEqual(run.returncode,1,run.stderr)
        self.assertIn('ansible_exit_status',value['data'],run.stderr)
        self.assertEqual(value['data']['ansible_exit_status'],7,run.stderr)
        self.assertIn('Ansible fixture diagnostic',run.stderr)
        self.assert_confidential(run)


class RecorderTests(envelope_tests.EnvelopeFixture, unittest.TestCase):
    def test_term_during_finalization_keeps_one_envelope_and_status(self):
        # After a TERM exit, TERM the group again while its writer is blocked.
        writer=self.root/'lib/envelope.py'
        source=writer.read_text()
        writer.write_text(source.replace(
            'def finish(path, command, dry_run, status):',
            '''def finish(path, command, dry_run, status):
    import time
    from pathlib import Path
    root = Path(os.environ['FIXTURE_NATIVE'])
    (root/'writer-ready').touch()
    while not (root/'writer-release').exists(): time.sleep(.02)
'''),newline='\n')
        (self.root/'lib/network.sh').write_text('kill -s TERM "$PPID"\n',newline='\n')
        proc=subprocess.Popen(['bash',str(self.root/'lab'),'network'],env=self.env,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                              start_new_session=True)
        try:
            deadline=time.monotonic()+10
            while not (self.root/'writer-ready').exists() and time.monotonic()<deadline: time.sleep(.02)
            self.assertTrue((self.root/'writer-ready').exists())
            os.killpg(proc.pid,signal.SIGTERM)
            (self.root/'writer-release').touch()
            out,err=proc.communicate(timeout=10)
            value=self.check_envelope(subprocess.CompletedProcess([],proc.returncode,out,err))
            self.assertEqual(proc.returncode,143,err)
            self.assertEqual(value['error']['details']['exit_status'],143)
        finally:
            (self.root/'writer-release').touch()
            if proc.poll() is None: proc.kill(); proc.wait()

    def test_truncated_missing_and_mktemp_failure(self):
        for body in ('printf \'{"data":\' >> "$LAB_RESULT_FILE"',
                     'rm -f "$LAB_RESULT_FILE"'):
            (self.root/'lib/network.sh').write_text(body+'\n',newline='\n')
            run,value=self.run_lab('network')
            self.assertEqual(run.returncode,1,run.stderr)
            self.assertEqual(value['error']['code'],'runtime_error')
        with (self.root/'bash-env').open('a') as out:
            out.write('\nmktemp() { return 9; }\n')
        run,value=self.run_lab('network')
        self.assertEqual(run.returncode,1,run.stderr)

    def test_fd3_isolation_and_lock_held(self):
        (self.root/'lib/network.sh').write_text('echo illicit >&3\necho useful-log >&2\n',newline='\n')
        run,value=self.run_lab('network')
        self.assertNotIn('illicit',run.stdout)
        self.assertIn('useful-log',run.stderr)
        import fcntl
        with (self.root/'.lab.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
            run,value=self.run_lab('up')
        self.assertEqual(run.returncode,4,run.stderr)
        self.assertEqual(value['error']['code'],'lock_held')

    def test_top_level_signals_outside_run_locked(self):
        for sig,expected in [('INT',130),('TERM',143)]:
            (self.root/'lib/network.sh').write_text('kill -s '+sig+' "$PPID"\n',newline='\n')
            run,value=self.run_lab('network')
            self.assertEqual(run.returncode,expected,run.stderr)
            self.assertEqual(value['error']['details']['exit_status'],expected)

    def test_first_error_precedence_over_uncaught_section(self):
        (self.root/'lib/preflight.sh').write_text('source "$(dirname "$0")/config.sh"\nlab_fail vmrest_unreachable fixture\n',newline='\n')
        (self.root/'lib/lifecycle.sh').write_text('exit 17\n',newline='\n')
        run,value=self.run_lab('status')
        self.assertEqual(run.returncode,4,run.stderr)
        self.assertEqual(value['data']['sections'],dict(preflight=4,vms=17))

    def test_confirmation_tokens_and_empty_state(self):
        for token in ('','a,a,b','a,b,','a,\nb','a,,b','A,b'):
            self.env['CONFIRM_TOKEN']=token
            run=subprocess.run(['bash','-c','bash "$FIXTURE_NATIVE/lab" destroy "--confirm=$CONFIRM_TOKEN"'],env=self.env,capture_output=True,text=True,encoding='utf-8',timeout=30)
            value=self.check_envelope(run)
            self.assertEqual(run.returncode,5,run.stderr)
            self.assertEqual(value['error']['hint'],'Use --confirm=a,b')
            self.assertFalse(any(c[0]=='destroy' for c in self.calls()))
        self.reset(live=(),desired=())
        run,value=self.run_lab('destroy')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertFalse(value['changed'])
        self.assertFalse(any(c[0]=='destroy' for c in self.calls()))
        for token in ('a','','A'):
            with self.subTest(empty_state_token=token):
                run,value=self.run_lab('destroy',f'--confirm={token}')
                self.assertEqual(run.returncode,5,run.stderr)
                self.assertEqual(value['error']['hint'],'./lab status')
                self.assertFalse(value['changed'])
                self.assertFalse(any(c[0]=='destroy' for c in self.calls()))

    def test_refused_real_run_remains_planned(self):
        self.reset(desired=('a',))
        run,value=self.run_lab('up')
        self.assertEqual(run.returncode,5,run.stderr)
        self.assertFalse(value['changed'])
        self.assertTrue(all(a['result']=='planned' for a in value['data']['actions']))

    def test_recovery_attempt_boundaries(self):
        backup=self.root/'terraform/bootstrap-records.backup.json'
        backup.write_text('synthetic-backup')
        self.env['PLAN_FAIL']='1'
        run,value=self.run_lab('up')
        self.assertEqual(run.returncode,1,run.stderr)
        self.assertTrue(value['changed'])
        backup.unlink()
        del self.env['PLAN_FAIL']
        (self.root/'terraform/cleanup-pending.json').write_text('synthetic-journal')
        (self.root/'lib/cleanup-guest.py').write_text('raise SystemExit(1)\n')
        run,value=self.run_lab('up')
        self.assertEqual(run.returncode,1,run.stderr)
        self.assertTrue(value['changed'])

    def test_guest_shutdown_attempt_with_noop_plan(self):
        self.reset(desired=('a','b'))
        state=json.loads((self.root/'fake.json').read_text())
        state['powers']=dict(a='off',b='off')
        (self.root/'fake.json').write_text(json.dumps(state))
        self.env['WAIT_FAIL']='1'
        run,value=self.run_lab('down','--all')
        self.assertEqual(run.returncode,1,run.stderr)
        self.assertTrue(value['changed'])
        self.assertIn('ansible-poweroff',(self.root/'events').read_text())

    def test_live_seeds_override_stale_state_actions(self):
        self.reset(desired=('a','b'))
        state=json.loads((self.root/'fake.json').read_text())
        state['powers']=dict(a='on',b='off')
        (self.root/'fake.json').write_text(json.dumps(state))
        self.env['POWER_OFF']='["a"]'
        run,value=self.run_lab('up','a','--dry-run')
        self.assertEqual(value['data']['actions'],[dict(vm='a',action='power_on',result='planned')])
        run,value=self.run_lab('down','b','--dry-run')
        self.assertEqual(value['data']['actions'],[dict(vm='b',action='power_off',result='planned')])
        self.reset(live=('a',),desired=('a',))
        state=json.loads((self.root/'fake.json').read_text())
        state.update(powers=dict(a='on'),cpus=dict(a=4))
        (self.root/'fake.json').write_text(json.dumps(state))
        run,value=self.run_lab('up','a','--dry-run')
        self.assertEqual([a['action'] for a in value['data']['actions']],['update','power_on'])

    def test_canary_diagnostics_and_power_report_once(self):
        for env,args in [('PLAN_FAIL',('up','--dry-run')),
                         ('APPLY_FAIL',('up','new')),
                         ('DESTROY_RC',('destroy','--confirm=a,b'))]:
            self.reset()
            self.env[env]='1'
            run,value=self.run_lab(*args)
            self.assertEqual(run.returncode,1,run.stderr)
            self.assertEqual(run.stderr.count('[VM] a:'),1)
            del self.env[env]

    def test_term_lifecycle_waits_for_trapped_child_cleanup(self):
        fake=self.root/'fake-tf.py'
        code=fake.read_text().replace("elif args[0]=='apply':", """elif args[0]=='apply':
    import signal, time
    def stop(sig, frame):
        time.sleep(.3)
        (root/'child-cleaned').touch()
        sys.exit(143)
    signal.signal(signal.SIGTERM, stop)
    (root/'ready').touch()
    while True: time.sleep(.05)
""")
        fake.write_text(code)
        proc=subprocess.Popen(['bash',str(self.root/'lab'),'up','new'],env=self.env,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+10
            while not (self.root/'ready').exists() and time.monotonic()<deadline: time.sleep(.02)
            self.assertTrue((self.root/'ready').exists())
            proc.send_signal(signal.SIGTERM)
            out,err=proc.communicate(timeout=10)
            value=self.check_envelope(subprocess.CompletedProcess([],proc.returncode,out,err))
            self.assertEqual(proc.returncode,143)
            self.assertTrue((self.root/'child-cleaned').exists())
            self.assertFalse(list((self.root/'private').glob('plan.*')))
            self.assertTrue(all(a['result']=='failed' for a in value['data']['actions']))
            self.assertEqual(len(value['data']['vms']),2)
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()

