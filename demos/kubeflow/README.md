# Kubeflow Blueprint Deployment Bundle

This is an experimental, clean-install demonstration of Kubeflow through SUSE
AI Factory on a laptop-sized RKE2 or K3s cluster. It is not supported, not a
production or upgrade design, and not an air-gap solution.

## Deployment Shape

`aifctl` applies and waits for these stages in filename order:

```text
deps/10-control-namespace.yaml
  aiflab-kubeflow control namespace

deps/20-namespaces.yaml
  Dedicated Kubeflow application namespaces

deps/30-platform.yaml
  Istio and aiflab-kubeflow-bootstrap 0.4.0 AIWorkloads

deps/40-chart-repository.yaml
  ClusterRepo/aiflab-kubeflow-hydrated

blueprint.yaml
  AIFLab Kubeflow Blueprint 0.3.0 domain revision using upstream chart 0.3.2
```

The bootstrap AIWorkload uses the upstream External Secrets chart's supported
`extraObjects` value to own `Deployment/kubeflow-chart-repository` and its
Service in `kubeflow`. The Deployment's init containers download the
SHA-pinned Kubeflow `0.3.2` archive, pull the SHA-pinned Application
Collection PostgreSQL `0.5.5` dependency, embed that one missing package, and
generate a Helm index. The verified output is cached on a 512 MiB PVC using the
cluster's default StorageClass, and its NGINX container serves the result only
inside the cluster.

After the bootstrap workload is Running, `aifctl` creates
`ClusterRepo/aiflab-kubeflow-hydrated`, waits for Rancher to download its index,
and submits the main Blueprint. The main Helm release owns Model Catalog
PostgreSQL with the rest of Kubeflow.

The Git checkout contains no hydrated chart. On restart, the repository pod
verifies the cached archive digest, Helm index digest, and embedded PostgreSQL
package digest before reusing it. Missing or invalid cache content is rebuilt
from the pinned sources. The repository workload must remain available for
Rancher and Fleet reconciliation. This flow does not inspect, patch, or retry
Fleet HelmOps.

Storage is an AIFLab platform prerequisite rather than a Kubeflow component.
The general deploy wrapper reuses the cluster's single default StorageClass. If
none exists, it first installs the demo-only bundle under
`aiflab/platform/local-storage`; k3s and clusters with an organizational default
are left unchanged.

## Prerequisites

- Rancher and SUSE AI Factory are installed on the local cluster.
- `kubectl` can reach that cluster.
- AI Factory Settings contain working Application Collection credentials.
- The cluster has exactly one default StorageClass, or the deployment is run
  through `aiflab/deploy.sh` so its platform fallback can create one.
- Application Collection credentials are the only required commercial
  credentials for this demo. Optional registry credentials can still be
  configured when a particular environment requires authenticated image pulls.
- The cluster can reach the pinned GitHub release, Application Collection, and
  all required image registries.
- A prebuilt `aifctl`, or Go 1.25 and `make` to build the checkout's client.

The deploy host needs Kubernetes access; it does not download or build the
Kubeflow chart. The in-cluster bootstrap downloads charts only. It does not
mirror container images or make Application Collection available offline.

## Deploy

Install/configure the base as needed and pass the bundle to `aifctl` through the
general AIFLab wrapper:

```bash
./aiflab/deploy.sh --skip-base \
  --env-file ~/.config/aiflab/credentials.env \
  --from aiflab/demos/kubeflow \
  --timeout 45m
```

Omit `--env-file` when the required credentials are already configured. To
install the base stack in the same flow, omit `--skip-base`.

Application Collection credentials are platform-scoped, not Kubeflow inputs.
The command configures them in AI Factory Settings before deployment; later
Blueprints can reuse them. `aifctl` does not accept credentials on its command
line. Before applying the first package object, it verifies that the external
`ClusterRepo/application-collection` exists and is ready. If the credential is
missing, invalid, or not yet reconciled, deployment stops with the setup command
instead of creating a partially installed Kubeflow demo.

