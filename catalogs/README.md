# Custom Blueprint Catalogs

AI Factory already supports custom catalogs. These examples target the lab's
AI Factory `2.4.0` installation and use its upstream Kubernetes resources:

| Resource | Purpose |
| --- | --- |
| `BlueprintCatalog` | Catalog branding and membership in the Blueprints UI. |
| `Blueprint` | A versioned definition of Helm components and their values. |
| `Settings.spec.blueprintCatalogs` | Optional Git sources that the operator synchronizes through Fleet. |
| `AIWorkload` | An explicit request to install a Blueprint. |

Upstream references:

- [Adding blueprint catalogs, section 3.8](https://documentation.suse.com/suse-ai-factory/latest/html/AI-Factory-deployment/ai-factory-post-deployment.html).
- [Registering local Blueprint files](https://documentation.suse.com/suse-ai-factory/latest/html/AI-Factory-bp-creating/aif-bp-creating-publish-run.html).
- [Partner repository layout and contribution template](https://github.com/suse/partner-blueprints).
- [BlueprintCatalog schema and family-based membership](https://github.com/SUSE/aif/blob/main/operator/api/v1alpha1/catalog_types.go).

## Register From A Local Directory

From the AIFLab checkout:

```bash
source scripts/common.sh
kubectl apply --dry-run=server -k catalogs/example
kubectl apply -k catalogs/example
kubectl get blueprintcatalogs.ai-factory.suse.com aiflab-examples
kubectl get blueprints.ai-factory.suse.com aiflab-example-ollama-0-1-0
```

The directory contains a `BlueprintCatalog`, an Ollama `Blueprint`, and a
`kustomization.yaml` listing both files. This registers **AIFLab Example Catalog**
on **SUSE AI Factory > Blueprints**. Select it in the catalog filter.
Registration creates no AIWorkload and installs no application pods. The Ollama
chart version is pinned to `1.95.0`, verified in Application Collection on
2026-11-05; installing it requires the platform's Application Collection
credentials and suitable chart values for your cluster.

For plain YAML without Kustomize, the equivalent is:

```bash
kubectl apply -f catalogs/example/catalog.yaml
kubectl apply -f catalogs/example/blueprints/
```

Edit the files and reapply to update them. A local directory is imported when
you run the command; it is not watched. Use `kubectl apply -k`, rather than
`kubectl apply -f` on the example root, because `kustomization.yaml` is a build
configuration. A catalog-only import also does not use `deploy.sh --from`:
that deployment flow requires an AIWorkload and prepares demo storage.

## Synchronize Your Own Git Repository

Commit the example directory to a Git repository accessible from the cluster.
The same directory works with Fleet, which recognizes its
[`kustomization.yaml`](https://fleet.rancher.io/explanations/gitrepo-content).

Copy `git/settings.example.yaml` to your own configuration file and edit:

- `repoURL`: your HTTPS Git URL;
- `branch`: the branch to follow;
- `paths`: directories relative to that repository's root;
- `namespace`: your operator namespace, if it differs from `aif-operator`.

Keep this Settings file outside the synchronized paths. Include both the
catalog and its Blueprints inside those paths. Then apply your configuration:

```bash
kubectl apply --server-side --field-manager=aiflab-catalogs \
  -f /path/to/my-catalog-settings.yaml
kubectl -n fleet-local get gitrepo blueprint-catalog-aiflab-examples
kubectl -n fleet-local describe gitrepo blueprint-catalog-aiflab-examples
```

The partial Settings manifest adds catalog entries by name and leaves platform
credential fields intact. Use additional entries for additional repositories.
The operator creates a Fleet GitRepo for each entry; Fleet applies updates
from Git and removes synchronized resources that are removed from Git.

You can also enter the same URL, branch, and paths in **SUSE AI Factory >
Settings > Blueprint Catalogs > Custom Catalogs > Add Catalog**. Upstream also
accepts `blueprintCatalogs` as operator Helm values; that makes those entries
Helm-managed. The upstream section 3.8 documents its list replacement and
server-side apply requirements when combining Helm and UI configuration.

Choose local apply or Git synchronization as the owner of a given catalog and
Blueprint set. When moving an existing local example to Git, remove its local
registrations before enabling Fleet so Fleet can create and own the resources.
Use unique catalog and Blueprint names for separate sources. The built-in
SUSE partner catalog already synchronizes `suse/partner-blueprints`.

## Private Git And Custom Charts

For private HTTPS Git, set `username` and `credSecretRef` in the Settings
example. The referenced Secret must exist in the operator namespace and contain
the selected token/password key. An existing Secret's `username` key can supply
the account name instead of the explicit field. For a private CA, set
`caBundleSecretRef` to a Secret/key containing the PEM CA bundle. Git catalog
synchronization supports HTTPS, not SSH or a workstation `file://` URL.

A Blueprint component's `chartRepo` names a Rancher **ClusterRepo**. It is
separate from the Git repository containing the catalog. The chart itself must
be accessible through a configured Helm, OCI, or Git chart repository; a local
chart directory cannot be used as `chartRepo`. Add a custom chart source in
**Settings > Repositories**, then use its name in your component. Upstream
[section 3.7](https://documentation.suse.com/suse-ai-factory/latest/html/AI-Factory-deployment/ai-factory-post-deployment.html)
documents those repository types, credentials, and CA references.

For additional Kubernetes manifests, list them in `kustomization.yaml` or apply
them explicitly. Both local apply and Fleet will apply listed resources, so
include workload resources only when you intend to deploy them as part of
registration.

## Author And Run Your Blueprints

Copy `example/` and change the catalog name, display name, and membership list.
For every Blueprint family, keep these values aligned:

- `metadata.labels[ai-factory.suse.com/blueprint-name]`: the family ID;
- `BlueprintCatalog.spec.blueprints[].name`: the same family ID;
- `metadata.name`: `<family>-<version>` with version dots replaced by hyphens;
- the version label and `spec.version`: the same SemVer value.

Add every new Blueprint file to `kustomization.yaml`. Catalog membership uses
the family ID, so additional versions remain in the same catalog. The example
sets `spec.source: Partner`, an author-declared badge supported since 2.3.0.
Use `Custom` for your internal custom Blueprints. See the existing
[Blueprint authoring guide](../demos/docs/blueprints.md) for components and
AIWorkload examples.

To run a registered Blueprint, select it in **Blueprints**, choose **Install**,
and select the namespace and target cluster. That creates the AIWorkload that
deploys its components. Review storage, model downloads, and resource settings
before installing the example's chart defaults.

## Remove A Catalog

For a catalog managed from the local example directory:

```bash
kubectl delete -k catalogs/example
```

For a Git catalog, remove its entry in **Settings > Blueprint Catalogs** and
select **Apply**. This removes its Fleet GitRepo and synchronized definitions.
Remove the entry from your local Settings configuration as well before the
next apply. Keep the shared Settings resource, which also stores platform
configuration and credential references. Delete any AIWorkload separately when
you intend to remove its running application.
