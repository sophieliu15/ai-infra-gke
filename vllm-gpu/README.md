# vLLM + GPU Scheduling on GKE

Deploy an open-weights LLM (`Qwen/Qwen3-4B-Instruct-2507`) on a GKE GPU node via vLLM, exposed through an OpenAI-compatible API. The cluster uses a two-pool GPU setup (on-demand + Spot) with multi-zone failover and a Custom Compute Class for on-demand-first scheduling priority.

## Architecture

```
┌──────────┐   OpenAI API   ┌────────────────┐   nvidia.com/gpu=present   ┌──────────────────┐
│  Client  │───────────────▶│  vLLM Service  │────────────────────────────▶│  L4 GPU Node     │
└──────────┘  :8000/v1/...  │  (Deployment)  │  toleration + nodeSelector │  (Qwen3-4B)      │
                            └────────────────┘                             └──────────────────┘
```

- **Cluster:** GKE Standard, `us-west1-b`. Default pool: 1× `e2-standard-4`. Cluster is torn down after each session.
- **GPU pools:** on-demand L4 + Spot L4, both spanning `us-west1-b/c/a` with `--location-policy=ANY`. On-demand-first priority is enforced by a Custom Compute Class (`compute-class.yaml`).
- **GPU isolation:** taint `nvidia.com/gpu=present:NoSchedule` on both GPU pools — only tolerating pods land there.
- **Model:** `Qwen/Qwen3-4B-Instruct-2507` (~8 GB bf16 weights, 24 GB L4, Apache 2.0, ungated).
- **Image:** `vllm/vllm-openai:v0.28.0` (pinned — never use `latest`).
- **Single-GPU constraint:** global GPU quota = 1, so only one GPU workload runs at a time.

## Prerequisites

| Requirement | Detail |
| --- | --- |
| GCP project | With billing enabled |
| GPU quota | At least 1× NVIDIA L4 in `us-west1` (`NVIDIA_L4_GPUS` quota) |
| Tools | `gcloud`, `kubectl`, `curl` |
| Auth | `gcloud auth login` and `gcloud config set project <project-id>` |

### Cluster specs

| Field | Value |
| --- | --- |
| Cluster name | `vllm-gpu-study` |
| Region / zone | `us-west1` (Oregon) / `us-west1-b` |
| Default pool | 1× `e2-standard-4` (4 vCPU, 16 GB RAM) |
| On-demand GPU pool | `gpu-pool-ondemand`: `g2-standard-4` + NVIDIA L4 (24 GB), autoscale 0–1 |
| Spot GPU pool | `gpu-pool-spot`: `g2-standard-4` + NVIDIA L4 (`--spot`), autoscale 0–1 |
| GPU pool zones | `us-west1-b, us-west1-c, us-west1-a` (`--location-policy=ANY`) |
| Pool priority | ComputeClass `gpu-l4` — on-demand first, Spot fallback on `FailedScaleUp` |
| GPU driver | `gpu-driver-version=default` (managed by GKE) |
| vLLM image | `vllm/vllm-openai:v0.28.0` |
| Model | `Qwen/Qwen3-4B-Instruct-2507` (bf16, FlashAttention v2, 16k context) |
| KV cache budget | 11.79 GiB → 85,808 tokens → ~5 concurrent 16k-token sequences |
| Cost | ~$0.80/hr total (default node + L4 GPU node). Always delete the cluster when done. |

## Quickstart

### 1. Create the cluster

```bash
bash cluster.sh create
```

This creates the GKE cluster, two GPU node pools, and applies the Custom Compute Class. Takes ~5 minutes. GPU pools start at 0 nodes — no GPU charges until you deploy a workload.

### 2. (Optional) Run the GPU smoketest

Before deploying vLLM, optionally validate that GPU scheduling works with a minimal CUDA pod:

```bash
kubectl apply -f gpu-smoketest.yaml
kubectl get pods -w                    # Pending → Running in ~2 min
kubectl logs gpu-smoketest             # Should show: NVIDIA L4, 23034 MiB
kubectl delete -f gpu-smoketest.yaml
```

This exercises four things that can fail silently on a fresh cluster: autoscaler scale-up, GPU driver install, taint/toleration match, and GPU device advertisement. If the pod stays `Pending`, check `kubectl describe pod gpu-smoketest` for autoscaler events.

### 3. Deploy vLLM

```bash
kubectl apply -f vllm-deployment.yaml
kubectl get pods -n vllm-gpu -w
```

