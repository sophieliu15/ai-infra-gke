# Live Test Report: vLLM Qwen3-4B Deployment on GKE NVIDIA L4

**Date:** 2026-09-03  
**Cluster:** `vllm-gpu-study` (`us-west1-b`)  
**Hardware:** NVIDIA L4 (24 GB VRAM) on `g2-standard-4`  
**Model:** `Qwen/Qwen3-4B-Instruct-2507`  
**Image:** `vllm/vllm-openai:v0.28.0`  
**Priority Policy:** Custom Compute Class `gpu-l4` (on-demand first, Spot fallback)

---

## 1. Cluster & Priority Setup

### Cluster Creation & ComputeClass Application
- **Command:** `bash cluster.sh create`
- **Region/Zone:** `us-west1-b` (with multi-zone GPU locations `us-west1-b,us-west1-c,us-west1-a`)
- **Default Node Pool:** 1× `e2-standard-4`
- **GPU Node Pools:**
  - `gpu-pool-ondemand` (autoscale 0–1, `g2-standard-4` + NVIDIA L4)
  - `gpu-pool-spot` (autoscale 0–1, `g2-standard-4` + NVIDIA L4 `--spot`)

```text
NAME            LOCATION    MASTER_VERSION      MASTER_IP     MACHINE_TYPE   NODE_VERSION        NUM_NODES  STATUS   STACK_TYPE
vllm-gpu-study  us-west1-b  1.35.7-gke.1027000  8.229.146.95  e2-standard-4  1.35.7-gke.1027000  1          RUNNING  IPV4

Node Pools Created:
- default-pool: 1x e2-standard-4 (Ready)
- gpu-pool-ondemand: g2-standard-4 + NVIDIA L4 (autoscale 0–1, zones: us-west1-b, us-west1-c, us-west1-a)
- gpu-pool-spot: g2-standard-4 + NVIDIA L4 --spot (autoscale 0–1, zones: us-west1-b, us-west1-c, us-west1-a)

ComputeClass applied:
computeclass.cloud.google.com/gpu-l4 created
```

---

## 2. Pod Scheduling & On-Demand Priority Validation

Applying `vllm-deployment.yaml` with `nodeSelector: cloud.google.com/compute-class: gpu-l4`.

### Node Provisioning & Custom Compute Class Trace
*Verified Outcome:* The GKE cluster autoscaler walked `priorities[0]` (`gpu-pool-ondemand`) first and provisioned an on-demand L4 node (`g2-standard-4`) in `us-west1-a` (after an automatic zone failover from `us-west1-b` on stockout).

```text
# Cluster Nodes Status
NAME                                                 STATUS   ROLES    AGE    VERSION               GKE-NODEPOOL        GKE-ACCELERATOR   GKE-SPOT   ZONE
gke-vllm-gpu-study-default-pool-e2ddf5c5-xgb8        Ready    <none>   11m    v1.35.7-gke.1027000   default-pool                                     us-west1-b
gke-vllm-gpu-study-gpu-pool-ondemand-90fb1b9a-zhpz   Ready    <none>   1m45s  v1.35.7-gke.1027000   gpu-pool-ondemand   nvidia-l4                    us-west1-a

# Pod Placement & Autoscaler Event Log
Normal   TriggeredScaleUp   cluster-autoscaler  Pod triggered scale-up: [{gpu-pool-ondemand 0->1}]
Warning  FailedScaleUp      cluster-autoscaler  Node scale up in zone us-west1-b failed: GCE out of resources.
Normal   Scheduled          default-scheduler   Successfully assigned vllm-gpu/vllm-745df8789c-njjll to gke-vllm-gpu-study-gpu-pool-ondemand-90fb1b9a-zhpz (zone us-west1-a)
Normal   Pulling            kubelet             Pulling image "vllm/vllm-openai:v0.28.0"
```

### Container Startup & Health Probes Timeline
- **Image pull:** `vllm/vllm-openai:v0.28.0` (~8.6 GB multi-arch image, ~2 min 40 sec)
- **Model weights download:** `Qwen/Qwen3-4B-Instruct-2507` (7.49 GiB downloaded in **49.17 seconds** from HuggingFace)
- **Attention Backend:** `FLASH_ATTN` (FlashAttention v2 on Ada `sm_89`, enabled natively by L4)
- **Precision:** `torch.bfloat16`
- **Engine Initialization:** CUDA graph capture & PagedAttention block pool allocation (~11.79 GB KV cache reserved)
- **Startup Probe status:** `startupProbe` passing `/health` (budget: 120 × 10s = 20 min)

---

## 3. OpenAI Chat Completions Verification

### `/v1/chat/completions` Test
```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-4B-Instruct-2507",
    "messages": [{"role": "user", "content": "Explain Kubernetes pod scheduling in 2 sentences."}],
    "max_tokens": 64
  }'
```

*Recorded Response:*
```json
{
  "id": "chatcmpl-ae27f797d11b2870",
  "object": "chat.completion",
  "created": 1788461944,
  "model": "Qwen/Qwen3-4B-Instruct-2507",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Kubernetes pod scheduling is the process of assigning pods to nodes in a cluster based on resource requirements, constraints, and availability. The Kubernetes scheduler evaluates pod specifications and node conditions to find the best fit, ensuring efficient resource utilization and meeting constraints like node labels, affinity, or anti-affinity rules."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 18,
    "total_tokens": 78,
    "completion_tokens": 60
  },
  "system_fingerprint": "vllm-0.28.0-83b9c2ff"
}
```

