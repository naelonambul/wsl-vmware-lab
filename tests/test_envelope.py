# PR 3 tests run exclusively in disposable system-temp checkouts.
import json
import re
import shutil
import signal
import subprocess
import time
import unittest
import test_power as fixtures

ROOT = fixtures.ROOT
CANARY = 'canary-password-do-not-print'


class EnvelopeFixture:
    def setUp(self):
        fixtures.LifecycleTests.setUp(self)
        self.env['VMWS_PASSWORD'] = CANARY
        # Redirect the one absolute filesystem dependency in the disposable
        # entry point. Never consult the runner's installed Ubuntu keyring.
        self.keyring = self.root/'ubuntu-cloudimage-keyring.gpg'
        self.keyring.write_text('fixture-keyring')
        entry = (self.root/'lab').read_text(encoding='utf-8')
        keyring_path = '/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg'
        self.assertEqual(entry.count(keyring_path), 1)
        (self.root/'lab').write_text(entry.replace(
            keyring_path,
            '"$FIXTURE_NATIVE/ubuntu-cloudimage-keyring.gpg"'), newline='\n')
        # LifecycleTests supplies a closed PATH of absolute utility symlinks.
        # Optional lab tools cannot fall through to installed host tools.
        self.setup_tools = ('terraform', 'ansible-playbook', 'qemu-img', 'cloud-localds', 'gpgv')
        for tool in self.setup_tools:
            path = self.bin/tool
            path.write_text('#!/bin/bash\necho "Unexpected fixture tool execution: $0" >&2\nexit 99\n', newline='\n')
            path.chmod(0o700)
        for name in ('network','preflight','account','base','configure'):
            (self.root/f'lib/{name}.sh').write_text(
                '#!/usr/bin/env bash\nsource "$(dirname "$0")/config.sh"\necho fixture-log\n', newline='\n')
        with (self.root/'lib/base.sh').open('a') as stream:
            stream.write('echo base >> "$FIXTURE_NATIVE/setup-calls"\n')
        init = r'''
set -o pipefail
sudo() { printf 'sudo %s\n' "$*" >> "$FIXTURE_NATIVE/setup-calls"; return 1; }
python3() { "$FIXTURE_PYTHON" "$@"; }
'''
        (self.root/'bash-env').write_text(init,newline='\n')
        self.env['BASH_ENV']=(self.root/'bash-env').as_posix()
        self.reset()

    def reset(self,live=('a','b'),desired=('a','b','new'),replace=()):
        (self.root/'fake.json').write_text(json.dumps(dict(live=list(live),desired=list(desired),replace=list(replace))))
        (self.root/'calls').write_text('')
        for name in set(live)|set(desired): (self.root/(name+'.vmx')).write_text('')

    def run_lab(self,*args):
        run=subprocess.run(['bash',(self.root/'lab').as_posix(),*args],env=self.env,capture_output=True,text=True,encoding="utf-8",timeout=30)
        return run,self.check_envelope(run)

    def check_envelope(self,run):
        self.assertNotIn('command not found',run.stderr)
        self.assertNotIn('Unexpected fixture tool execution:',run.stderr)
        self.assertNotIn(CANARY,run.stdout+run.stderr)
        self.assertEqual(len(run.stdout.splitlines()),1,run.stdout+run.stderr)
        value=json.loads(run.stdout)
        self.assertEqual(set(value),{'ok','command','dry_run','changed','data','warnings','error'})
        self.assertEqual(value['ok'],value['error'] is None)
        self.assertEqual(value['ok'],run.returncode==0)
        if value['error'] and run.returncode not in (130,143):
            table=json.loads((ROOT/'lib/describe.json').read_text())['errors']
            self.assertEqual(run.returncode,table[value['error']['code']]['exit'])
        return value

    def calls(self):
        return [json.loads(l)['args'] for l in (self.root/'calls').read_text().splitlines()]


