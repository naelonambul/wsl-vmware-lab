# Distributed systems: establish order before configure or start

This applies to replication, master/worker roles, membership and quorum.
Before any configuration or start, look up the **official documentation for
the exact installed version**. Write the following record in the user's
project notes, with links and the installed version. No record, no configure
and no start; guessing an order or merely choosing manual start is insufficient.

## Required record

- Configuration order and which role starts first; each role's own readiness
  query and expected result, plus what dependent nodes do when peers are absent.
- First-creation/bootstrap order versus normal restart order; peer addressing
  over `lan0`, stable identities and required membership/quorum.
- Irreversible one-time initialization, how to detect it already happened,
  and a playbook guard preventing repetition.
- State-dependent bootstrap after orderly full shutdown versus crash recovery.
- Whether packages start services during installation, whether services start
  at OS boot, and how to enforce the documented policy.
- Full-shutdown order, full-restart order and recovery decisions requiring the
  user. Include commands, expected readiness/membership results and stop points.

## Execute the recorded procedure

Where services must stay stopped during installation, use
`ansible.builtin.apt` with `policy_rc_d: 101` (the Debian policy return code
denying service starts), then apply the documented boot policy. This only
controls package scripts that honor that policy; verify the service's state.
Guard format/init steps using the system's persistent state, not a temporary
marker. A rerun must not reformat a node or bootstrap another independent cluster.

Ordered VM selection (`./lab up <vm>` / `./lab down <vm>`) is introduced in
PR 2. **Until then this CLI starts/stops the whole checkout:** do not use a
multi-VM up for a system that requires ordered VM starts. Stop and explain the
limitation. Once selection exists, use one invocation per ordered step; a
multi-name call gives no ordering guarantee. Between steps check readiness with
the system's own query, for example a check playbook with `--limit`; an open
TCP port alone is insufficient. Inventory readiness can still depend on other
running VMs, and inventory groups are not a durable source of cluster topology.

Several PCs require one checkout per PC and a written sequence per host;
one checkout cannot orchestrate another's lifecycle. Services communicate over
`lan0`. Give the user the written bootstrap, shutdown and restart procedures.
After every reboot verify `./lab status`, `lan0` addresses, membership and a
fresh write on one node read on another. Partial starts/stops are a user decision;
report evidence and ask before recovery changes.

## Versioned examples to research, not recipes to run

- **MariaDB Galera:** record the exact MariaDB/Galera versions. Consult that
  version's official bootstrap and full-cluster restart documentation, including
  `safe_to_bootstrap` for orderly shutdown and `wsrep-recover` / recovered
  sequence numbers after a crash. Never select a bootstrap node by hostname
  alone or repeat initialization just because a peer cannot join. Start at
  [MariaDB Galera documentation](https://mariadb.com/docs/galera-cluster/).
- **Hadoop 2.7.7, non-HA:** separate initial NameNode formatting from service
  starts and restarts; record the exact documented role order and readiness
  commands from the
  [2.7.7 cluster setup guide](https://hadoop.apache.org/docs/r2.7.7/hadoop-project-dist/hadoop-common/ClusterSetup.html).
  Do not apply this example to an HA or different-version cluster.

Check official pages when writing the actual project's record; these examples
do not supply a complete bootstrap/recovery procedure. Package install control:
[ansible.builtin.apt](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html).
