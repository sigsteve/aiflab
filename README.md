# AIFLab

AIFLab is experimental automation for installing a local SUSE AI Factory
environment and sharing reproducible Blueprint demonstrations. It is reference
material, not a supported deployment or lifecycle product.

The base flow installs:

- host dependencies;
- a local RKE2 or k3s Kubernetes runtime;
- cert-manager and Rancher;
- the SUSE AI Factory operator and UI extension.

Blueprint deployments use the experimental `aifctl` client so a plain YAML and
a demonstration with ordered dependencies follow the same path.

## Layout

- `deploy.sh`: installs the base and optionally passes `--from` to `aifctl`.
- `scripts/`: individual base-install steps and shared shell helpers.
- `platform/`: shared demo infrastructure installed through AI Factory.
- `demos/kubeflow/`: structured, ordered Kubeflow deployment bundle.
- `tests/`: host-side regression tests.
- `aifctl/`: self-contained source, tests, and build for the experimental
  AIFLab client.

## Quick Start

Install the base, configure credentials, and deploy Kubeflow with one command:

```bash
./aiflab/deploy.sh \
  --env-file ~/.config/aiflab/credentials.env \
  --from aiflab/demos/kubeflow \
  --timeout 45m
```

When Rancher and AI Factory are already installed but credentials have not yet
been configured:

```bash
./aiflab/deploy.sh --skip-base \
  --env-file ~/.config/aiflab/credentials.env \
  --from aiflab/demos/kubeflow \
  --timeout 45m
```

Only after the required platform credentials are ready may later deployments
omit `--env-file` and reuse them:

```bash
./aiflab/deploy.sh --skip-base \
  --from aiflab/demos/kubeflow \
  --timeout 45m
```

`deploy.sh` finds `aifctl` on `PATH` or at `aiflab/aifctl/bin/aifctl`. In a
development checkout it can also build that AIFLab-local binary when Go and
`make` are available. The base dependency step installs those build tools on
the supported SUSE lab host before the client is needed. Set `AIFCTL_BIN` to
select another binary explicitly.

`deploy.sh` has no Kubeflow-specific behavior. It installs/configures the base
when requested, then invokes the same `aifctl` command shown below. Kubeflow's
chart hydration runs inside its prerequisite AIWorkload, not on the deploy
host.

Before any `--from` deployment, the wrapper checks for exactly one default
StorageClass. It reuses an existing cluster default, including k3s local-path or
an organizational CSI class. Stock RKE2 has no default, so the wrapper installs
the demo-only `platform/local-storage` Blueprint from Application Collection.
That node-local fallback is shared by demos and remains when a demo is removed.

## Base Installation Only

```bash
./aiflab/deploy.sh
```

A bare install deliberately creates no credentials and deploys no Blueprint.
Its completion output says so and prints the credential setup command. Existing
credentials are preserved if the base command is rerun; AIFLab never discovers
or loads a credential file implicitly. Rerun `./aiflab/deploy.sh --skip-base`
at any time for a value-free status of all three credential groups and their
repository readiness.

The scripts call `sudo` for privileged operations. Running them through `sudo`
also works; `scripts/common.sh` targets the invoking user's kubeconfig rather
than `/root/.kube/config`.

Run individual steps when diagnosing the base installation:

```bash
aiflab/scripts/00-install-runtime-deps.sh
aiflab/scripts/01-install-runtime.sh
aiflab/scripts/02-install-rancher-deps.sh
aiflab/scripts/03-install-rancher.sh
aiflab/scripts/04-install-aif-operator.sh
aiflab/scripts/05-configure-aif-credentials.sh --env-file /secure/aiflab.env
```

## AI Factory Credentials

Credentials belong to the AI Factory installation, not to Kubeflow or any
other Blueprint. Configure each group once, then reuse it for every compatible
Blueprint deployed to this installation:

