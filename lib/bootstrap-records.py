"""Durable backup of bootstrap records before targeted replacement destroy.

Raw state manipulation follows the former lifecycle.sh restoration code.
Only missing records for VM instances still in state are restored.
"""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def bootstrap(state):
    return next((r for r in state.get('resources', []) if r['mode'] == 'managed'
                 and r['type'] == 'terraform_data' and r['name'] == 'guest_bootstrap'), None)


def restore(old, state):
    old = old.get('bootstrap')
    new = bootstrap(state)
    live = {i.get('index_key') for r in state.get('resources', [])
            if r['mode'] == 'managed' and r['type'] == 'vmworkstation_virtual_machine'
            for i in r.get('instances', [])}
    have = {i.get('index_key') for i in (new or {}).get('instances', [])}
    add = [i for i in (old or {}).get('instances', [])
           if i.get('index_key') in live and i.get('index_key') not in have]
    if add:
        if new is None:
            new = dict(copy.deepcopy(old), instances=[])
            state['resources'].append(new)
        new['instances'] += copy.deepcopy(add)
        state['serial'] += 1
    return [i['index_key'] for i in add]


def main():
    mode, filename, *doomed = sys.argv[1:]
    path = Path(filename)
    if mode == 'restore' and not path.exists():
        return
    state = json.loads(subprocess.check_output(['terraform', 'state', 'pull'], text=True))
    if mode == 'save':
        # Exclusive creation: never overwrite the only recovery copy.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as out:
            json.dump({'bootstrap': bootstrap(state), 'doomed': doomed}, out)
            out.flush()
            os.fsync(out.fileno())
    elif mode == 'restore':
        names = restore(json.loads(path.read_text()), state)
        if names:
            # Use the same state-push file interface as the old shell code.
            fd, temporary = tempfile.mkstemp(dir=os.environ['LAB_PRIVATE_DIR'])
            try:
                with os.fdopen(fd, 'w') as out:
                    json.dump(state, out)
                subprocess.run(['terraform', 'state', 'push', temporary], check=True)
            finally:
                Path(temporary).unlink()
        path.unlink()  # only after a successful push (or no missing records)
        print('[OK] Restored bootstrap records: ' + (', '.join(names) or 'none missing'))
    else:
        raise ValueError('unknown mode')


if __name__ == '__main__':
    main()
