# NemoClaw Blueprint Notes

## What I Found

`NemoClaw` exists in public GTC 2026 reporting as NVIDIA's OpenClaw-oriented
security and privacy stack. Reports describe it as an open-source stack that adds
privacy and security controls to OpenClaw, including a network guardrail and
privacy router.

I did not find a public NVIDIA Helm chart named `nemoclaw`, `nemo-claw`, or
`openclaw` in these NVIDIA Helm indexes:

- `https://helm.ngc.nvidia.com/nvidia/index.yaml`
- `https://helm.ngc.nvidia.com/nvidia/blueprint/index.yaml`
- `https://helm.ngc.nvidia.com/nim/index.yaml`

The public NVIDIA blueprint repo does expose AI-Q charts. The closest deployable
reference artifact I found is:

```text
repo:    https://helm.ngc.nvidia.com/nvidia/blueprint
chart:   aiq2-web
version: 2.1.0
images:  nvcr.io/nvidia/blueprint/aiq-agent:2.1.0
         nvcr.io/nvidia/blueprint/aiq-frontend:2.1.0
```

The sample Blueprint at
`aiflab/demos/blueprints/blueprint-nemoclaw-reference.yaml` uses that NVIDIA AI-Q
WEB profile as a NemoClaw reference deployment. It is intentionally named
`NemoClaw Reference` rather than `NemoClaw` because the chart itself is not named
NemoClaw.

## Why AI-Q

The `aiq2-web` chart is in NVIDIA's `nvidia/blueprint` Helm repository and is
described by its chart metadata as `AI-Q - WEB Profile`. The packaged chart
deploys:

- AI-Q backend
- AI-Q frontend
- PostgreSQL

The chart README requires an `aiq-credentials` Secret with:

- `DB_USER_NAME`
- `DB_USER_PASSWORD`
- `NVIDIA_API_KEY`
- `TAVILY_API_KEY`

It also documents NGC image pulls from:

- `nvcr.io/nvidia/blueprint/aiq-agent`
- `nvcr.io/nvidia/blueprint/aiq-frontend`

## Prerequisites

Before applying the sample for real:

1. Create a valid NGC image pull secret named `ngc-secret` in the
   `nemoclaw-reference` namespace.
2. Replace the placeholder values in `Secret/aiq-credentials`.
3. Confirm the NVIDIA blueprint ClusterRepo downloads successfully.

Example image pull secret:

```bash
kubectl create secret docker-registry ngc-secret \
  -n nemoclaw-reference \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="$NVIDIA_API_KEY"
```

The current test cluster does not have NVIDIA credentials configured, so this
sample is not applied by default.

## Apply

```bash
kubectl apply -f aiflab/demos/blueprints/blueprint-nemoclaw-reference.yaml
```

Watch status:

```bash
kubectl get clusterrepo nvidia-blueprint
kubectl get aiworkload nemoclaw-reference -n nemoclaw-reference
kubectl get helmop,bundle,bundledeployment -A | grep nemoclaw
kubectl get pods,svc -n nemoclaw-reference
```

Port-forward the UI after the frontend is ready:

```bash
kubectl -n nemoclaw-reference port-forward svc/aiq-frontend 3000:3000
```

## If NVIDIA Publishes A NemoClaw Chart

If NVIDIA later publishes a concrete NemoClaw chart, update the Blueprint
component only:

```yaml
components:
- chartRepo: nvidia-blueprint
  chartName: <published-nemoclaw-chart-name>
  chartVersion: <published-version>
  values: {}
```

Keep the `NemoClaw Reference` sample separate from any future production
`NemoClaw` Blueprint so QA can distinguish the reference deployment from a real
product chart.

## Sources Checked

- Business Insider: NVIDIA announced NemoClaw at GTC 2026 as an OpenClaw
  security/privacy stack.
- TechRadar: NemoClaw described as adding security and privacy tools, including
  OpenShell, with a single-command install story.
- NVIDIA public Helm repo: `https://helm.ngc.nvidia.com/nvidia/index.yaml`
- NVIDIA public blueprint Helm repo:
  `https://helm.ngc.nvidia.com/nvidia/blueprint/index.yaml`
- NVIDIA public NIM Helm repo: `https://helm.ngc.nvidia.com/nim/index.yaml`