---

## 4. Prometheus `/metrics` Baseline Reconcile

Scraped counters from `http://localhost:8000/metrics`:

| Metric | Measured Value | Description |
|---|---|---|
| `vllm:num_requests_running` | `0.0` | In-flight decode batch size |
| `vllm:num_requests_waiting` | `0.0` | Queue depth |
| `vllm:kv_cache_usage_perc` | `0.0` | PagedAttention KV block saturation |
| `vllm:time_to_first_token_seconds_sum` | `0.12658` (126.58 ms) | Prefill + TTFT latency |
| `vllm:generation_tokens_total` | `60.0` | Total output token count |

---

## 5. Obstacles & Operational Discoveries (Troubleshooting Log)

### 1. GKE Custom Compute Class Node Pool Label Mismatch (`CrdLabelNotMatching`)
- **Symptom:** `kubectl describe computeclass gpu-l4` reported `NodepoolMisconfigured: Crd label doesn't match Crd name for the nodepool gpu-pool-ondemand`, keeping `ComputeClass` in `Health: False`. Pods stayed `Pending` with `Pod didn't trigger scale-up`.
- **Root Cause:** When `nodePoolAutoCreation.enabled: false` is used (pre-created node pools), GKE requires that each referenced node pool carries the node label matching the `ComputeClass` name: `cloud.google.com/compute-class: <class-name>`.
- **Resolution:** Updated node pool labels via `gcloud container node-pools update` to include `cloud.google.com/compute-class=gpu-l4`, re-applied `compute-class.yaml`, and updated `cluster.sh` for future creations.

### 2. Multi-Zone Accelerator Stockout & Automatic Failover
- **Symptom:** Autoscaler emitted `Warning FailedScaleUp: Node scale up in zone us-west1-b failed: GCE out of resources.`
- **Root Cause:** Transient GPU stockout in `us-west1-b`.
- **Resolution:** Because `cluster.sh` defined multi-zone locations (`us-west1-b,us-west1-c,us-west1-a`) and `--location-policy=ANY`, GKE autoscaler automatically fell through to **`us-west1-a`**, successfully provisioning `gke-vllm-gpu-study-gpu-pool-ondemand-90fb1b9a-zhpz`.

### 3. Single-GPU Cluster Rollout Lock (`RollingUpdate` vs `Recreate`)
- **Symptom:** Re-applying `vllm-deployment.yaml` caused the new pod to stay stuck in `Pending` state while the existing pod remained `Running`.
- **Root Cause:** Kubernetes Deployments default to `RollingUpdate` strategy (spins up new pod before terminating old pod). On a quota=1 single GPU cluster, 2 GPU requests cannot be satisfied simultaneously.
- **Resolution:** Added `strategy.type: Recreate` to `vllm-deployment.yaml` so Kubernetes terminates the old GPU pod first, freeing up the accelerator before creating the new pod.

### 4. vLLM v0.28.0 V1 Engine Startup Timeout & CLI Spec
- **Symptom:** `APIServer` process failed with `RuntimeError: Engine core initialization failed` after 120 seconds. vLLM emitted warnings regarding `--model` flag.
- **Root Cause:**
  1. In v0.28.0 (V1 Engine architecture), `APIServer` has a 120s startup timeout waiting for `EngineCore`. Cold start (8.6 GB image pull + 7.49 GB model weights download + JIT compilation) exceeded 120 seconds on the initial run.
  2. vLLM v0.28.0 CLI spec replaces `--model <name>` with positional argument 0 (`vllm serve Qwen/Qwen3-4B-Instruct-2507`).
- **Resolution:** Added `--enforce-eager` to bypass JIT compilation delays (slashed engine init from ~150s down to 14.6s), updated positional CLI args, and verified that on Run 2 with cached weights, engine initialization completes in ~35 seconds cleanly.

### 5. Persistent `emptyDir` Cache & K8s Service Link Conflict Fix (`VLLM_PORT`)
- **Symptom:** `EngineCore` crashed with `ValueError: VLLM_PORT 'tcp://34.118.233.251:8000' appears to be a URI` because Kubernetes automatically injects legacy service environment variables for services named `vllm`.
- **Root Cause:** Kubernetes injected `VLLM_PORT="tcp://34.118.233.251:8000"` into container environment variables, which clashed with vLLM's internal `VLLM_PORT` environment variable parser. Additionally, un-volumed container restarts forced full model downloads on every crash.
- **Resolution:**
  1. Added `enableServiceLinks: false` and explicitly set `VLLM_PORT: "8000"` in `vllm-deployment.yaml` to block K8s URI link pollution.
  2. Mounted an `emptyDir` volume at `/root/.cache/huggingface`. This persisted downloaded model weights across pod container restarts, dropping safetensors weight loading time from **38.26 seconds down to 8.12 seconds**.

---

## 6. Teardown & Cost Summary

- **Session duration:** ~35 minutes
- **Hardware:** 1× e2-standard-4 default node ($0.134/hr) + 1× g2-standard-4 NVIDIA L4 GPU node ($0.672/hr)
- **Total GPU cost incurred:** ~$0.47
- **Teardown command:** `bash cluster.sh delete`
