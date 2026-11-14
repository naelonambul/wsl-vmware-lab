"""PR 2 offline fixtures. External commands are fakes; never runs ./lab."""
import importlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))
power = importlib.import_module('power-map')
inspect = importlib.import_module('plan-inspect')
records = importlib.import_module('bootstrap-records')
inventory = importlib.import_module('guest-inventory')


FAKE_TF = r"""
import json, os, sys
from pathlib import Path
root = Path(os.environ['FIXTURE_NATIVE'])
args = sys.argv[1:]
state = json.loads((root/'fake.json').read_text())
seeds = json.loads(os.environ.get('TF_VAR_power_states', '{}'))
# Model precedence, including an explicit conflicting variable-file value.
for arg in args:
    if arg.startswith('-var-file='):
        seeds = dict.fromkeys(state['desired'], 'on')
    if arg.startswith('-var=power_states='):
        seeds = json.loads(arg.split('=',2)[2])
if args[0] == 'apply' and '-destroy' not in args:
    saved = json.loads(Path(args[-1]).read_text())
    seeds = saved['seeds']
with (root/'calls').open('a') as out:
    out.write(json.dumps(dict(args=args, seeds=seeds))+'\n')
def shown():
    return {'values': {'root_module': {'resources': [dict(mode='managed', type='vmworkstation_virtual_machine',
        index=n, values=dict(id=n, path=str(root/(n+'.vmx')))) for n in state['live']]}},
        'outputs': {'vms': {'value': {}}}}
def plan():
    targets=[a for a in args if a.startswith('-target=')]
    bootstrap=any('guest_bootstrap' in a for a in targets)
    changes=[]
    for n in sorted(set(state['desired']) | set(state['live'])):
        if targets and not bootstrap and not any('["'+n+'"]' in a for a in targets): continue
        before=dict(processors=state.get('cpus',{}).get(n,2), memory=2048,
                    description=state.get('descriptions',{}).get(n,''),
                    state=state.get('powers',{}).get(n,'off' if n in json.loads(os.environ.get('POWER_OFF','[]')) else 'on'))
        after=dict(processors=4 if state.get('resize') else 2,memory=2048,
                   description='edited' if os.environ.get('METADATA') else '',state=seeds.get(n,'off'))
        action=('delete' if n not in state['desired'] else 'replace' if n in state.get('replace',[]) else
                'create' if n not in state['live'] else 'update' if before != after else 'no-op')
        if bootstrap and n == 'b' and os.environ.get('UNEXPECTED_ACTION'): action=os.environ['UNEXPECTED_ACTION']
        changes.append(dict(type='vmworkstation_virtual_machine', name='vm', index=n,
            change=dict(actions=['delete','create'] if action=='replace' else [action],
                before=before if n in state['live'] else None,after=after if action!='delete' else None)))
    return dict(resource_changes=changes,seeds=seeds)
if args[0]=='show':
    print(json.dumps(json.loads(Path(args[-1]).read_text()) if len(args)>2 else shown()))
elif args[0]=='plan':
    saved=plan()
    for arg in args:
        if arg.startswith('-out='): Path(arg[5:]).write_text(json.dumps(saved))
    for r in saved['resource_changes']:
        a=r['change']['actions']; action='replace' if len(a)>1 else a[0]
        print(json.dumps(dict(type='planned_change', change=dict(action=action, resource=dict(
            addr='vmworkstation_virtual_machine.vm["'+r['index']+'"]', resource_type=r['type'],
            resource_name='vm', resource_key=r['index'])))))
elif args[0]=='apply':
    if '-destroy' in args:
        doomed=[n for n in state['live'] if any('["'+n+'"]' in a for a in args if a.startswith('-target='))]
        state['live']=[n for n in state['live'] if n not in doomed]
        state['replace']=[n for n in state['replace'] if n not in doomed]
    else:
        assert not any(a.startswith('-var') for a in args), args
        for r in saved['resource_changes']:
            n=r['index']; c=r['change']
            if c['actions']==['delete']:
                state['live'].remove(n)
            else:
                if n not in state['live']: state['live'].append(n)
                for key,attr in [('powers','state'),('cpus','processors'),('descriptions','description')]:
                    state.setdefault(key,{})[n]=c['after'][attr]
    (root/'fake.json').write_text(json.dumps(state))
elif args[0]=='destroy':
    assert '-auto-approve' not in args, args
    answer = input('Destroy confirmation: ')
    (root/'confirmation').write_text(answer)
    sys.exit(int(os.environ.get('DESTROY_RC', '1')))
"""


