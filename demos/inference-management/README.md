# Inference management MVP

This demo is a deliberately small SUSE AI Factory proof of one inference and
observability path:

```text
client -> LiteLLM -> vLLM
            |          |
            + metrics  + metrics -> Prometheus -> Grafana
            |
            + OpenTelemetry spans -> Langfuse

NVIDIA DCGM metrics (optional) ----------------> Prometheus
Kubernetes workload health --------------------> Prometheus
```

The deployment is one multi-document manifest. It uses upstream charts rather
than a new umbrella chart and does not modify product source.

## What it installs

| Component | Pinned chart/image |
| --- | --- |
| vLLM production stack | chart `0.1.11`; CPU image `vllm/vllm-openai-cpu:v0.24.0-x86_64` |
| Prometheus and Grafana | embedded kube-prometheus-stack `82.4.3`; Prometheus `v3.10.0`; Grafana `12.4.0` |
| LiteLLM | chart/app `1.92.0`; image `ghcr.io/berriai/litellm:v1.92.0` |
| Langfuse | chart `1.5.39`; app images `3.212.0` |
| DCGM Exporter (optional; GPU nodes only) | chart `4.8.2`; image `4.5.3-4.8.2-distroless` |
| Test client | `curlimages/curl:8.21.0` |
| Default model | `HuggingFaceTB/SmolLM2-135M-Instruct` at revision `12fd25f77366fa6b3b4b768ec3050bf629380bac` |

The chart package hashes and LiteLLM OCI digest are recorded on the Blueprint.
Every installed workload image is tagged. The upstream LiteLLM chart also
contains two bare `busybox` Helm **test hooks**; Fleet does not execute those
hooks during install, so those images are not deployed.

## Before applying

Search for every exposed input:

```bash
rg -n 'INPUT:' aiflab/demos/inference-management/blueprint.yaml
```

At minimum, replace the `CHANGE_ME` credentials before exposing the deployment
beyond a trusted lab network or allowing untrusted clients. The checked-in
values exist only to preserve the one-apply demo workflow.

The CPU/public-image default does not require an AI Factory Application
Collection, SUSE Registry, or NVIDIA credential group. Its LiteLLM, vLLM,
Langfuse, Grafana, and test credentials are demo workload inputs in
`Secret/inference-management-secrets`, not shared platform credentials. The
optional GPU path requires NVIDIA platform credentials only if the selected
charts or images are protected NGC content.

The default profile is CPU-only because a GPU is not required to showcase the
inference and observability path. The DCGM chart is still recorded in the
Blueprint, but its DaemonSet schedules zero pods when no node has
`nvidia.com/gpu.present=true`; its Grafana panels stay empty and GPU assertions
are skipped. Persistent claims use the cluster's default StorageClass and need
several GiB of free space in addition to model cache. Do not install it on a crowded
control-plane node. The scanned lab node was already using roughly 79% of its
memory, so capacity should be checked before a live install.
The available `kubectl` client was also v1.20 against a v1.35 server; use a
current client within Kubernetes' supported version skew for the live apply.

The main inputs are:

- Namespace: change every `inference-management` occurrence together.
- Model: change `modelURL`, its immutable `--revision`, storage, and optional
  `HF_TOKEN`.
- Optional GPU profile: use `vllm/vllm-openai:v0.25.1`, set both runtime
  classes to `nvidia`, set `requestGPU` and test `GPU_COUNT` to the same nonzero
  count, and choose a GPU-compatible dtype. If GPU Operator already supplies DCGM
  Exporter, remove the DCGM component and adjust the DCGM ServiceMonitor to its
  existing Service labels/port.
- Endpoints and credentials: update the Secret, LiteLLM `api_base`, model
  alias, vLLM Service name, and matching URLs in the test Job together.
- Storage: the persistent components consume the cluster default. Use the
  AIFLab deploy wrapper to establish its shared demo fallback on stock RKE2.
- Ingress: the demo enables LiteLLM, Grafana, and Langfuse through nginx at
  `*.192.168.122.227.sslip.io`. Replace `192.168.122.227` in all four hostname/
  URL values when the ingress endpoint changes. These are deliberately HTTP
  endpoints; TLS requires certificates valid for the three names.
- Privacy: leave
  `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=no_content` to suppress
  prompts and responses, or set it to `span_only` to prove content capture.
- Test prompt: `TEST_PROMPT` is JSON-escaped by the Job before use.

If Prometheus Operator CRDs and a shared operator already exist, set both of
these values to `false` before applying:

```yaml
kube-prometheus-stack:
  crds:
    enabled: false
  prometheusOperator:
    enabled: false
```

The manifest will still create its own short-retention Prometheus and Grafana;
the shared operator must watch the `inference-management` namespace. This
avoids running competing operators and does not make the test deployment own
the shared monitoring release. On a cluster without those CRDs, retain the
default `true` values.

