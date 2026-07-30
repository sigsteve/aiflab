# Blueprint Authoring Guide

Blueprints are reusable, versioned definitions for installing one or more Helm
charts through SUSE AI Factory. A Blueprint does not deploy anything by
itself. A namespaced `AIWorkload` installs one Blueprint version into one target
namespace and one or more target clusters.

## Where The Spec Lives

The Blueprint API is defined in:

- `operator/api/v1alpha1/blueprint_types.go` - source of truth for the Go API type.
- `operator/config/crd/bases/ai-factory.suse.com_blueprints.yaml` - generated operator CRD.
- `charts/aif-operator/crds/ai-factory.suse.com_blueprints.yaml` - generated Helm chart CRD.
- `ui/pkg/aif-ui/types/blueprint-types.ts` - UI TypeScript mirror.

Blueprint installation is handled by:

- `operator/internal/controller/aiworkload/blueprint.go`
- `operator/api/v1alpha1/aiworkload_types.go`

## Resource Model

A complete kubectl-applied example usually contains these resources:

1. `ClusterRepo`

   Rancher catalog repo containing the Helm chart or charts referenced by the
   Blueprint.

2. `Blueprint`

   Cluster-scoped, versioned chart stack definition.

3. `Namespace`

   Namespace where the `AIWorkload` CR lives. In simple examples this is also
   the Helm release target namespace.

4. `AIWorkload`

   Namespaced install request that points at a Blueprint family and version.

## Blueprint Spec

`Blueprint` is cluster-scoped:

```yaml
apiVersion: ai-factory.suse.com/v1alpha1
kind: Blueprint
metadata:
  name: <family-slug>-<version-name>
  labels:
    ai-factory.suse.com/blueprint-name: <family-slug>
    ai-factory.suse.com/blueprint-version: <semver>
spec:
  displayName: <human readable family name>
  version: <semver>
  description: <optional description>
  deprecated: false
  components:
  - chartRepo: <clusterrepo-name>
    chartName: <helm-chart-name>
    chartVersion: <helm-chart-version>
    values: {}
```

### Metadata

| Field | Required | Notes |
| --- | --- | --- |
| `metadata.name` | Yes | Use `<family-slug>-<version-name>`. Example: `open-webui-ollama-0-1-0`. |
| `metadata.labels["ai-factory.suse.com/blueprint-name"]` | Yes for UI and conventions | Family slug used to group Blueprint versions. |
| `metadata.labels["ai-factory.suse.com/blueprint-version"]` | Yes for UI and conventions | Full SemVer value from `spec.version`. |

The family slug convention is:

1. Lowercase the display name.
2. Replace each run of non-`[a-z0-9]` characters with `-`.
3. Trim leading and trailing `-`.

The version name convention is:

1. Start with `spec.version`.
2. Strip build metadata beginning at `+`.
3. Replace `.` with `-`.

Examples:

| Display name | Version | Family slug | `metadata.name` |
| --- | --- | --- | --- |
| `Open WebUI + Ollama` | `0.1.0` | `open-webui-ollama` | `open-webui-ollama-0-1-0` |
| `NGINX` | `0.1.0` | `nginx` | `nginx-0-1-0` |
| `RAG Chatbot` | `1.2.0+build.4` | `rag-chatbot` | `rag-chatbot-1-2-0` |

The controller resolves an `AIWorkload` Blueprint source by deriving the
Blueprint CR name from `source.blueprint.name` and `source.blueprint.version`, so
the names must follow the same convention.

### `spec`

| Field | Required | Validation | Notes |
| --- | --- | --- | --- |
| `displayName` | Yes | Non-empty string | Human-readable name shown in the UI. Versions in the same family should use the same display name. |
| `version` | Yes | SemVer pattern | Full SemVer is allowed, including prerelease and build metadata. |
| `description` | No | String | Short description of what the Blueprint deploys. |
| `deprecated` | No | Boolean | Marks this Blueprint version as deprecated. |
| `components` | Yes | At least one item | Each item is one Helm chart. |