Wait for the pod to reach `Running 1/1`. On a cold node (first deploy), expect:
- ~2 min for the L4 node to provision (autoscaler scale-up)
- ~3 min for the vLLM image pull (~8.6 GB)
- ~50s for model weights download (7.49 GB from HuggingFace)
- ~6s for safetensors loading into GPU memory

Total cold start: **~6–10 minutes**. Subsequent deploys on the same node skip the image pull and reuse cached weights.

### 4. Send a request

```bash
# Port-forward the vLLM service
kubectl port-forward svc/vllm 8000:8000 -n vllm-gpu &

# Send a chat completion request (OpenAI-compatible API)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-4B-Instruct-2507",
    "messages": [{"role": "user", "content": "Explain Kubernetes pod scheduling in 2 sentences."}],
    "max_tokens": 64
  }'
```

Expected response:
```json
{
  "model": "Qwen/Qwen3-4B-Instruct-2507",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Kubernetes pod scheduling is the process of assigning pods to nodes in a cluster based on resource requirements, constraints, and availability. The Kubernetes scheduler evaluates pod specifications and node conditions to find the best fit, ensuring efficient resource utilization and meeting constraints like node labels, affinity, or anti-affinity rules."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {"prompt_tokens": 18, "completion_tokens": 60, "total_tokens": 78}
}
```

### 5. Scrape Prometheus metrics

```bash
curl -s http://localhost:8000/metrics | grep -E "vllm:(num_requests|kv_cache|generation_tokens|time_to_first)"
```

Key metrics:

| Metric | Type | What it measures |
| --- | --- | --- |
| `vllm:num_requests_running` | gauge | In-flight requests being decoded on the GPU |
| `vllm:num_requests_waiting` | gauge | Requests queued behind the running batch |
| `vllm:kv_cache_usage_perc` | gauge | Fraction of KV cache blocks in use |
| `vllm:time_to_first_token_seconds` | histogram | Prefill latency (time to first generated token) |
| `vllm:generation_tokens_total` | counter | Cumulative output tokens since server start |

**Note:** gauge metrics (`num_requests_running`, `kv_cache_usage_perc`) read `0.0` when scraped after a request completes — they measure the instant of scrape, not historical activity. Send concurrent requests to observe non-zero gauges.

### 6. Tear down

```bash
bash cluster.sh delete
```

The cluster costs ~$0.80/hr while running (default node + GPU node). Always delete when done.

## Troubleshooting

These are real issues encountered during deployment, in the order you're likely to hit them.

### 1. ComputeClass reports `CrdLabelNotMatching`, pods stay `Pending`

**Symptom:** `kubectl describe computeclass gpu-l4` reports `NodepoolMisconfigured: Crd label doesn't match Crd name for the nodepool gpu-pool-ondemand`. ComputeClass stays `Health: False`. Pods stay `Pending` with `Pod didn't trigger scale-up`.

**Root cause:** When `nodePoolAutoCreation.enabled: false` is used (pre-created node pools), GKE requires that each referenced node pool carries a node label matching the ComputeClass name: `cloud.google.com/compute-class: <class-name>`.

**Fix:** Add the label to existing node pools:
```bash
gcloud container node-pools update gpu-pool-ondemand \
  --cluster=vllm-gpu-study --zone=us-west1-b \
  --node-labels=nvidia.com/gpu=present,cloud.google.com/compute-class=gpu-l4
```
Then re-apply `compute-class.yaml`. This label is already included in `cluster.sh`.

### 2. GPU stockout in one zone (`FailedScaleUp: GCE out of resources`)

**Symptom:** Autoscaler emits `Warning FailedScaleUp: Node scale up in zone us-west1-b failed: GCE out of resources.`

**Root cause:** Transient GPU stockout. Quota is a ceiling, not a reservation — an approved quota can still return `out of resources`.

**What happens:** Because `cluster.sh` defines multi-zone locations (`us-west1-b,us-west1-c,us-west1-a`) and `--location-policy=ANY`, the autoscaler automatically tries the next zone. No manual intervention needed — just wait. If all three zones fail, the ComputeClass falls through from on-demand to Spot as a second level of failover.

### 3. Deployment update hangs — new pod `Pending`, old pod still `Running`

**Symptom:** After re-applying `vllm-deployment.yaml`, the new pod stays `Pending` while the old pod remains `Running`. Deployment makes no progress.

**Root cause:** Kubernetes Deployments default to `RollingUpdate` strategy, which creates the new pod before terminating the old one. On a quota=1 cluster, two `nvidia.com/gpu: 1` requests cannot be satisfied simultaneously.

**Fix:** Set `strategy.type: Recreate` in the Deployment spec. This terminates the old GPU pod first, freeing the accelerator. Already set in `vllm-deployment.yaml`.

