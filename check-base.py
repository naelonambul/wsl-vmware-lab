"""Confirm the base VM that Terraform will clone, before anything changes.

  python3 check-base.py WSL_BASE_VMX DISPLAY_NAME

The provider finds the base by display name and takes the first match from
vmrest's list, so a second VM with the same name could be cloned instead.
This checks that exactly one registered VM has DISPLAY_NAME and that it is the
VMX at WSL_BASE_VMX, then prints its vmrest id. Any doubt (a duplicate, the
name on another VMX, a VM whose name cannot be read) is an error.
Needs VMWS_ENDPOINT, VMWS_USERNAME and VMWS_PASSWORD (lib/config.sh).
"""
import base64
import json
import ntpath
import os
import subprocess
import sys
import urllib.error
import urllib.request


def norm(path):
    return ntpath.normcase(ntpath.normpath(path))


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    vmx, name = argv[1], argv[2]
    expected = subprocess.check_output(['wslpath', '-w', vmx], text=True).strip()
    endpoint = os.environ['VMWS_ENDPOINT'].rstrip('/')
    token = base64.b64encode(
        (os.environ['VMWS_USERNAME'] + ':' + os.environ['VMWS_PASSWORD']).encode()).decode()

    def get(route):
        req = urllib.request.Request(endpoint + route, headers={
            'Authorization': 'Basic ' + token,
            'Accept': 'application/vnd.vmware.vmw.rest-v1+json'})
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read())

    matches, unreadable = [], []
    for vm in get('/vms'):
        try:
            shown = get('/vms/' + vm['id'] + '/params/displayName').get('value')
        except (urllib.error.URLError, ValueError) as e:
            unreadable.append(vm['path'] + ' (' + str(e) + ')')
            continue
        if shown == name:
            matches.append(vm)

    def fail(msg, paths=()):
        print('[ERROR] ' + msg, file=sys.stderr)
        for p in paths:
            print('        ' + p, file=sys.stderr)
        return 1

    if unreadable:
        return fail('Could not read the display name of these registered VMs, so the base '
                    'cannot be told apart from them. Remove stale entries from VMware '
                    "Workstation's library, then retry:", unreadable)
    if not matches:
        return fail('No registered VM is named "' + name + '". Run: ./lab setup (registers the base)')
    if len(matches) > 1:
        return fail(str(len(matches)) + ' registered VMs are named "' + name + '"; Terraform '
                    'could clone any of them. Rename or remove all but the base ' + expected + ':',
                    [vm['path'] for vm in matches])
    if norm(matches[0]['path']) != norm(expected):
        return fail('The VM named "' + name + '" is not the lab base VMX:',
                    ['found:    ' + matches[0]['path'], 'expected: ' + expected])
    print(matches[0]['id'])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