### `spec.components[]`

| Field | Required | Validation | Notes |
| --- | --- | --- | --- |
| `chartRepo` | Yes | Non-empty string | Name of a Rancher `ClusterRepo`. This is not a URL. |
| `chartName` | Yes | Non-empty string | Helm chart name in the repo. |
| `chartVersion` | Yes | Non-empty string | Helm chart version. |
| `values` | No | Arbitrary JSON/YAML object | Helm values passed to this component. Unknown fields are preserved by the CRD. |

For HTTP Helm repos, the controller passes `repo`, `chart`, and `version` to
Fleet. For OCI repos, the controller appends `/<chartName>` to the repo URL and
passes the result as the Fleet Helm repo.

## ClusterRepo Prerequisite

Every `components[].chartRepo` must match a Rancher `ClusterRepo` name.

HTTP Helm repo:

```yaml
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: open-webui
spec:
  url: https://helm.openwebui.com
```

OCI Helm repo:

```yaml
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: application-collection
spec:
  url: oci://dp.apps.rancher.io/charts
```

If the repo requires credentials, configure the Rancher `ClusterRepo`
credentials first. Missing credentials leave the repo or Fleet Helm operation in
an authentication error state.

## Installing A Blueprint With AIWorkload

Use `AIWorkload.spec.source.sourceType: Blueprint`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: open-webui-ollama
---
apiVersion: ai-factory.suse.com/v1alpha1
kind: AIWorkload
metadata:
  name: open-webui-ollama
  namespace: open-webui-ollama
spec:
  displayName: Open WebUI + Ollama
  deployStrategy: FleetBundle
  source:
    sourceType: Blueprint
    blueprint:
      name: open-webui-ollama
      version: 0.1.0
  targetNamespace: open-webui-ollama
  targetClusters:
  - local
```

Important fields:

| Field | Required | Notes |
| --- | --- | --- |
| `metadata.namespace` | Yes | Namespace that stores the `AIWorkload` CR. |
| `spec.displayName` | Yes | Human-readable install name. |
| `spec.deployStrategy` | Yes for predictable behavior | Use `FleetBundle` for kubectl-applied examples. `GitOps` is supported when Git settings are configured. Blueprint-sourced `Helm` installs are not implemented today. |
| `spec.source.blueprint.name` | Yes | Blueprint family slug. |
| `spec.source.blueprint.version` | Yes | Blueprint SemVer version. |
| `spec.targetNamespace` | Yes | Namespace where Helm releases are installed on target clusters. |
| `spec.targetClusters` | Yes for Fleet/GitOps installs | Use `local` for the local cluster. Use Rancher cluster IDs for downstream clusters. |
| `spec.fleetBundleNames` | No | Controller-owned. Do not set it in author-authored YAML. |
| `spec.componentValues` | No | Do not rely on this for Blueprint-sourced installs yet. Put default values in `Blueprint.spec.components[].values`. |

## Authoring Checklist

1. Choose the Blueprint family name and SemVer version.

   Example:

   ```text
   displayName: Open WebUI + Ollama
   family slug: open-webui-ollama
   version: 0.1.0
   metadata.name: open-webui-ollama-0-1-0
   ```

2. Confirm each chart is available in a `ClusterRepo`.

   ```bash
   kubectl get clusterrepo
   kubectl get clusterrepo <repo-name> -o yaml
   ```

3. Create one `Blueprint` component per chart.

   Each component becomes one Fleet Helm bundle when installed through an
   `AIWorkload`.

4. Put chart defaults in `components[].values`.

   These are Helm values, exactly as you would pass them to the chart. Prefer
   explicit values that make the example reproducible: disable optional ingress,
   persistence, GPU, model pulls, or external services unless the example needs
   them.

5. Watch for chart-generated name collisions.

   Fleet release names are derived from the workload namespace, workload name,
   and chart name. Charts with subcharts can still generate colliding Kubernetes
   object names if their helpers reuse the release name. Use chart values such as
   `fullnameOverride` or subchart-specific overrides when the upstream chart
   supports them.

6. Add an `AIWorkload` only when the file is intended to deploy immediately.

   Bundled chart defaults under `charts/aif-operator/files/blueprints/` should
   contain only the `Blueprint` CR. End-to-end examples under
   `aiflab/demos/blueprints/` can include `ClusterRepo`, `Blueprint`,
   `Namespace`, and `AIWorkload`.

## Complete Example

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nginx
---
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: bitnami
spec:
  url: https://charts.bitnami.com/bitnami
---
apiVersion: ai-factory.suse.com/v1alpha1
kind: Blueprint
metadata:
  name: nginx-0-1-0
  labels:
    ai-factory.suse.com/blueprint-name: nginx
    ai-factory.suse.com/blueprint-version: 0.1.0
spec:
  displayName: NGINX
  version: 0.1.0
  description: Deploys an NGINX web server.
  components:
  - chartRepo: bitnami
    chartName: nginx
    chartVersion: 25.0.8
    values:
      replicaCount: 1
      service:
        type: ClusterIP
      ingress:
        enabled: false
---
apiVersion: ai-factory.suse.com/v1alpha1
kind: AIWorkload
metadata:
  name: nginx
  namespace: nginx
spec:
  displayName: NGINX
  deployStrategy: FleetBundle
  source:
    sourceType: Blueprint
    blueprint:
      name: nginx
      version: 0.1.0
  targetNamespace: nginx
  targetClusters:
  - local
```