class PowerTests(unittest.TestCase):
    def test_live_power_table_and_no_provider_state_guess(self):
        vm = dict(id='fixture', name='fixture')
        env = dict(VMWS_USERNAME='fake', VMWS_PASSWORD='fake', VMWS_ENDPOINT='offline')
        for value, expected in [('poweredOn','on'), ('poweredOff','off'), ('suspended',None), ('paused',None), ('on',None)]:
            with patch.dict(os.environ, env), patch.object(power.subprocess, 'run', return_value=
                    subprocess.CompletedProcess([],0,json.dumps(dict(power_state=value)),'')) as run:
                if expected:
                    self.assertEqual(power.power(vm), expected)
                else:
                    with self.assertRaises(ValueError): power.power(vm)
                self.assertEqual(run.call_args.args[0][-1], 'offline/vms/fixture/power')
        for rc, body in [(22,''), (28,''), (0,'garbled'), (0,'{}')]:
            with patch.dict(os.environ, env), patch.object(power.subprocess,'run', return_value=
                    subprocess.CompletedProcess([],rc,body,'')):
                with self.assertRaises((ValueError,KeyError)): power.power(vm)

    def test_seed_includes_instances_missing_from_outputs(self):
        state = {'values': {'root_module': {'child_modules': [{'resources': [dict(
            mode='managed', type='vmworkstation_virtual_machine', index='hidden',
            values=dict(id='hidden-id', path='fixture.vmx'))]}]}}, 'outputs': {'vms': {'value': {}}}}
        with patch.object(power,'power',return_value='on'):
            self.assertEqual(power.seed(power.vm_instances(state)), {'hidden':'on'})
        with patch.object(power,'power',side_effect=ValueError('unknown')):
            with self.assertRaises(ValueError): power.seed(power.vm_instances(state))

    def test_resize_exact_update_only(self):
        for actions in [['update'], ['delete','create'], ['delete'], ['create']]:
            plan = dict(resource_changes=[dict(type='vmworkstation_virtual_machine', index='a',
                change=dict(actions=actions, before=dict(processors=2,memory=2048),
                            after=dict(processors=4,memory=2048,state='off')))])
            self.assertEqual(inspect.resized(plan,'up',{'a':'on'}), ['a'] if actions==['update'] else [])
            self.assertEqual(inspect.resized(plan,'up',{'a':'off'}), [])
            self.assertEqual(inspect.resized(plan,'down',{'a':'off'}), ['a'] if actions==['update'] else [])

    def test_update_attribute_and_power_matrix(self):
        for before_power,after_power,edit,unknown,blocked in [
                ('on','off',False,False,False), ('off','on',False,False,False),
                ('on','on',True,False,True), ('off','on',True,False,True),
                ('off','off',True,False,False), ('off','off',False,True,False)]:
            change=dict(actions=['update'],before=dict(state=before_power,description='old'),
                        after=dict(state=after_power,description='new' if edit else 'old'),
                        after_unknown=dict(description=unknown))
            plan=dict(resource_changes=[dict(type='vmworkstation_virtual_machine',index='a',change=change)])
            self.assertEqual(bool(inspect.resized(plan,'up',dict(a=before_power))),blocked)

    def test_restore_only_missing_records_for_live_including_doomed(self):
        old = dict(bootstrap=dict(mode='managed',type='terraform_data',name='guest_bootstrap',
                   instances=[dict(index_key=n) for n in ['survivor','doomed','gone']]), doomed=['doomed','gone'])
        state = dict(serial=7,resources=[dict(mode='managed',type='vmworkstation_virtual_machine',
                     instances=[dict(index_key=n) for n in ['survivor','doomed']])])
        self.assertEqual(records.restore(old,state), ['survivor','doomed'])
        self.assertEqual(state['serial'],8)
        self.assertEqual(records.restore(old,state), [])
        self.assertEqual(state['serial'],8)

    def test_wait_requires_api_off_and_timeout(self):
        vms=[dict(name='a',id='a'),dict(name='b',id='b')]
        with patch.object(power,'power',side_effect=['off','on','off']), patch.object(power.time,'sleep'):
            self.assertEqual(power.wait_off(vms,120), [])
        with patch.object(power,'power',side_effect=ValueError('unknown')), \
                patch.object(power.time,'monotonic',side_effect=[0,0,2]):
            self.assertEqual(power.wait_off(vms[:1],1), ['a'])

    def test_rebootstrap_refused_before_writes(self):
        source=(ROOT/'lib/bootstrap-guest.sh').read_text(encoding='utf-8')
        start=source.index("if grep -Eqi")
        guard=source[start:source.index('\nseed_dir=',start)]
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'fixture.vmx'
            path.write_text('ide1:0.fileName = "fixture.iso"\n')
            run=subprocess.run(['bash','-c','vmx="$1"\n'+guard,'fixture',str(path)],capture_output=True,text=True)
            self.assertEqual(run.returncode,1,run.stderr)
            self.assertIn('already bootstrapped',run.stderr)
            self.assertEqual(path.read_text(),'ide1:0.fileName = "fixture.iso"\n')

    def test_backup_survives_failed_push_then_restores(self):
        with tempfile.TemporaryDirectory() as folder:
            backup=Path(folder)/'backup.json'
            old=dict(serial=1,resources=[dict(mode='managed',type='terraform_data',name='guest_bootstrap',
                instances=[dict(index_key='a')])])
            now=dict(serial=2,resources=[dict(mode='managed',type='vmworkstation_virtual_machine',
                instances=[dict(index_key='a')])])
            with patch.object(records.sys,'argv',['records','save',str(backup),'a']), \
                    patch.object(records.subprocess,'check_output',return_value=json.dumps(old)):
                records.main()
            with patch.object(records.sys,'argv',['records','restore',str(backup)]), \
                    patch.dict(os.environ,LAB_PRIVATE_DIR=folder), \
                    patch.object(records.subprocess,'check_output',return_value=json.dumps(now)), \
                    patch.object(records.subprocess,'run',side_effect=subprocess.CalledProcessError(1,'fake')):
                with self.assertRaises(subprocess.CalledProcessError): records.main()
            self.assertTrue(backup.is_file())
            with patch.object(records.sys,'argv',['records','restore',str(backup)]), \
                    patch.dict(os.environ,LAB_PRIVATE_DIR=folder), \
                    patch.object(records.subprocess,'check_output',return_value=json.dumps(now)), \
                    patch.object(records.subprocess,'run', side_effect=lambda args, **kw:
                        self.assertEqual(records.bootstrap(json.loads(Path(args[-1]).read_text()))['instances'],
                                         [dict(index_key='a')])):
                records.main()
            self.assertFalse(backup.exists())

    @unittest.skipUnless(shutil.which('flock') and shutil.which('setsid'), 'requires Linux flock and setsid')
    def test_surviving_child_retains_lock(self):
        # Run only the production shell functions, with a disposable fake child.
        source=(ROOT/'lab').read_text(encoding='utf-8')
        functions=source[source.index('lock() {'):source.index('\ncase "$cmd" in')]
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)
            script=path/'child.sh'
            script.write_text('sleep 30 >/dev/null 2>&1 &\nprintf "%s" "$!" > "$here/child.pid"\n')
            # 30 s is a test-only failsafe; the child is terminated in finally.
            run=subprocess.run(['bash','-c','set -euo pipefail\nhere="$1"; export here\n'+functions+
                '\nrun_locked "$here/child.sh"','fixture',str(path)],capture_output=True,text=True,timeout=5)
            self.assertEqual(run.returncode,0,run.stderr)
            pid=int((path/'child.pid').read_text())
            try:
                second=subprocess.run(['flock','-n',str(path/'.lab.lock'),'true'])
                self.assertNotEqual(second.returncode,0)
            finally:
                os.kill(pid,15)

    def test_detached_runner_preserves_stdin(self):
        source=(ROOT/'lab').read_text(encoding='utf-8')
        functions=source[source.index('lock() {'):source.index('\ncase "$cmd" in')]
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)
            (path/'child.sh').write_text('read -r confirmation\nprintf "%s" "$confirmation"\n')
            # Isolate the stdin boundary on Git Bash too; process groups and
            # real lock inheritance are checked separately under Linux.
            script=functions+'\nlock() { :; }\nenv() { shift 3; "$@"; }\nrun_locked "$1/child.sh"'
            run=subprocess.run(['bash','-c',script,'fixture',str(path)],input='confirm\n',capture_output=True,text=True,timeout=5)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertEqual(run.stdout.rstrip('\r\n'),'confirm')

    @unittest.skipUnless(os.name == 'posix' and shutil.which('setsid') and shutil.which('flock'), 'requires Linux process groups')
    def test_stdin_and_signals_with_lock(self):
        source=(ROOT/'lab').read_text(encoding='utf-8')
        functions=source[source.index('lock() {'):source.index('\ncase "$cmd" in')]
        for sig in [signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as folder:
                path=Path(folder)
                # Child acknowledges the forwarded signal but deliberately waits
                # for release, proving the lock remains held during shutdown.
                (path/'child.py').write_text("import os,signal,time\nfrom pathlib import Path\np=Path(os.environ['here'])\n"
                    "def stop(sig,frame):\n (p/'signal').write_text(str(sig))\n"
                    "signal.signal(signal.SIGINT,stop)\nsignal.signal(signal.SIGTERM,stop)\n"
                    "(p/'input').write_text(input())\n(p/'ready').touch()\n"
                    "while not (p/'release').exists(): time.sleep(.02)\n")
                (path/'child.sh').write_text('exec python3 "$here/child.py"\n')
                proc=subprocess.Popen(['bash','-c','set -euo pipefail\nhere="$1"; export here\n'+functions+
                    '\nrun_locked "$here/child.sh"','fixture',str(path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                def wait_file(name):
                    deadline=time.monotonic()+5
                    while not (path/name).exists() and time.monotonic()<deadline: time.sleep(.02)
                    self.assertTrue((path/name).exists(),name)
                try:
                    proc.stdin.write('confirmation\n'); proc.stdin.flush()
                    wait_file('ready')
                    self.assertEqual((path/'input').read_text(),'confirmation')
                    proc.send_signal(sig)
                    wait_file('signal')
                    self.assertEqual(int((path/'signal').read_text()),sig)
                    self.assertIsNone(proc.poll())
                    self.assertNotEqual(subprocess.run(['flock','-n',str(path/'.lab.lock'),'true']).returncode,0)
                    (path/'release').touch()
                    stdout,stderr=proc.communicate(timeout=5)
                    self.assertEqual(proc.returncode,128+sig,stderr)
                    self.assertIn('Run interrupted; check ./lab status',stderr)
                    self.assertEqual(subprocess.run(['flock','-n',str(path/'.lab.lock'),'true']).returncode,0)
                finally:
                    (path/'release').touch()
                    if proc.poll() is None: proc.terminate()
                    proc.communicate(timeout=5)

    def test_forwarded_signal_overrides_successful_child(self):
        source=(ROOT/'lab').read_text()
        functions=source[source.index('lock() {'):source.index('\ncase "$cmd" in')]
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)
            (path/'child.sh').write_text('builtin kill -s "$FIXTURE_SIGNAL" "$runner_pid"\nsleep .1\nexit 0\n',newline='\n')
            # Only the process-group boundary is faked on Git Bash. Deliver a
            # real signal to the runner and let its child finish successfully.
            shim='''
lock() { :; }
env() { shift 3; "$@"; }
kill() { if [[ "$1" == -0 ]]; then builtin kill "$@"; else :; fi; }
export runner_pid=$$
run_locked "$1/child.sh"
'''
            for sig,code in [('INT',130),('TERM',143)]:
                run=subprocess.run(['bash','-c','set -euo pipefail\n'+functions+shim,'fixture',path.as_posix()],
                    env=dict(os.environ,FIXTURE_SIGNAL=sig),capture_output=True,text=True,timeout=5)
                self.assertEqual(run.returncode,code,run.stderr)
                self.assertEqual(run.stderr.count('Run interrupted; check ./lab status'),1)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        (self.root/'terraform').mkdir()
        (self.root/'private').mkdir()
        (self.root/'lib').mkdir()
        for name in ['network-inspect.py','power-map.py','plan-inspect.py']:
            shutil.copyfile(ROOT/'lib'/name,self.root/'lib'/name)
        # Fake cleanup and backup boundaries record ordering only; restoration
        # semantics are exercised independently above, including failed pushes.
        for name in ['cleanup-guest.py','bootstrap-records.py']:
            (self.root/'lib'/name).write_text("import os,sys\nfrom pathlib import Path\np=Path(os.environ['FIXTURE_NATIVE'])/'events'\nwith p.open('a') as f: f.write(' '.join(sys.argv[1:2])+ '\\n')\n")
        (self.root/'fake-tf.py').write_text(FAKE_TF)
        (self.root/'lib'/'guest-inventory.py').write_text("import os,json\nfrom pathlib import Path\nPath(os.environ['LAB_INVENTORY']).write_text(json.dumps(dict(all=dict(hosts={} if os.environ.get('EMPTY_INVENTORY') else dict(a={})))))\n")
        self.source=(ROOT/'lib/lifecycle.sh').read_text(encoding='utf-8')
        config=(ROOT/'lib/config.sh').read_text(encoding='utf-8')
        fail=config[config.index('lab_fail() {'):config.index('\nLAB_ENV_FILE=')]
        mocks=r'''
python3() { "$FIXTURE_PYTHON" "$@" | tr -d '\r'; }
cd "$FIXTURE_NATIVE"
export LAB_PROJECT_DIR="$PWD"
export LAB_PRIVATE_DIR="$PWD/private"
LAB_TF_VAR_ARGS=(-var-file=fixture.tfvars)
LAB_VMS_FILE=fixture.tfvars
LAB_CLONE_NAME=a
LAB_VM_ROOT_WIN="$PWD/clones"
TF_VAR_vmrest_endpoint=offline
lab_terraform_env() { :; }
lab_base_identity() { :; }
lab_curl_auth() { :; }
curl() { printf 200; }
wslpath() { echo "$2"; }
terraform() { python3 "$FIXTURE_NATIVE/fake-tf.py" "$@"; }
ansible() {
  [[ "$1" == -i && "$2" == *.yml ]] || return 99
  echo ansible-poweroff >> "$FIXTURE_NATIVE/events"
  python3 -c 'import json,os; from pathlib import Path; Path(os.environ["FIXTURE_NATIVE"], "ansible-env.json").write_text(json.dumps({k: os.environ.get(k) for k in ["ANSIBLE_PIPELINING", "ANSIBLE_TIMEOUT"]}))'
  return 42
}
'''
        self.config_mocks=fail+mocks
        self.source=self.source.replace('source "$(dirname "${BASH_SOURCE[0]}")/config.sh"',fail+mocks,1)
        # Override the API boundary in this disposable copy. This is portable
        # across Windows/Git Bash and Linux, with no chance of finding curl.exe.
        helper=self.root/'lib'/'power-map.py'
        code=helper.read_text()
        code=code.replace("if __name__ == '__main__':", "def power(vm, max_time=10):\n    return 'off' if vm['name'] in json.loads(os.environ.get('POWER_OFF', '[]')) else 'on'\n\nif __name__ == '__main__':")
        helper.write_text(code,newline='\n')
        code=helper.read_text().replace("if __name__ == '__main__':", "def wait_off(vms, seconds):\n    return [vm['name'] for vm in vms] if os.environ.get('WAIT_FAIL') else []\n\nif __name__ == '__main__':")
        helper.write_text(code,newline='\n')
        self.env=dict(os.environ,FIXTURE_NATIVE=self.root.as_posix(), FIXTURE_PYTHON=sys.executable,
                      VMWS_ENDPOINT='offline',VMWS_USERNAME='fake',VMWS_PASSWORD='fake')

    def run_case(self,args,live=('a','b'),desired=('a','b','new'),replace=(),resize=False):
        (self.root/'fake.json').write_text(json.dumps(dict(live=list(live),desired=list(desired),replace=list(replace),resize=resize)))
        (self.root/'calls').write_text('')
        for name in set(live)|set(desired): (self.root/(name+'.vmx')).write_text('')
        result=subprocess.run(['bash','-s','--',*args],input=self.source,env=self.env,
                              capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=30)
        calls=[json.loads(l) for l in (self.root/'calls').read_text().splitlines()]
        return result,calls

    def test_up_selection_and_saved_apply(self):
        for args,expected in [(['on'],dict(a='on',b='on',new='off')),(['on','new'],dict(a='on',b='on',new='on')),
                              (['on','--all'],dict(a='on',b='on',new='on'))]:
            with self.subTest(args=args):
                result,calls=self.run_case(args)
                self.assertEqual(result.returncode,0,result.stderr)
                applies=[c for c in calls if c['args'][0]=='apply']
                self.assertEqual(applies[0]['seeds'],dict(a='on',b='on',new='off'))
                self.assertEqual(applies[-1]['seeds'],expected)
                self.assertTrue(all(not any(a.startswith('-var') for a in c['args']) for c in applies))
                self.assertFalse(list((self.root/'private').glob('plan.*')))

    def test_preparing_message_lists_all_clones_on_one_line(self):
        result,_=self.run_case(['on'],live=(),desired=('a','b','new'))
        self.assertEqual(result.returncode,0,result.stderr)
        line=next(l for l in result.stdout.splitlines() if 'Preparing powered-off clones:' in l)
        self.assertEqual(line.split(':',1)[1].split(),['a','b','new'])

    def test_destroy_stdin_and_status_through_runner_and_profile_discovery(self):
        # Use the real discovery function against a fake PowerShell that drains
        # stdin, modelling the Windows interop boundary without calling Windows.
        config=(ROOT/'lib/config.sh').read_text()
        discovery=config[config.index('lab_windows_profile() {'):config.index('\nexport VMWS_ENDPOINT=')]
        discovery=discovery.replace('local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
                                    'local ps="$FIXTURE_NATIVE/fake-powershell"')
        ps=self.root/'fake-powershell'
        ps.write_text('#!/usr/bin/env bash\ncat >/dev/null\nprintf "fixture-profile"\n',newline='\n')
        ps.chmod(0o700)
        source=self.source.replace('operation="${1:-status}"',discovery+
            '\nLAB_WINDOWS_PROFILE=$(lab_windows_profile)\noperation="${1:-status}"',1)
        script=self.root/'lifecycle.sh'; script.write_text(source,newline='\n')
        entry=(ROOT/'lab').read_text()
        functions=entry[entry.index('lock() {'):entry.index('\ncase "$cmd" in')]
        # Git Bash lacks setsid/flock. Model setsid's documented fork case:
        # without --wait it returns success before the command completes.
        # Linux additionally exercises the real tools in PowerTests.
        shim='''
lock() { :; }
env() {
  shift
  [[ "$1" == setsid ]] || return 99
  shift
  if [[ "$1" == --wait ]]; then shift; "$@"
  else "$@" & return 0
  fi
}
run_locked "$1/lifecycle.sh" destroy
'''
        (self.root/'fake.json').write_text(json.dumps(dict(live=['a'],desired=['a'])))
        for code in [1,7,0]:
            env=dict(self.env,DESTROY_RC=str(code))
            run=subprocess.run(['bash','-c','set -euo pipefail\n'+functions+shim,'fixture',self.root.as_posix()],
                input='no\n',env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(run.returncode,code,run.stderr)
            self.assertEqual((self.root/'confirmation').read_text(),'no')

    def test_gui_off_preserved_and_off_resize_can_start(self):
        self.env['POWER_OFF']='["a"]'
        result,calls=self.run_case(['on'],live=('a',),desired=('a',))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([c for c in calls if c['args'][0]=='apply'][-1]['seeds'],dict(a='off'))
        result,calls=self.run_case(['on','a'],live=('a',),desired=('a',),resize=True)
        self.assertEqual(result.returncode,0,result.stderr)
        applies=[c for c in calls if c['args'][0]=='apply']
        self.assertEqual([c['seeds'] for c in applies], [dict(a='off'),dict(a='on')])

    def test_replacement_creation_off_survivor_on(self):
        for selection in [[],['a']]:
            result,calls=self.run_case(['on','--allow-destroy',*selection],desired=('a','b'),replace=('a',))
            self.assertEqual(result.returncode,0,result.stderr)
            applies=[c for c in calls if c['args'][0]=='apply']
            self.assertIn('-destroy',applies[0]['args'])
            self.assertEqual(applies[1]['seeds'],dict(a='off',b='on'))
            self.assertEqual(applies[-1]['seeds'],dict(a='on' if selection else 'off',b='on'))

    def test_resize_blocks_before_mutation_up_and_down(self):
        for args in [['on'],['off','--all','--hard']]:
            result,calls=self.run_case(args,desired=('a','b'),resize=True)
            self.assertEqual(result.returncode,5,result.stderr)
            self.assertIn('config_change_requires_off',result.stderr)
            self.assertFalse(any(c['args'][0]=='apply' for c in calls))

    def test_collision_precedes_replacement(self):
        folder=self.root/'clones'/'new'; folder.mkdir(parents=True); (folder/'held').write_text('fixture')
        result,calls=self.run_case(['on','--allow-destroy'],replace=('a',))
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertIn('folder already has files',result.stderr)
        self.assertFalse(any(c['args'][0]=='apply' for c in calls))
        # Only the initial restore check may precede the collision gate.
        self.assertEqual((self.root/'events').read_text().splitlines(),['restore'])

    def test_metadata_update_guard_and_off_staging(self):
        self.env['METADATA']='1'
        result,calls=self.run_case(['on'],live=('a',),desired=('a',))
        self.assertEqual(result.returncode,5,result.stderr)
        self.assertFalse(any(c['args'][0]=='apply' for c in calls))
        self.env['POWER_OFF']='["a"]'
        result,calls=self.run_case(['on','a'],live=('a',),desired=('a',))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual([c['seeds'] for c in calls if c['args'][0]=='apply'],[dict(a='off'),dict(a='on')])

    def test_delete_create_and_removed_selection(self):
        result,calls=self.run_case(['on','--allow-destroy'],desired=('a','new'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(set(json.loads((self.root/'fake.json').read_text())['live']),{'a','new'})
        result,calls=self.run_case(['on','b','--allow-destroy'],desired=('a','new'))
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertIn('unknown_vm',result.stderr)
        self.assertFalse(any(c['args'][0]=='apply' for c in calls))

    def test_creation_guard_refuses_unexpected_delete_or_replace(self):
        for action in ['delete','replace']:
            self.env['UNEXPECTED_ACTION']=action
            result,calls=self.run_case(['on','--allow-destroy'])
            self.assertNotEqual(result.returncode,0,result.stderr)
            self.assertIn('Unexpected deletion',result.stderr)
            self.assertFalse(any(c['args'][0]=='apply' for c in calls))

    def test_precedence_every_plan_and_target_destroy(self):
        result,calls=self.run_case(['on','--allow-destroy'],desired=('a','b'),replace=('a',))
        self.assertEqual(result.returncode,0,result.stderr)
        for c in calls:
            args=c['args']
            if args[0]=='plan' or '-destroy' in args:
                self.assertTrue(args[-1].startswith('-var=power_states='),args)
                self.assertLess(args.index('-var-file=fixture.tfvars'),len(args)-1)
        diagnostic=(ROOT/'lib/diagnose.sh').read_text()
        self.assertIn('"${LAB_TF_VAR_ARGS[@]}" -var="power_states=$TF_VAR_power_states"',diagnostic)
        # Execute the production diagnostic plan line against the same fake:
        # explicit off must win over the conflicting variable-file on value.
        command=next(line for line in diagnostic.splitlines() if line.startswith('terraform plan '))
        script=self.config_mocks+"\nTF_VAR_power_states='"+json.dumps(dict(a='off',b='on'))+"'\nexport TF_VAR_power_states\nplan=preview\n"+command
        run=subprocess.run(['bash','-s'],input=script,env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(run.returncode,0,run.stderr)
        last=json.loads((self.root/'calls').read_text().splitlines()[-1])
        self.assertEqual(last['seeds'],dict(a='off',b='on'))

    def test_empty_shutdown_inventory_skips_ansible(self):
        self.env['EMPTY_INVENTORY']='1'
        result,calls=self.run_case(['off','a'],desired=('a','b'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('ansible-poweroff',(self.root/'events').read_text())

    def test_journal_replayed_before_collision(self):
        folder=self.root/'clones'/'new'; folder.mkdir(parents=True)
        (folder/'cloud-init-new.iso').write_text('fixture')
        journal=self.root/'terraform'/'cleanup-pending.json'
        journal.write_text(json.dumps(dict(pending=dict(new=dict(id='new',name='new',path=str(folder/'new.vmx'))))))
        code=(ROOT/'lib/cleanup-guest.py').read_text().replace(
            "Path(subprocess.check_output(['wslpath', '-u', vm['path']], text=True).strip())", "Path(vm['path'])")
        (self.root/'lib'/'cleanup-guest.py').write_text(code)
        result,calls=self.run_case(['on'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(folder.exists())
        self.assertFalse(journal.exists())

    def test_usage_and_unknown_names(self):
        for args in [['off'],['on','--all','a'],['off','--all','a'],['on','missing']]:
            result,calls=self.run_case(args)
            self.assertEqual(result.returncode,2,result.stderr)
            self.assertFalse(any(c['args'][0]=='apply' for c in calls))

    def test_graceful_down_ansible_environment(self):
        for timeout,expected in [(None,'60'), ('90','90')]:
            with self.subTest(timeout=timeout):
                self.env.pop('ANSIBLE_TIMEOUT',None)
                if timeout is not None: self.env['ANSIBLE_TIMEOUT']=timeout
                self.env['ANSIBLE_PIPELINING']='false'
                result,_=self.run_case(['off','a'],desired=('a','b'))
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(json.loads((self.root/'ansible-env.json').read_text()),
                                 dict(ANSIBLE_PIPELINING='true',ANSIBLE_TIMEOUT=expected))

    def test_graceful_down_ignores_ansible_failure_but_requires_power_off(self):
        result,calls=self.run_case(['off','a'],desired=('a','b'))
        self.assertEqual(result.returncode,0,result.stderr)
        applies=[c for c in calls if c['args'][0]=='apply']
        self.assertEqual(applies[-1]['seeds'],dict(a='off'))
        self.assertIn('ansible-poweroff',(self.root/'events').read_text())
        self.env['WAIT_FAIL']='1'
        result,calls=self.run_case(['off','a'],desired=('a','b'))
        self.assertEqual(result.returncode,1,result.stderr)
        self.assertIn('guest_not_ready',result.stderr)
        self.assertFalse(any(c['args'][0]=='apply' for c in calls))


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for name,content in [('fixture-key','placeholder'),('leases',''),('conf','')]:
            (self.root/name).write_text(content)
        self.vms={name:dict(id=name,path=str(self.root/(name+'.vmx')),groups=['demo']) for name in ['a','b','c']}
        for name in self.vms:
            (self.root/(name+'.vmx')).write_text('ethernet1.generatedAddress = "00:50:56:00:00:01"')
            (self.root/('known_hosts-'+name)).write_text('wsl-vmware-lab-'+name+' placeholder')
        self.env=patch.dict(os.environ,dict(LAB_PRIVATE_DIR=str(self.root),LAB_SSH_KEY=str(self.root/'fixture-key'),
            LAB_DHCP_LEASES=str(self.root/'leases'),LAB_DHCP_CONF=str(self.root/'conf'),
            LAB_INVENTORY=str(self.root/'inventory.json'),LAB_INVENTORY_SELECTION_FILE=str(self.root/'selection')))
        self.env.start(); self.addCleanup(self.env.stop)
        os.environ.pop('LAB_INVENTORY_SELECTED',None)

    def run_inventory(self,best=False,powers=None):
        def output(args,**kwargs):
            if args[0]=='terraform':
                if 'show' in args:
                    return json.dumps({'values':{'root_module':{'resources':[
                        dict(mode='managed',type='vmworkstation_virtual_machine',index=n,values=v)
                        for n,v in self.vms.items()]}}})
                if best: raise AssertionError('best effort must not read outputs')
                return json.dumps(self.vms)
            if args[0]=='wslpath': return args[-1]
            raise AssertionError(args)
        def ssh(args,**kwargs):
            # a is reachable, b fails both direct and proxy checks.
            good='HostKeyAlias=wsl-vmware-lab-a' in args
            return subprocess.CompletedProcess(args,0 if good else 1,'','unreachable')
        def get_power(vm):
            value=(powers or dict(a='on',b='on',c='off'))[vm['id']]
            if value=='error': raise ValueError('fake failure')
            return value
        with patch.object(inventory.sys,'argv',['inventory']+(['--best-effort'] if best else [])), \
                patch.object(inventory.subprocess,'check_output',side_effect=output), \
                patch.object(inventory.subprocess,'run',side_effect=ssh), \
                patch.object(inventory.power_api,'power',side_effect=get_power), \
                patch.object(inventory,'mgmt_subnet',return_value='fixture'), \
                patch.object(inventory,'pick_address',return_value=('fixture-address',[])), \
                patch('sys.stdout',new_callable=io.StringIO), patch('sys.stderr',new_callable=io.StringIO):
            inventory.main()

    def test_best_effort_keeps_reachable_omits_off_and_unreachable(self):
        os.environ['LAB_INVENTORY_SELECTED']='["a","b"]'
        self.run_inventory(best=True)
        hosts=json.loads((self.root/'inventory.json').read_text())['all']['hosts']
        self.assertEqual(set(hosts),{'a'})

    def test_zero_hosts_api_failure_and_frozen_set(self):
        for powers in [dict(a='off',b='off',c='off'),dict(a='error',b='off',c='off')]:
            with self.assertRaises(SystemExit) as exc: self.run_inventory(powers=powers)
            self.assertEqual(exc.exception.code,3)
        with self.assertRaises(SystemExit) as exc: self.run_inventory()
        self.assertEqual(exc.exception.code,1)  # b is unreachable
        self.assertEqual(json.loads((self.root/'selection').read_text()),['a','b'])
        os.environ['LAB_INVENTORY_SELECTED']='["a","b"]'
        with self.assertRaises(SystemExit) as exc:
            self.run_inventory(powers=dict(a='on',b='off',c='on'))
        self.assertEqual(exc.exception.code,1)  # b cannot silently drop out

    def test_configure_limit_uses_default_playbook_and_credentials(self):
        source=(ROOT/'lib/configure.sh').read_text(encoding='utf-8')
        mocks=r'''
cd "$FIXTURE_NATIVE"
LAB_PROJECT_DIR="$PWD"
LAB_PRIVATE_DIR="$PWD/private"
LAB_INVENTORY=fixture
LAB_GUEST_USER=lab
LAB_PLAYBOOK="$PWD/playbook.yml"
lab_require_credentials() { echo credentials; }
timeout() { return 0; }
ansible-playbook() { printf 'ARG=%s\n' "$@"; }
'''
        config=(ROOT/'lib/config.sh').read_text(encoding='utf-8')
        ansible_env=config[config.index('lab_ansible_env() {'):config.index('\nLAB_ENV_FILE=')]
        source=source.replace('source "$here/config.sh"',ansible_env+mocks)
        (self.root/'playbook.yml').write_text('---\n')
        run=subprocess.run(['bash','-s','--','--limit','db'],input=source,
            env=dict(os.environ,FIXTURE_NATIVE=self.root.as_posix()),capture_output=True,text=True)
        self.assertEqual(run.returncode,0,run.stderr)
        self.assertIn('credentials',run.stdout)
        self.assertIn('playbook.yml',run.stdout)
        self.assertIn('ARG=--limit\nARG=db',run.stdout)


if __name__=='__main__': unittest.main()