| Credential group | Used by | Required when |
| --- | --- | --- |
| Application Collection | `ClusterRepo/application-collection`, chart downloads, and derived workload pull credentials | A component uses `chartRepo: application-collection`; this includes AIFLab local storage and Kubeflow |
| SUSE Registry | `ClusterRepo/suse-ai-registry` and derived SUSE image-pull credentials | A selected Blueprint uses protected SUSE Registry content |
| NVIDIA | NVIDIA chart repositories plus derived `ngc-secret` and `ngc-api` workload credentials | A selected NVIDIA/NGC path uses protected charts, images, or APIs |

Public upstream Blueprints need none of these merely because their vendor is
SUSE. The Blueprint documentation must identify any protected image or API that
cannot be inferred from its `chartRepo`.

Keep credentials outside the repository in a mode-`600` file:

```bash
install -d -m 700 ~/.config/aiflab
install -m 600 aiflab/credentials.env.example \
  ~/.config/aiflab/credentials.env
# Edit the copied file, then configure the existing environment:
./aiflab/deploy.sh --skip-base \
  --env-file ~/.config/aiflab/credentials.env
```

Supported literal assignments are:

```dotenv
AIF_APPLICATION_COLLECTION_USERNAME=<username>
AIF_APPLICATION_COLLECTION_TOKEN=<token>
AIF_SUSE_REGISTRY_USERNAME=<username>
AIF_SUSE_REGISTRY_TOKEN=<token>
AIF_NVIDIA_API_KEY=<api-key>
# AIF_NVIDIA_USERNAME=$oauthtoken
```

The parser accepts only these assignments, comments, and blank lines. It never
sources the file or expands shell syntax. Complete credential groups are
written to AI Factory's recognized Kubernetes Secrets; omitted existing groups
are left unchanged. Rerun the same command to rotate one or more groups.

AI Factory stores the source Secrets in `aif-operator`, references them from
`Settings/settings`, and reconciles the required Rancher/Fleet repository-auth
mirrors and workload pull-secret copies. Never put credentials in a Blueprint,
an `aifctl` flag, or a shell command line.

Deleting a Blueprint does not delete an AIWorkload, an application, or any
platform credential. Delete the AIWorkload to tear down its deployment.
Platform source credentials, Settings, ClusterRepos, and repository-auth
mirrors remain available to other Blueprints until a platform administrator
explicitly removes them.

Credential rotation is reconciled to active workloads. Complete revocation
requires more care: previously delivered namespace-local pull-secret objects
are not currently guaranteed to disappear as soon as the source credential is
removed. For deterministic revocation, first remove affected AIWorkloads, then
remove the platform credential and verify the derived Secrets and pull-secret
Bundles are gone.

Run its regression test without changing a cluster:

```bash
aiflab/tests/credential-env.sh
```

## Deploying Blueprints

The simple form is an ordinary multi-document YAML containing its Blueprint,
AIWorkload, and any required bootstrap resources:

```bash
./aiflab/aifctl/bin/aifctl blueprint deploy --from /path/to/example.yaml
```

For an ordered demonstration, pass a directory:

```text
example/
├── deps/                  # optional, *.yaml applied in lexical order
│   ├── 10-control-namespace.yaml
│   ├── 20-namespaces.yaml
│   ├── 30-platform.yaml
│   └── 40-chart-repository.yaml
├── blueprint.yaml         # required main deployment
└── post-deploy/           # optional idempotent Jobs
    └── 10-seed-demo.yaml
```

For every stage, `aifctl` applies the Kubernetes objects and waits for included
ClusterRepos, AIWorkloads, and Jobs before continuing. It does not build charts,
patch Fleet, perform rollback, or execute arbitrary host scripts.

Before the first write, `aifctl` scans packaged Blueprint components for
external `chartRepo` dependencies. Repositories supplied by the package are
handled by its ordered stages; every other referenced ClusterRepo must already
exist and report its current download ready. Missing Application Collection,
SUSE Registry, or NVIDIA repositories produce credential-specific setup
guidance and stop the deployment before any package object is applied.
Offline `--dry-run` prints these prerequisites without contacting Kubernetes.

This preflight validates chart repositories and NVIDIA-vendored component
requirements. It cannot reliably infer arbitrary protected image registries or
API keys hidden inside opaque Helm values. Authors must document those inputs.
Using raw `kubectl apply` bypasses the AIFLab preflight, so missing prerequisites
may instead surface later in AIWorkload, Helm, or image-pull status.