## Validation

Client-side validation catches basic YAML and API shape errors:

```bash
kubectl apply --dry-run=client -f aiflab/demos/blueprints/blueprint-nginx.yaml
```

Server-side validation checks the installed CRD schema:

```bash
kubectl apply --dry-run=server -f aiflab/demos/blueprints/blueprint-nginx.yaml
```

If a file creates a `Namespace` and an `AIWorkload` in that namespace in the same
apply, server-side dry-run may report that the namespace does not exist because
dry-run does not persist earlier documents. In that case either pre-create the
namespace for validation or validate the namespaced resource after the namespace
exists.

After applying:

```bash
kubectl get blueprints
kubectl get aiworkload -A
kubectl get helmop,bundle,bundledeployment -A
kubectl get pods,svc -n <target-namespace>
```

## Bundled Blueprints

Bundled defaults live under:

```text
charts/aif-operator/files/blueprints/
```

Rules for bundled files:

- One YAML file per Blueprint version.
- Exactly one YAML document per file.
- The file contains only a `Blueprint` CR.
- Do not include `ClusterRepo`, `Namespace`, or `AIWorkload`.
- Do not set `ai-factory.suse.com/source`; the Helm chart injects
  `ai-factory.suse.com/source: bundled`.

Validate bundled blueprint conventions from the repository root:

```bash
bash charts/aif-operator/tests/default-blueprints-convention.sh
bash charts/aif-operator/tests/default-blueprints-render.sh
```

## Troubleshooting

Blueprint does not appear in the UI:

- Confirm `metadata.labels["ai-factory.suse.com/blueprint-name"]` is set.
- Confirm `metadata.labels["ai-factory.suse.com/blueprint-version"]` matches `spec.version`.
- Confirm the Blueprint CR exists: `kubectl get blueprints`.

AIWorkload is `Failed` or stays `Pending`:

- Confirm the Blueprint name convention matches `spec.source.blueprint.name` and `version`.
- Confirm `targetClusters` includes at least one valid target such as `local`.
- Inspect Fleet status:

  ```bash
  kubectl get helmop,bundle,bundledeployment -A
  ```

Chart repo errors:

- Confirm `components[].chartRepo` matches an existing `ClusterRepo`.
- Confirm the `ClusterRepo` downloaded successfully:

  ```bash
  kubectl get clusterrepo <repo-name> -o yaml
  ```

Immutable field errors after editing chart values:

- Some chart values change immutable Kubernetes fields, such as Deployment
  selectors. Delete and recreate the `AIWorkload` or the target namespace for
  clean example verification.