### 4. vLLM crashes with `Engine core initialization failed` after ~120 seconds

**Symptom:** `APIServer` fails with `RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}`.

**Root cause:** Two issues in vLLM v0.28.0:
1. The V1 Engine has a 120s default timeout waiting for `EngineCore`. Cold start (image pull + model download + JIT graph compilation) exceeds this.
2. The v0.28.0 CLI spec uses a positional model argument, not `--model <name>`.

**Fix:** Add `--enforce-eager` to bypass JIT compilation (reduces engine init from ~150s to ~15s). Pass the model name as the first positional arg in the container `args` array. Both are already configured in `vllm-deployment.yaml`.

### 5. vLLM crashes with `VLLM_PORT appears to be a URI`

**Symptom:** `EngineCore` crashes with `ValueError: VLLM_PORT 'tcp://34.118.233.251:8000' appears to be a URI`.

**Root cause:** Kubernetes automatically injects environment variables like `VLLM_PORT=tcp://<cluster-ip>:8000` for any Service named `vllm` in the same namespace (legacy Docker-link compatibility). vLLM's internal parser expects `VLLM_PORT` to be a plain integer.

**Fix:** Add `enableServiceLinks: false` to the pod spec. Already set in `vllm-deployment.yaml`.

### 6. Image pull takes 5+ minutes on a fresh node

**Symptom:** Pod sits in `ContainerCreating` for several minutes. `kubectl describe pod` shows `Pulling image "vllm/vllm-openai:v0.28.0"`.

**Root cause:** The image is ~8.6 GB. Fresh GPU nodes have an empty image cache.

**Mitigation:** `imagePullPolicy: IfNotPresent` is set — subsequent pod restarts on the same node skip the pull. The `startupProbe` budget (120 × 10s = 20 min) accommodates the worst case. This is not a bug — just wait.

### 7. Cannot run a batch Job while vLLM is running

**Symptom:** A GPU batch Job pod stays `Pending` indefinitely.

**Root cause:** GPU quota = 1. Only one GPU workload at a time.

**Fix:** Scale vLLM to 0 first:
```bash
kubectl scale deploy vllm -n vllm-gpu --replicas=0
kubectl apply -f batch-job.yaml
# Wait for Job completion...
kubectl scale deploy vllm -n vllm-gpu --replicas=1
```

### 8. Gated models fail with 401 Unauthorized

**Symptom:** vLLM logs show `401 Unauthorized` or `Repository not found` during model download.

**Root cause:** Gated HuggingFace models (Llama, Gemma) require an access token. Qwen3 is Apache 2.0 and ungated, so this doesn't apply to the default config.

**Fix:** For gated models, create a Secret and mount `HF_TOKEN`:
```bash
kubectl create secret generic hf-token -n vllm-gpu --from-literal=token=hf_xxx
# Add to Deployment env:
# - name: HF_TOKEN
#   valueFrom: {secretKeyRef: {name: hf-token, key: token}}
```

### 9. vLLM OOMs on startup with Qwen3

**Symptom:** Pod crashes during engine initialization with an out-of-memory error.

**Root cause:** Qwen3-4B declares `max_position_embeddings: 262144` in its config. Without an explicit limit, vLLM tries to allocate a KV cache for 262k tokens — ~37 GB on a 24 GB card.

**Fix:** Always set `--max-model-len` explicitly. `16384` fits comfortably on L4 (allocates ~11.79 GiB of KV cache). Already set in `vllm-deployment.yaml`.

## How it works

### GPU isolation: taint + toleration + resource request

Three independent levers place a pod on the GPU node:

| Lever | Set on | Value | Role |
| --- | --- | --- | --- |
| Taint | GPU node (`cluster.sh`) | `nvidia.com/gpu=present:NoSchedule` | Repels pods by default |
| Toleration | Pod spec | `key: nvidia.com/gpu`, `operator: Exists`, `effect: NoSchedule` | Lets the pod bypass the taint — does **not** attract it |
| Resource request | Pod spec | `resources.limits."nvidia.com/gpu": 1` | Actually routes the pod to the GPU node |

Key points:
- **Taint is a gate, not a magnet.** The resource request is what routes the pod. Without it, a tolerating pod could land on either pool.
- **GKE auto-injects the toleration** for any pod that requests `nvidia.com/gpu`. Writing it explicitly is redundant but improves readability.

### Two-pool GPU setup + multi-zone failover