AIWorkload readiness follows AI Factory's top-level phase. AI Factory can
briefly publish a top-level `Failed` phase while Fleet starts an automatic
retry, so `aifctl` allows 30 seconds for that phase to recover. A transition
back to `Pending` or `Degraded` resets the grace period; a continuous failure
still returns its error, and the explicit deployment timeout remains the
overall limit.

The Kubeflow bundle uses that normal ordering to build its compatibility chart
inside the cluster. Its bootstrap AIWorkload owns a chart-repository pod whose
init containers fetch SHA-pinned Kubeflow `0.3.2` and Application Collection
PostgreSQL `0.5.5`, cache the verified hydrated archive on demo-local storage,
then serve it. The next stage creates and waits for
`ClusterRepo/aiflab-kubeflow-hydrated`; a domain-derived revision of the main
Kubeflow Blueprint `0.3.0` follows. The cluster therefore needs GitHub,
Application Collection, and workload-image access for a first build. This is
not an air-gap workflow.

Preview a bundle without contacting the cluster:

```bash
./aiflab/aifctl/bin/aifctl blueprint deploy \
  --from aiflab/demos/kubeflow --dry-run
```

See [the Kubeflow README](./demos/kubeflow/README.md) for the exact stages,
pinned hydration inputs, limitations, access, and cleanup.

## Current Cluster

After installing the runtime, source the shared environment in each new shell:

```bash
source aiflab/scripts/common.sh
kubectl get pods -A
```

Rancher is available at the URL printed by `03-install-rancher.sh`, normally
`https://<host-ip>.sslip.io`. The local demo bootstrap login defaults to:

```text
Username: admin
Password: password
```

## Runtime Selection

RKE2 is the default. Select k3s before running the base installation:

```bash
export INSTALL_RUNTIME=k3s
./aiflab/deploy.sh
```

## Useful Base Overrides

- `KUBECONFIG_PATH`: destination kubeconfig path. Defaults to
  `~/.kube/config`, including the invoking user's home under `sudo`.
- `RUNTIME_READY_TIMEOUT`: Kubernetes node-readiness timeout. Default `300s`.
- `RANCHER_HOSTNAME`: Rancher hostname. Default `<host-ip>.sslip.io`.
- `RANCHER_BOOTSTRAP_PASSWORD`: local bootstrap password. Default `password`.
- `RANCHER_BOOTSTRAP_COMPLETE`: complete first-login setup automatically.
  Default `true`.
- `RANCHER_HELM_REPO_CHANNEL`: Rancher chart channel. Default `stable`.
- `RANCHER_CHART_VERSION`: optional Rancher chart version pin.
- `RANCHER_INGRESS_CLASS`: optional ingress class override.
- `RANCHER_INGRESS_READY_TIMEOUT`: ingress readiness timeout. Default `300`.
- `AIF_CHART_VERSION`: AI Factory operator chart version. Default `2.0.1`.
- `AIF_CREDENTIALS_TIMEOUT_SECONDS`: Settings and repository timeout. Default
  `300`.

## Recovering A Stale Kubeconfig

If `kubectl` reports an unknown certificate authority after reinstalling RKE2,
refresh the user kubeconfig:

```bash
aiflab/scripts/01-install-runtime.sh
source aiflab/scripts/common.sh
kubectl get pods -A
```


## Demos

### Deploy base

[![deployment demo](https://asciinema.org/a/CSd3sKKXZ7xeDFzR.svg)](https://asciinema.org/a/CSd3sKKXZ7xeDFzR)

### Add creds

[![add creds demo](https://asciinema.org/a/0ZcuaQLrW4FgSHQE.svg)](https://asciinema.org/a/0ZcuaQLrW4FgSHQE)

### Deploy the kubeflow demo

[![kubeflow demo](https://asciinema.org/a/f0EpIL8LZcQRKhiI.svg)](https://asciinema.org/a/f0EpIL8LZcQRKhiI)
