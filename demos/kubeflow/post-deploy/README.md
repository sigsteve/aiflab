# Optional Post-Deploy Jobs

Add ordered Kubernetes manifests such as `10-seed-model-catalog.yaml` here.
`aifctl blueprint deploy --from ...` applies them after the main Kubeflow
AIWorkload is `Running` and waits for every included `Job` to complete.

Jobs must be idempotent so rerunning the bundle is safe. Prefer calling an
upstream API over writing directly to an application's database.