| Layer | Config | Handles |
| --- | --- | --- |
| On-demand pool | `gpu-pool-ondemand`, autoscale 0–1 | Preferred — no preemption |
| Spot pool | `gpu-pool-spot` + `--spot`, autoscale 0–1 | Fallback — cheaper, ~30s preempt notice |
| Multi-zone | Both pools: `--node-locations=us-west1-b,us-west1-c,us-west1-a` | Zone-level stockouts |
| Location policy | Both pools: `--location-policy=ANY` | Autoscaler picks whichever zone has capacity |
| Total-node cap | Both pools: `--total-max-nodes=1` | Honours global GPU quota |

**The GKE autoscaler picks the *cheapest* pool first by default (Spot, not on-demand).** On-demand-first priority requires an explicit mechanism — see below.

### On-demand-first priority: Custom Compute Class

`compute-class.yaml` defines a `ComputeClass` named `gpu-l4` with two priority entries — `gpu-pool-ondemand` first, `gpu-pool-spot` second. The autoscaler walks the list top-to-bottom: on `FailedScaleUp` for the on-demand pool, it falls through to Spot automatically. Pods opt in with:

```yaml
nodeSelector:
  cloud.google.com/compute-class: gpu-l4
```

| Field | Value | Why |
| --- | --- | --- |
| `priorities[0].nodepools` | `[gpu-pool-ondemand]` | Preferred — no preemption |
| `priorities[1].nodepools` | `[gpu-pool-spot]` | Fallback on `FailedScaleUp` |
| `nodePoolAutoCreation.enabled` | `false` | Pools are pre-created by `cluster.sh` |
| `whenUnsatisfiable` | `DoNotScaleUp` | If both pools fail, stay `Pending` — don't place on CPU pool |

Alternatives ruled out: the [priority expander](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/expander/priority/readme.md) isn't configurable on GKE's managed autoscaler. A Spot-pool taint + toleration gives a hard gate, not a fallback.

### vLLM engine flags and image pinning

Image pinned to `vllm/vllm-openai:v0.28.0`. Never use `latest` — vLLM's CLI, engine architecture, and default flags change between minor versions.

| Flag / Config | Value | Why |
| --- | --- | --- |
| `--enforce-eager` | enabled | Bypasses JIT compilation + CUDA graph capture. Reduces cold start from ~150s to ~15s. Tradeoff: ~10–15% lower steady-state throughput (no CUDAGraph batching). |
| `--max-model-len` | `16384` | **Mandatory for Qwen3.** Default 262k context OOMs on 24 GB. 16384 → ~85k token KV budget, ~5 concurrent sequences. |
| `--gpu-memory-utilization` | `0.9` | Reserve 90% of VRAM for weights + KV cache. 10% headroom for CUDA context. |
| `--dtype auto` | resolves to `bfloat16` | L4 is Ada (sm_89) and bf16-capable. |
| `enableServiceLinks: false` | pod spec | Prevents K8s from injecting `VLLM_PORT=tcp://...` (see [troubleshooting #5](#5-vllm-crashes-with-vllm_port-appears-to-be-a-uri)). |
| `strategy: Recreate` | deployment spec | Required on quota=1 — `RollingUpdate` deadlocks (see [troubleshooting #3](#3-deployment-update-hangs--new-pod-pending-old-pod-still-running)). |
| `emptyDir` at `/root/.cache/huggingface` | volume mount | Persists model weights across container restarts. Drops weight loading from 38s to 8s. |

### GPU choice: L4 over T4

L4 (Ada, sm_89) over T4 (Turing, sm_75) for three reasons:

| Pressure | Detail |
| --- | --- |
| Cloud lifecycle | T4 has a published GCP [end-of-support date of 2027-08-01](https://cloud.google.com/compute/docs/eol/t4-eos). New CUDs are blocked. |
| Runtime support | vLLM's sm_75 support is decaying — FlashInfer dropped from SM75 in v0.24.0, `FLASH_ATTN` requires sm_80+. |
| Model ecosystem | T4 is fp16-only. Current open models are bf16-native; Gemma 3 overflows to NaN under fp16. |

L4: bf16-capable, 24 GB (vs 16 GB), FlashAttention-eligible, not on a sunset path. Costs ~$0.70/hr vs ~$0.35/hr on-demand.

### Region: us-west1

`us-west1` over `us-central1` — `us-central1` is Google's ML hub and is consistently contested for GPU inventory. `us-west1` has historically better on-demand availability. Same quota is pre-approved in every US region, so switching is a config change only.

## Scripts

| Script | What it does |
| --- | --- |
| `cluster.sh create` | Creates the GKE cluster with two L4 GPU pools + ComputeClass |
| `cluster.sh delete` | Deletes the cluster and stops all charges |
| `cluster.sh status` | Shows nodes by pool, accelerator, spot, and zone labels |