## Deploy and verify

Apply the one file:

```bash
kubectl apply -f aiflab/demos/inference-management/blueprint.yaml
```

The test Job is created immediately and waits for the four AI Factory Helm
components. Allow time for chart/image pulls and the first model download:

```bash
kubectl -n inference-management wait \
  --for=condition=complete job/inference-management-test-0-1-0 \
  --timeout=60m

kubectl -n inference-management logs job/inference-management-test-0-1-0
kubectl -n inference-management get configmap/inference-management-test-results -o yaml
```

The Job fails closed and records the failing stage in the results ConfigMap.
On success it has proved:

- Kubernetes, storage, Secret, Prometheus CRD, and optional GPU prerequisites.
- A direct OpenAI-compatible vLLM response and increases in its request and
  token counters.
- LiteLLM routing to the expected vLLM backend, with both counters increasing.
- A unique successful Langfuse trace with model, timing, positive token usage,
  and prompt/response visibility matching the privacy setting.
- An intentional unknown-model error and an increase in LiteLLM failures.
- Twenty requests at concurrency four, nonzero request/token rates, and a
  nonzero running-request observation in Prometheus.
- Healthy LiteLLM/vLLM/Kubernetes scrape targets and a loaded Grafana dashboard.
- No pod replacements or container restarts during the failure/load stages.
- Deletion of one named LiteLLM pod, a different replacement UID, fresh
  Prometheus scraping, and successful inference after recovery.

Failed-request tracing is integration-path dependent. The result records it as
`ERROR_RECORDED`, `RECORDED_WITHOUT_ERROR_STATUS`, or `UNSUPPORTED_HTTP_*`
without weakening the required successful-trace assertion.

## Open the interfaces

The directly applied demo exposes:

```text
LiteLLM: http://litellm.192.168.122.227.sslip.io
Grafana: http://grafana.192.168.122.227.sslip.io
Langfuse: http://langfuse.192.168.122.227.sslip.io
```

The hostnames resolve through `sslip.io` to the current AIFLab node. vLLM and
Prometheus remain internal; LiteLLM is the public inference path and Grafana is
the public metrics view.

Port-forwarding remains useful if ingress is disabled. In that case, also set
`langfuse.nextauth.url` back to `http://localhost:3000` before applying. Use
separate terminals:

```bash
kubectl -n inference-management port-forward service/litellm 4000:4000
kubectl -n inference-management port-forward service/inference-grafana 3001:80
kubectl -n inference-management port-forward service/langfuse-web 3000:3000
```

The Grafana dashboard is **Inference Management MVP** (UID
`inference-management-mvp`). Grafana and Langfuse login values, plus the
LiteLLM master key, are in `Secret/inference-management-secrets`.

An independent gateway request looks like:

```bash
curl --fail-with-body http://litellm.192.168.122.227.sslip.io/v1/chat/completions \
  -H 'Authorization: Bearer sk-mvp-CHANGE_ME-before-exposure' \
  -H 'Content-Type: application/json' \
  --data '{"model":"mvp-model","messages":[{"role":"user","content":"Say hello briefly"}],"max_tokens":16}'
```

Use `traceID` or `marker` from the results ConfigMap to locate the same request
in Langfuse. Grafana intentionally reads only Prometheus; metrics are not sent
through Langfuse.

## Re-run and remove

Re-run all assertions without touching the Helm releases:

```bash
kubectl -n inference-management delete job/inference-management-test-0-1-0 \
  --ignore-not-found
kubectl apply -f aiflab/demos/inference-management/blueprint.yaml
```

For removal, delete the AIWorkload first so its finalizer can remove only the
four generated Helm/Fleet releases, then remove the remaining manifest objects:

```bash
kubectl -n inference-management delete aiworkload/inference-management-mvp
kubectl -n inference-management wait \
  --for=delete aiworkload/inference-management-mvp --timeout=15m
kubectl delete -f aiflab/demos/inference-management/blueprint.yaml \
  --ignore-not-found
```

Do not manually delete shared Prometheus Operator CRDs during cleanup. Helm CRD
objects may intentionally remain, and deleting shared CRDs would affect other
monitoring installations.

## Upstream references

- [vLLM production stack](https://docs.vllm.ai/projects/production-stack/en/latest/)
- [vLLM metrics](https://docs.vllm.ai/en/latest/design/metrics/)
- [LiteLLM Prometheus metrics](https://docs.litellm.ai/docs/proxy/prometheus)
- [LiteLLM Langfuse integration](https://docs.litellm.ai/docs/observability/langfuse_integration)
- [Langfuse Kubernetes Helm deployment](https://langfuse.com/self-hosting/deployment/kubernetes-helm)
- [Langfuse headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
