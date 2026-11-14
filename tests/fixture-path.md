# Closed fixture PATH audit

Disposable shell checkouts start with the complete `lib/` tree and `lab` via
`copy_fixture_tree`; scenario overrides are applied afterward. The real config
loader initializes `LAB_PROJECT_DIR` and sources its definitions before fixture
overrides run. Scripts execute at their copied paths, preserving sibling shell
sources and Python imports. Production source is never sliced into fragments.

`LifecycleTests` supplies the PATH inherited by the envelope and review fixtures.
Real utility links resolve only through `/usr/bin:/bin`, then use the resolved
absolute target. `python3` links to the running interpreter's absolute path.
No utility lookup uses the runner's PATH and no wrapper dispatches to itself.

| Scripts / boundary | Commands and fixture treatment |
| --- | --- |
| Entry point / process control | Real `bash`, `env`, `flock`, `setsid`, `mktemp`, `rm`, `sleep`, `cat`, `sed`; signals, `wait`, and `kill` are Bash builtins. |
| Config / lifecycle / reports | Real `awk`, `cut`, `dirname`, `find`, `grep`, `head`, `id`, `mkdir`, `chmod`, `paste`, `sha256sum`, `sort`, `tail`, `tr`, `timeout`; Python is the fixture interpreter. |
| Base / bootstrap / account | Real `cp`, `date`, `hostname`, `mv`, `seq`, `sha512sum`, `stat`, `tar`, plus the shared utilities above. `ls` remains available even though the collision gate now uses checked `find`. |
| Other standard utilities | Real `basename`, `readlink`, `tee`, `touch`, `true`, `wc` for fixture bodies and utility helpers. |
| VM / SSH / network / install boundaries | Explicit fail-on-unexpected-call fakes for `ansible`, `ansible-playbook`, `apt-get`, `cloud-localds`, `curl`, `dpkg`, `gpg`, `gpgv`, `ip`, `ping`, `qemu-img`, `ssh`, `ssh-keygen`, `sudo`, `terraform`, `wslpath`. Scenario functions replace these with disposable behavior where used. Setup prerequisite probes intentionally see fakes as installed tools; the missing-tool cases hide each fake explicitly. |
| Absolute Windows executables | Review fixtures replace PowerShell with a disposable fake. VM executables are not present in the disposable VMware directory. Python subprocess/HTTP calls in production review bodies are intercepted and reject any unrecognized command or URL. |
| Guest cloud-init commands | `sh`, `cloud-init-per`, `systemd-machine-id-setup`, and guest `rm` are emitted as guest configuration, never run on the fixture host. |

Shared result assertions reject `command not found` and unexpected fake-call
diagnostics, including in tests expecting a nonzero product result. This keeps
an absent utility from impersonating an expected safety refusal. Intentional
tool failure regressions inject explicit failure functions instead of relying
on the machine's installed tools.