class EnvelopeTests(EnvelopeFixture, unittest.TestCase):
    def test_dispatch_and_stdout_is_only_envelope(self):
        for args in [('network',),('account',),('setup',),('status',),('configure',),('cleanup',),
                     ('up','--dry-run'),('down','--all','--dry-run'),('destroy','--dry-run'),('describe','--json')]:
            with self.subTest(args=args):
                self.reset()
                run,value=self.run_lab(*args)
                self.assertEqual(value['command'],args[0])
                self.assertEqual(run.returncode,0,run.stderr)

    def test_setup_tool_and_keyring_prerequisites(self):
        calls = self.root/'setup-calls'
        # Each missing prerequisite must block independently, even if every
        # tool and the real keyring happen to be installed on the runner.
        for missing in (*self.setup_tools, 'keyring', None):
            with self.subTest(missing=missing):
                calls.write_text('')
                path = self.keyring if missing == 'keyring' else self.bin/missing if missing else None
                if path: path.rename(path.with_suffix('.hidden'))
                try:
                    run, value = self.run_lab('setup')
                    self.assertEqual(run.returncode, 3 if missing else 0, run.stderr)
                    self.assertFalse(value['changed'])
                    if missing:
                        self.assertEqual(value['error']['code'], 'needs_user')
                        self.assertEqual(calls.read_text().splitlines(), ['sudo -n true'])
                        self.assertIn('missing: '+('ubuntu-cloudimage-keyring' if missing == 'keyring' else missing), run.stderr)
                    else:
                        self.assertIsNone(value['error'])
                        self.assertEqual(calls.read_text().splitlines(), ['base'])
                finally:
                    if path: path.with_suffix('.hidden').rename(path)

    def test_every_error_code_and_forced_crash(self):
        table=json.loads((ROOT/'lib/describe.json').read_text())['errors']
        for code,spec in table.items():
            with self.subTest(code=code):
                (self.root/'lib/network.sh').write_text(
                    'source "$(dirname "$0")/config.sh"\nlab_fail '+code+' "fixture failure" "fixture hint" \'{"fixture":true}\'\n',newline='\n')
                run,value=self.run_lab('network')
                self.assertEqual(run.returncode,spec['exit'])
                self.assertEqual(value['error']['code'],code)
                self.assertEqual(value['error']['details'],{'fixture':True})
        (self.root/'lib/network.sh').write_text('echo crash-log\nexit 17\n',newline='\n')
        run,value=self.run_lab('network')
        self.assertEqual(run.returncode,1)
        self.assertEqual(value['error']['code'],'runtime_error')
        self.assertEqual(value['error']['details'],dict(exit_status=17))

    def test_dry_runs_have_no_mutation_and_report_pending_and_power(self):
        for args in [('up','--all'),('up','b','new'),('down','--all'),('destroy',)]:
            with self.subTest(args=args):
                self.reset(replace=('a',) if args[0]=='up' else ())
                self.env['POWER_OFF']='["b"]'
                journal=self.root/'terraform/cleanup-pending.json'
                backup=self.root/'terraform/bootstrap-records.backup.json'
                journal.write_text('pending canary journal'); backup.write_text('pending canary backup')
                stale=self.root/'private/plan.stale'; stale.write_text('private canary plan')
                options=('--allow-destroy',) if args[0]=='up' else ()
                run,value=self.run_lab(*args,*options,'--dry-run')
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertFalse(value['changed']); self.assertTrue(value['dry_run'])
                self.assertEqual(value['data']['pending'],['cleanup','bootstrap_record_restoration'])
                self.assertTrue(all(c[0] not in ('apply','destroy','init') and c[:2]!=['state','push'] for c in self.calls()))
                self.assertFalse((self.root/'events').exists())
                self.assertEqual(journal.read_text(),'pending canary journal')
                self.assertEqual(backup.read_text(),'pending canary backup')
                self.assertEqual(stale.read_text(),'private canary plan')
                actions=value['data']['actions']
                self.assertTrue(all(a['result']=='planned' for a in actions))
                if args[0]=='up':
                    expected={'a','b','new'} if '--all' in args else {'b','new'}
                    self.assertEqual({a['vm'] for a in actions if a['action']=='power_on'},expected)
                self.assertEqual({v['name'] for v in value['data']['vms']},{'a','b'})

    def test_dry_run_never_powers_on_a_deleted_vm(self):
        self.reset(desired=('a',))
        self.env['POWER_OFF']='["b"]'
        run,value=self.run_lab('up','--all','--allow-destroy','--dry-run')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertEqual(value['data']['actions'],[dict(vm='b',action='delete',result='planned')])
        self.assertFalse((self.root/'events').exists())

    def test_dry_run_preserves_gates(self):
        self.reset(live=('a','b'),desired=('a',))
        run,value=self.run_lab('up','--dry-run')
        self.assertEqual(run.returncode,5,run.stderr)
        self.assertEqual(value['error']['code'],'plan_destroy_refused')
        self.assertFalse((self.root/'events').exists())

    def test_destroy_exact_set_and_no_passthrough(self):
        for args,code in [((),5),(('--confirm=a',),5),(('-auto-approve',),2),(('--confirm=a,b','-target=x'),2)]:
            self.reset()
            run,value=self.run_lab('destroy',*args)
            self.assertEqual(run.returncode,code,run.stderr)
            if code==5: self.assertEqual(value['error']['details']['expected'],'a,b')
            self.assertFalse(any(c[0]=='destroy' for c in self.calls()))
        self.env['DESTROY_RC']='0'
        run,value=self.run_lab('destroy','--confirm=b,a')
        self.assertEqual(run.returncode,0,run.stderr)
        destroy=[c for c in self.calls() if c[0]=='destroy'][0]
        self.assertIn('-input=false',destroy); self.assertIn('-auto-approve',destroy)

    def test_precheck_codes_plan_failure_and_apply_failure(self):
        config=self.root/'lib/config.sh'
        original=config.read_text(encoding='utf-8')
        for code,expected,exit_status in [('401','vmrest_auth',3),('403','vmrest_auth',3),('000','vmrest_unreachable',4)]:
            source=original.replace('curl() { printf 200; }',
                'curl() { printf '+code+'; '+('return 7;' if code=='000' else '')+' }')
            config.write_text(source,encoding='utf-8',newline='\n')
            run,value=self.run_lab('up','--dry-run')
            self.assertEqual(run.returncode,exit_status,run.stderr)
            self.assertEqual(value['error']['code'],expected)
            self.assertFalse((self.root/'events').exists())
        config.write_text(original,encoding='utf-8',newline='\n')
        self.env['PLAN_FAIL']='1'
        run,value=self.run_lab('up','--dry-run')
        self.assertEqual(value['error']['code'],'runtime_error')
        self.assertFalse(value['changed'])
        del self.env['PLAN_FAIL']
        self.env['APPLY_FAIL']='1'
        run,value=self.run_lab('up','new')
        self.assertEqual(value['error']['code'],'runtime_error')
        self.assertTrue(value['changed'])
        self.assertTrue(all(a['result']=='failed' for a in value['data']['actions']))

    def test_result_merge_and_configure_metadata(self):
        (self.root/'lib/network.sh').write_text(
            'source "$(dirname "$0")/config.sh"\nlab_result \'{"first":1}\'\nlab_result \'{"second":2}\'\n',newline='\n')
        run,value=self.run_lab('network')
        self.assertEqual(value['data'],dict(first=1,second=2))
        shutil.copyfile(ROOT/'lib/configure.sh',self.root/'lib/configure.sh')
        with (self.root/'lib/config.sh').open('a', encoding='utf-8', newline='\n') as stream:
            stream.write('\nlab_require_credentials() { :; }\n')
        (self.root/'playbook.yml').write_text('---\n')
        self.env.update(LAB_PRIVATE_DIR=(self.root/'private').as_posix(),
                        LAB_PLAYBOOK=(self.root/'playbook.yml').as_posix(),
                        LAB_INVENTORY=(self.root/'private/inventory.json').as_posix())
        with (self.root/'bash-env').open('a') as stream:
            stream.write('\ntimeout() { shift; "$@"; }\nansible-playbook() { return "${ANSIBLE_RC:-0}"; }\n')
        (self.root/'lib/guest-inventory.py').write_text(
            'import envelope\nenvelope.record("data",dict(selected=["a"],omitted=["b"]))\n'
            'envelope.record("warnings",[dict(code="powered_off",message="Powered off; omitted.",vm="b")])\n',newline='\n')
        for code in ('0','7'):
            self.env['ANSIBLE_RC']=code
            run,value=self.run_lab('configure','--limit','a')
            self.assertEqual(run.returncode,0 if code=='0' else 1,run.stderr)
            self.assertEqual(value['data'],dict(selected=['a'],omitted=['b'],ansible_exit_status=int(code)))
            self.assertEqual(value['warnings'][0]['vm'],'b')

    def test_status_plan_hint_and_describe_coverage(self):
        run,value=self.run_lab('configure','--dry-run')
        self.assertEqual(run.returncode,2)
        self.assertFalse(value['dry_run'])
        run,value=self.run_lab('status','--plan')
        self.assertEqual(run.returncode,2)
        self.assertEqual(value['error']['code'],'usage_error')
        self.assertIn('--dry-run',value['error']['hint'])
        run,value=self.run_lab('describe','--json')
        codes=set(value['data']['errors']); self.assertEqual(len(codes),14)
        for path in [ROOT/'lab',*ROOT.glob('lib/*.sh')]:
            for code in re.findall(r'\blab_fail\s+([a-z_]+)',path.read_text(encoding='utf-8')):
                self.assertIn(code,codes,path.name)

    def test_mutation_success_and_noop(self):
        for args in [('up','new'),('down','--all')]:
            self.reset()
            run,value=self.run_lab(*args)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertTrue(value['changed'])
            self.assertTrue(all(a['result']=='done' for a in value['data']['actions']))
        self.reset(desired=('a','b'))
        run,value=self.run_lab('up','a')
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertFalse(value['changed']); self.assertEqual(value['data']['actions'],[])

    def test_interrupt_envelope_once_with_original_status(self):
        for sig,expected in [(signal.SIGINT,130),(signal.SIGTERM,143)]:
            (self.root/'lib/configure.sh').write_text('echo ready > "$FIXTURE_NATIVE/ready"\nwhile :; do sleep 1; done\n',newline='\n')
            ready=self.root/'ready'; ready.unlink(missing_ok=True)
            process=subprocess.Popen(['bash',(self.root/'lab').as_posix(),'configure'],env=self.env,
                                     stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                deadline=time.monotonic()+10
                while not ready.exists() and time.monotonic()<deadline: time.sleep(.02)
                self.assertTrue(ready.exists()); process.send_signal(sig)
                out,err=process.communicate(timeout=15)
                value=self.check_envelope(subprocess.CompletedProcess([],process.returncode,out,err))
                self.assertEqual(process.returncode,expected)
                self.assertEqual(value['error']['details']['exit_status'],expected)
            finally:
                if process.poll() is None: process.kill(); process.wait()


if __name__=='__main__': unittest.main()
