"""Small append-only result recorder and the single stdout envelope writer."""
import json
import os
import sys


def record(kind, value):
    path = os.environ.get('LAB_RESULT_FILE')
    if path:
        with open(path, 'a', encoding='utf-8') as out:
            out.write(json.dumps({kind: value}, separators=(',', ':')) + '\n')


def failure(code, message, hint='', details=None):
    record('error', dict(code=code, message=message, hint=hint, details=details or {}))


def records(path):
    """Keep complete records even if a writer was interrupted mid-append."""
    try:
        with open(path, encoding='utf-8') as source:
            for line in source:
                try:
                    item = json.loads(line)
                    if not isinstance(item, dict):
                        raise ValueError('not an object')
                    yield item
                except ValueError:
                    yield {'corrupt': True}
    except (OSError, UnicodeError):
        yield {'corrupt': True}


def finish(path, command, dry_run, status):
    data, warnings, error, changed = {}, [], None, False
    corrupt = False
    for item in records(path):
        data.update(item.get('data', {}))
        warnings.extend(item.get('warnings', []))
        error = error or item.get('error')
        changed = changed or item.get('changed', False)
        corrupt = corrupt or item.get('corrupt', False)
    # Signals and incomplete records take precedence; otherwise the first
    # explicit error wins, including over later uncaught section failures.
    exit_status = 0
    if corrupt or status in (130, 143) or (status and error is None):
        exit_status = status if status in (130, 143) else 1
        error = dict(code='runtime_error', message='Command failed; read stderr.',
                     hint='./lab status; inspect before retrying.', details=dict(exit_status=status))
    elif error is not None:
        with open(os.path.join(os.path.dirname(__file__), 'describe.json'), encoding='utf-8') as source:
            table = json.load(source)
        exit_status = table['errors'][error['code']]['exit']
    if command in ('up', 'down', 'destroy'):
        data.setdefault('actions', [])
        data.setdefault('vms', [])
        if not dry_run and error is not None and changed:
            for action in data['actions']:
                if action['result'] == 'planned':
                    action['result'] = 'failed'
    print(json.dumps(dict(ok=error is None, command=command, dry_run=dry_run,
                          changed=changed, data=data, warnings=warnings, error=error)))
    return exit_status


def main():
    mode, *args = sys.argv[1:]
    if mode == 'finish':
        sys.exit(finish(args[0], args[1], args[2] == '1', int(args[3])))
    elif mode == 'data':
        record('data', json.loads(args[0]))
    elif mode == 'fail':
        failure(args[0], args[1], args[2], json.loads(args[3]))
    elif mode == 'changed':
        record('changed', True)
    elif mode == 'plan-changed':
        plan = json.load(sys.stdin)
        if any(r['change']['actions'] not in (['no-op'], ['read']) for r in plan.get('resource_changes', [])):
            record('changed', True)
    elif mode == 'actions':
        # stdin is the first saved plan, never retained in the result file.
        plan = json.load(sys.stdin)
        actions = []
        seeds = json.loads(os.environ.get('TF_VAR_power_states', '{}'))
        selected = set(args[2:])
        for resource in plan.get('resource_changes', []):
            if resource['type'] != 'vmworkstation_virtual_machine':
                continue
            name = str(resource['index'])
            change = resource['change']
            steps = change['actions']
            action = 'replace' if 'delete' in steps and 'create' in steps else steps[0]
            if action == 'update':
                before, after = change.get('before') or {}, change.get('after') or {}
                if ({k: v for k, v in before.items() if k != 'state'} ==
                        {k: v for k, v in after.items() if k != 'state'} and
                        not any(v for k, v in change.get('after_unknown', {}).items() if k != 'state')):
                    action = 'no-op'
            if action in ('create', 'delete', 'replace', 'update'):
                actions.append(dict(vm=name, action=action, result=args[0]))
            if args[1] == 'on' and action != 'delete' and (os.environ.get('LAB_SELECT_ALL') == '1' or name in selected):
                if action in ('create', 'replace') or seeds.get(name) == 'off':
                    actions.append(dict(vm=name, action='power_on', result=args[0]))
            if args[1] == 'off' and (os.environ.get('LAB_SELECT_ALL') == '1' or name in selected):
                if seeds.get(name) == 'on':
                    actions.append(dict(vm=name, action='power_off', result=args[0]))
        record('data', dict(actions=actions))
    elif mode == 'outcome':
        # Update action results only; never read a plan after an apply.
        path = os.environ.get('LAB_RESULT_FILE')
        if path:
            actions = []
            changed = False
            for item in records(path):
                actions = item.get('data', {}).get('actions', actions)
                changed = changed or item.get('changed', False)
            if args[0] == 'failed' and not changed:
                return
            for action in actions:
                action['result'] = args[0]
            record('data', dict(actions=actions))
    else:
        raise ValueError('unknown recorder mode')


if __name__ == '__main__':
    main()