There is no Kubeflow-specific path in `deploy.sh`. With the base, credentials,
and a default StorageClass already configured, invoking the same generic client
directly is equivalent:

```bash
./aiflab/aifctl/bin/aifctl blueprint deploy \
  --from aiflab/demos/kubeflow \
  --timeout 45m
```

The same pinned bundle may be rerun unchanged. Blueprint name/version pairs are
immutable, so `aifctl` adds a stable domain-derived suffix to this demo's
`0.3.0` version. The same domain is idempotent; if the discovered node IP
changes, a new configuration revision is created and the AIWorkload moves to
it without rewriting the old Blueprint. Other component or value changes still
require increasing the authored base version.

Check public AI Factory status and workload pods with:

```bash
kubectl -n aiflab-kubeflow get aiworkloads
kubectl -n kubeflow get pods
```

The first deployment pulls many large images and can take several minutes.
Fleet may retry Helm hooks during that cold start, and AI Factory can briefly
publish `Failed` before returning to `Pending`. `aifctl` tolerates that phase
for 30 seconds while Fleet owns the retry. A continuous failure remains an
error; inspect its status and the referenced Rancher/Fleet diagnostics. AIFLab
does not force a Fleet resync or hide a sustained failed reconciliation.

## Why The Chart Is Hydrated

Kubeflow Model Registry shares Pipelines' MariaDB. Model Catalog separately
requires PostgreSQL. The official Kubeflow `0.3.2` archive declares
Application Collection PostgreSQL `0.5.5` but does not contain its nested tgz.

The bootstrap pod verifies both pinned downloads, adds exactly that missing
package, checks the dependency tree, and indexes the new bytes with a new
digest. It does not change PostgreSQL or Kubeflow templates and does not push
the result to a persistent registry. The hydrated archive is nevertheless
different from the published archive and should be described as such.

Do not also deploy PostgreSQL as a separate AIWorkload. The hydrated Kubeflow
release creates and owns the `model-catalog-postgres` Service, Secret,
StatefulSet, and storage.

The Blueprint seeds Model Catalog with a small public Hugging Face source list.
For authenticated or gated models, create
`Secret/model-catalog-hf-secret` in `kubeflow` with key `HF_API_KEY` before the
main Blueprint is deployed.

## Access

For packages that request a domain, `aifctl` prefers a Kubernetes node
`ExternalIP`, falls back to its `InternalIP`, and derives
`<node-ip>.sslip.io`. Kubeflow uses that one base domain for the dashboard,
Knative, and KServe. Its wildcard gateway routes the dashboard and generated
serving hostnames. The self-signed wildcard certificate exactly covers the
dashboard and one-label hosts; see the Serverless hostname limitation below.

After a successful deployment, `aifctl` reads the allocated HTTPS NodePort and
prints the complete browser URL:

```text
Resolved deployment domain 192.168.122.227.sslip.io (node InternalIP)
Access URL: https://kubeflow.192.168.122.227.sslip.io:<https-node-port>
```

The NodePort is allocated separately for every cluster. Always use the URL
printed by the current deployment instead of reusing one from a destroyed
cluster. An automatically selected `InternalIP` must also be reachable from
the browser's network; `--domain` changes DNS naming, not network routing.

Accept the demo's self-signed certificate and sign in with:

```text
Email: user@example.com
Password: 12341234
```

Set a real or preconfigured base domain explicitly when needed; it must resolve
to an address that reaches the Istio gateway:

```bash
./aiflab/deploy.sh --skip-base \
  --from aiflab/demos/kubeflow \
  --domain lab.example.com \
  --timeout 45m
```

The direct client accepts the same `--domain` flag. `AIFLAB_DOMAIN` is the
environment-variable equivalent, with an explicit flag taking precedence.

These credentials, self-signed TLS, demo storage, and reduced resource requests
are intentionally unsuitable for production.

