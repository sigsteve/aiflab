# AIFLab Demo Local Storage

This structured Blueprint bundle supplies a default StorageClass only for a
local demonstration cluster that does not already have one. The general
`aiflab/deploy.sh` wrapper checks the cluster before applying it:

- an existing default StorageClass is reused unchanged;
- no default causes this Application Collection Local Path Provisioner to be
  installed through SUSE AI Factory;
- multiple defaults fail the preflight so the cluster administrator can choose
  one deliberately.

The resulting `aiflab-local-path` class uses node-local `hostPath` volumes,
`WaitForFirstConsumer`, and a `Delete` reclaim policy. It is convenient for a
single-node laptop lab, but provides no replication, failover, shared access,
snapshot, backup, or production durability guarantee.

Application Collection credentials must be configured before this bundle is
needed. It can also be deployed directly on a cluster with no default class:

```bash
./aiflab/aifctl/bin/aifctl blueprint deploy \
  --from aiflab/platform/local-storage
```

`aifctl` verifies `ClusterRepo/application-collection` before creating the
platform namespaces, so absent or unreconciled credentials fail without a
partial storage deployment. The credentials remain platform-scoped and are not
owned by this storage Blueprint.

This storage has platform scope and intentionally remains installed when an
individual demo is removed.
