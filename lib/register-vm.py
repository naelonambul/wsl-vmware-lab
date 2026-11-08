"""Register an existing VMX through vmrest; never starts or clones the VM."""
import base64
import json
import ntpath
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request


def main():
    if len(sys.argv) != 3:
        raise ValueError("Usage: register-vm.py WSL_VMX_PATH DISPLAY_NAME")
    vmx = Path(sys.argv[1]).resolve(strict=True)
    if vmx.suffix.lower() != ".vmx":
        raise ValueError("Expected a .vmx file")
    name = sys.argv[2].strip()
    if not name:
        raise ValueError("Display name must not be empty")
    windows_path = subprocess.check_output(
        ["wslpath", "-w", str(vmx)], text=True
    ).strip()
    if windows_path.startswith("\\\\wsl"):
        raise ValueError("Place the VM on a Windows drive such as /mnt/c/")
    endpoint = os.environ["VMWS_ENDPOINT"].rstrip("/")
    if not endpoint.endswith("/api"):
        raise ValueError("VMWS_ENDPOINT must end with /api")
    token = base64.b64encode(
        (os.environ["VMWS_USERNAME"] + ":" + os.environ["VMWS_PASSWORD"]).encode()
    ).decode()

    def request(route, payload=None):
        req = urllib.request.Request(
            endpoint + route,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={"Authorization": "Basic " + token,
                     "Content-Type": "application/vnd.vmware.vmw.rest-v1+json",
                     "Accept": "application/vnd.vmware.vmw.rest-v1+json"},
            method="GET" if payload is None else "POST",
        )
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else None

    def find_vm():
        return next((vm for vm in request("/vms")
                     if ntpath.normcase(ntpath.normpath(vm["path"])) ==
                     ntpath.normcase(ntpath.normpath(windows_path))), None)

    # Registrations whose VMX no longer exists (e.g. after moving the repository)
    # are reported, not deleted: vmrest DELETE /vms/{id} can delete the VM files.
    for vm in request("/vms"):
        try:
            local = subprocess.run(["wslpath", "-u", vm["path"]], capture_output=True,
                                   text=True, check=True).stdout.strip()
        except Exception:
            continue
        if local and not os.path.exists(local):
            print("[WARN] Stale registration (VMX missing): " + vm["id"] + " " + vm["path"]
                  + "  - remove it in VMware Workstation's library", file=sys.stderr)

    existing = find_vm()
    if existing:
        print("[OK] Already registered: " + existing["id"])
        return
    try:
        request("/vms/registration", {"name": name, "path": windows_path})
    except urllib.error.HTTPError as error:
        # vmrest has answered 500 while still registering the VM; trust the list.
        if not find_vm():
            raise
        print("[WARN] vmrest answered HTTP " + str(error.code) + " but the VM is registered",
              file=sys.stderr)
    registered = find_vm()
    if not registered:
        raise RuntimeError("Registration returned but VM is absent from /api/vms")
    print("[OK] Registered through API: " + registered["id"])
    print("[OK] VMX: " + windows_path)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        print("[ERROR] vmrest HTTP " + str(error.code), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        print("[ERROR] " + str(error), file=sys.stderr)
        sys.exit(1)