## Known Limitations

- The flow is pinned to Kubeflow `0.3.2` and PostgreSQL `0.5.5`; changing either
  requires reviewing the dependency layout and creating a new demo revision.
- The cluster-local chart repository works only for the local target cluster.
- This is an online compatibility build, not an air-gap implementation.
- A missing or invalid repository cache requires the cluster to reach both
  pinned chart sources again.
- No automatic rollback, migration, Fleet patch, or AIFLab-initiated retry is
  provided. The client only tolerates a brief `Failed` phase while AI Factory
  and Fleet perform their own reconciliation.
- Knative and Serverless KServe use `<service>.<namespace>.<domain>`. The
  gateway routes those two-label hosts, but the demo certificate contains only
  `*.<domain>`, so strict TLS hostname verification fails for them. The
  dashboard hostname is covered correctly. This demo already requires users
  to accept self-signed TLS; a real deployment should issue a certificate for
  its chosen serving-domain layout.
- With this pinned KServe/Istio/OAuth combination, an InferenceService's
  top-level `.status.url` can rewrite the OAuth redirect to its cluster-local
  predictor name. Use `.status.components.predictor.url` for the externally
  reachable Serverless check, as shown below. A production integration should
  resolve the gateway authentication and Host-rewrite behavior explicitly.
- Kubeflow, KServe, Katib, Knative, and training controllers update generated
  webhook CA bundles and certificate Secrets after Helm renders them. Fleet can
  consequently report those resources as `Modified` after a successful
  install even while AI Factory is `Running` and every workload is Ready. This
  demo records that upstream runtime drift; it does not patch or force Fleet.
- The Istio chart creates
  `MutatingWebhookConfiguration/istio-sidecar-injector` as a Helm hook. It can
  remain outside normal release ownership and appear as drift after a failed or
  repeated install. Cleanup removes it because this demo assumes dedicated
  Istio resources.

## Host Limits

Kubeflow may exceed default inotify limits. Run the warning-only check on every
eligible Kubernetes node:

```bash
aiflab/demos/kubeflow/host-preflight.sh --print-settings
```

The script prints a copyable `sysctl` command for low settings but never changes
the host.

## Optional KServe Check

This creates a tiny Serverless predictor, exercising both KServe and Knative:

```bash
kubectl apply -f aiflab/demos/kubeflow/examples/kserve-http-check.yaml
kubectl -n kubeflow-user-example-com wait \
  --for=condition=Ready inferenceservice/aiflab-kserve-check --timeout=10m
kubectl -n kubeflow-user-example-com get \
  inferenceservice/aiflab-kserve-check \
  -o jsonpath='{.status.components.predictor.url}{"\n"}'
```

## Optional Notebook Storage Check

This lightweight Notebook and class-less workspace claim prove that user
workloads consume the platform default rather than a demo-specific class:

```bash
kubectl apply -f aiflab/demos/kubeflow/examples/notebook-storage-check.yaml
kubectl -n kubeflow-user-example-com wait \
  --for=condition=Ready pod/aiflab-storage-check-0 --timeout=10m
kubectl -n kubeflow-user-example-com get \
  pvc/aiflab-notebook-storage-check
```

## Cleanup

```bash
aiflab/demos/kubeflow/cleanup.sh
```

Cleanup deletes the main workload before the prerequisites so its chart
repository remains reachable during uninstall. It then removes the hydrated
ClusterRepo, Blueprint definitions, dedicated namespaces, repository cache,
and other demo data. Shared platform storage is retained. Cleanup is destructive
and must not be used when those namespaces or Istio resources are shared.
Cluster-scoped CRDs retained by upstream charts are outside this cleanup.

Cleanup does not remove Application Collection or other AI Factory platform
credentials, Settings references, or shared repository authentication. Those
are intentionally retained for other and future Blueprints. Credential removal
is a separate platform-administration action, not part of Blueprint cleanup.
