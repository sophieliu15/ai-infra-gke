# Live Test Report: KServe v0.20.0 + vLLM Qwen3-4B Deployment on GKE NVIDIA L4 (Path A)

**Date:** 2026-09-04  
**Cluster:** `vllm-gpu-study` (`us-west1-b`)  
**Hardware:** NVIDIA L4 (24 GB VRAM) on `g2-standard-4`  
**Model:** `Qwen/Qwen3-4B-Instruct-2507` (~8 GB bf16)  
**Image:** `vllm/vllm-openai:v0.28.0`  
**Platform Stack:** KServe v0.20.0, cert-manager v1.17.0, ClusterServingRuntime `kserve-vllmserver`  
**Deployment Mode:** Standard (`serving.kserve.io/deploymentMode: Standard`)  
**Priority Policy:** Custom Compute Class `gpu-l4` (on-demand first, Spot fallback)  

---

## 1. Cluster & CRD Pre-Flight Setup

### Cluster Creation & Ownership Inspection
- **Cluster creation command:** `bash ai_infra_projects/vllm-gpu/cluster.sh create`
- **Region/Zone:** `us-west1-b` (with multi-zone GPU locations `us-west1-b,us-west1-c,us-west1-a`)
- **Default Node Pool:** 1× `e2-standard-4` (`gke-vllm-gpu-study-default-pool-558fcdd2-98s4`, Ready)
- **GPU Node Pools:**
  - `gpu-pool-ondemand` (autoscale 0–1, `g2-standard-4` + NVIDIA L4)
  - `gpu-pool-spot` (autoscale 0–1, `g2-standard-4` + NVIDIA L4 `--spot`)

### Pre-Install CRD Ownership Audit
Before installing KServe, ran the CRD ownership audit to prevent conflicts with GKE's `kube-addon-manager`:
```bash
kubectl get crd -o json | jq -r '
  .items[]
  | select(.metadata.name | test("inference\\.networking|gateway\\.networking"))
  | [.metadata.name,
     (.metadata.labels["addonmanager.kubernetes.io/mode"] // "-"),
     (.spec.versions | map(.name) | join(","))]
  | @tsv'
```

*Recorded Output:*
```text
backendtlspolicies.gateway.networking.k8s.io      NewerRevision   v1,v1alpha3
gatewayclasses.gateway.networking.k8s.io          NewerRevision   v1,v1beta1
gateways.gateway.networking.k8s.io                NewerRevision   v1,v1beta1
httproutes.gateway.networking.k8s.io              NewerRevision   v1,v1beta1
inferencepools.inference.networking.k8s.io        NewerRevision   v1
referencegrants.gateway.networking.k8s.io         NewerRevision   v1,v1beta1
tlsroutes.gateway.networking.k8s.io               NewerRevision   v1,v1alpha2,v1alpha3
```
*Crucial Confirmation:* GKE owns `inferencepools.inference.networking.k8s.io` (v1) under `NewerRevision`. The KServe installer was designed to filter out `inferencepools.inference.networking.k8s.io` while retaining `inferencepools.inference.networking.x-k8s.io` (v1alpha2) required by the `llmisvc-controller-manager`.

---

## 2. KServe v0.20.0 Installation Trace

- **Script:** `bash ai_infra_projects/vllm-gpu/kserve_install.sh` (standalone installer inside `vllm-gpu/`, zero modifications to `kserve/`)
- **Components Installed:**
  - cert-manager `v1.17.0`
  - KServe `v0.20.0` CRDs and controllers
  - ClusterServingRuntime resources (`kserve-vllmserver`, `kserve-huggingfaceserver`, etc.)
- **Controller Readiness:**
  ```text
  NAME                                                   READY   STATUS    RESTARTS   AGE
  kserve-controller-manager-84695bd7b6-nk9sz             2/2     Running   0          34s
  kserve-localmodel-controller-manager-86796845c-wkgdk   1/1     Running   0          90s
  llmisvc-controller-manager-5655d8c55d-kj2ck            1/1     Running   0          90s
  ```
- **Configuration Patches Applied:**
  - Standard Deployment Mode: `inferenceservice-config` ConfigMap `deploy.defaultDeploymentMode: Standard`
  - Disabled Istio VirtualHost warning: `ingress.disableIstioVirtualHost: true`
  - Storage Initializer Memory: `clusterstoragecontainer/default` memory limit raised to `4Gi` (see Troubleshooting)
  - Runtime Python Binary: `clusterservingruntime/kserve-vllmserver` command patched to `python3` (see Troubleshooting)

---

## 3. Pod Scheduling, Storage Initializer & Container Startup Timeline

- **Manifest Applied:** `ai_infra_projects/vllm-gpu/qwen3-vllm-isvc.yaml`
- **Node Provisioning:**
  - Pod `qwen3-predictor` triggered GKE autoscaler `gpu-pool-ondemand 0->1` in `us-west1-a`.
  - Node `gke-vllm-gpu-study-gpu-pool-ondemand-3c17ac88-fj5s` provisioned and registered in ~2 min 15 sec.
  - GKE `nvidia-gpu-device-plugin` initialized in ~30s, advertising `nvidia.com/gpu: 1`.
- **Model Acquisition (`storage-initializer` initContainer):**
  - Image: `kserve/storage-initializer:v0.20.0`
  - Download target: `hf://Qwen/Qwen3-4B-Instruct-2507` -> `/mnt/models`
  - Download duration: **68.73 seconds** for 7.49 GiB safetensors model weights.
- **Serving Engine (`kserve-container`):**
  - Image: `vllm/vllm-openai:v0.28.0` (pinned via `spec.predictor.model.runtimeVersion: v0.28.0`)
  - Image pull: 5 min 7 sec (8.63 GB uncompressed image layers on fresh node)
  - Attention Backend: `FLASH_ATTN` (FlashAttention v2 on Ada `sm_89`)
  - Precision: `torch.bfloat16`
  - Checkpoint Shards Load: 3/3 shards loaded in ~44 seconds.
  - VRAM Footprint: `8,938 MiB / 23,034 MiB` allocated on NVIDIA L4.
  - Startup / Readiness Probes: `GET /v1/models` passing 200 OK.
- **InferenceService Status:**
  ```text
  NAME     URL                                 READY   PREV   LATEST   AGE
  qwen3    http://qwen3-vllm-gpu.example.com   True                    16m
  ```

---

## 4. OpenAI Chat Completions Verification

Port-forwarded directly to the predictor service:
```bash
kubectl port-forward -n vllm-gpu svc/qwen3-predictor 8080:80
```

### Test 1: Served Model Name Confirmation (`/v1/models`)
```json
{
  "object": "list",
  "data": [
    {
      "id": "qwen3",
      "object": "model",
      "owned_by": "vllm",
      "root": "/mnt/models",
      "max_model_len": 16384
    }
  ]
}
```
*Note:* The served model ID is `qwen3` (the name of the `InferenceService`), not the Hugging Face repo ID.

### Test 2: General Knowledge & KV Cache Explanation
```bash
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen3",
  "messages": [{"role":"user","content":"Explain KV cache in one sentence."}],
  "max_tokens": 60
}' | jq
```

*Recorded Output:*
```json
{
  "id": "chatcmpl-ae5916d4d9d70bda",
  "object": "chat.completion",
  "created": 1788532317,
  "model": "qwen3",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "A KV cache (Key-Value cache) stores previously computed key-value pairs from a model's attention mechanism to avoid redundant calculations and speed up subsequent token generation in sequence modeling."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 16,
    "total_tokens": 52,
    "completion_tokens": 36
  },
  "system_fingerprint": "vllm-0.28.0-4ae0aaf6"
}
```

### Test 3: Standard Benchmark Prompt Verification
```bash
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen3",
  "messages": [{"role":"user","content":"Explain Kubernetes pod scheduling in 2 sentences."}],
  "max_tokens": 64
}' | jq
```

*Recorded Output:*
```json
{
  "id": "chatcmpl-b0d7a2906c73d2ce",
  "object": "chat.completion",
  "created": 1788532322,
  "model": "qwen3",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Kubernetes pod scheduling is the process of assigning pods to nodes in a cluster based on resource requirements, constraints, and availability. The Kubernetes scheduler evaluates pod specifications and node conditions to ensure optimal resource utilization, affinity rules, and availability, then places the pod on a suitable node."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 18,
    "total_tokens": 74,
    "completion_tokens": 56
  },
  "system_fingerprint": "vllm-0.28.0-4ae0aaf6"
}
```

---

## 5. Prometheus `/metrics` Baseline Reconcile

Scraped counters from `http://localhost:8080/metrics`:

| Metric | Measured Value (KServe Path A) | Measured Value (Raw vLLM Baseline) | Note |
|---|---|---|---|
| `vllm:num_requests_running` | `0.0` | `0.0` | Idle after completions |
| `vllm:num_requests_waiting` | `0.0` | `0.0` | No queuing |
| `vllm:kv_cache_usage_perc` | `0.0` | `0.0` | PagedAttention blocks reclaimed |
| `vllm:time_to_first_token_seconds_sum` | `0.23137s` (across 2 reqs) | `0.12658s` (1 req) | **Avg TTFT: 115.68 ms** |
| `vllm:generation_tokens_total` | `92.0` | `60.0` | Cumulative generated tokens |
| `vllm:e2e_request_latency_seconds_sum` | `4.6262s` | N/A | Total e2e generation time |

---

## 6. Obstacles & Operational Discoveries (Troubleshooting Log)

### 1. `storage-initializer` OOMKill on Large HF Models (`Exit Code: 137`)
- **Symptom:** Init container `storage-initializer` repeatedly crashed with `Exit Code: 137` / `Reason: OOMKilled` during model weight transfer.
- **Root Cause:**
  - Upstream KServe v0.20.0 defines default limits of `1Gi` memory for `storage-initializer`.
  - In KServe v0.20.0, resource definitions for initializers are governed by the `ClusterStorageContainer` CRD (`default`) rather than solely the ConfigMap.
  - Multi-stream high performance downloading (`HF_HUB_ENABLE_HF_TRANSFER=1`, `HF_XET_NUM_CONCURRENT_RANGE_GETS=8`) exceeded 1Gi of resident memory while streaming the 7.49 GiB model.
- **Resolution:**
  - Patched `clusterstoragecontainer/default` to set `limits.memory: "4Gi"` and `requests.memory: "1Gi"`.
  - Also updated `inferenceservice-config` ConfigMap and added this patch to `kserve_install.sh`.
  - On restart, model download completed cleanly in **68.72 seconds**.

### 2. Upstream Runtime Command Mismatch (`exec: "python": executable file not found in $PATH`)
- **Symptom:** `kserve-container` failed at startup with `Exit Code: 128`, `Reason: StartError: failed to create shim task: ... exec: "python": executable file not found in $PATH`.
- **Root Cause:**
  - Upstream `kserve-vllmserver` ClusterServingRuntime declares `command: [python, -m, vllm.entrypoints.openai.api_server]`.
  - Modern Ubuntu-based images (such as `vllm/vllm-openai:v0.28.0`) install `/usr/bin/python3` without the legacy `/usr/bin/python` symlink.
- **Resolution:**
  - Patched `clusterservingruntime/kserve-vllmserver` to replace `python` with `python3`:
    ```bash
    kubectl patch clusterservingruntime kserve-vllmserver --type=json \
      -p '[{"op": "replace", "path": "/spec/containers/0/command/0", "value": "python3"}]'
    ```
  - Added this patch into `kserve_install.sh`. On restart, vLLM launched instantly.

### 3. Deployment Strategy & Single GPU Quota Deadlock
- **Symptom:** Modifying or updating the `InferenceService` created a new pod that stayed stuck in `Pending` due to `0/2 nodes available: 1 Insufficient nvidia.com/gpu`.
- **Root Cause:**
  - KServe manages an underlying Deployment (`qwen3-predictor`) which defaults to `RollingUpdate`.
  - On a cluster with a strict quota of 1 GPU, the new pod cannot schedule until the old pod terminates and frees the L4 GPU.
- **Resolution:**
  - Scaled the superseded ReplicaSet to 0 (`kubectl scale rs <old-rs> -n vllm-gpu --replicas=0`) and force-terminated the old pod.
  - The new pod immediately bound to the node and allocated the GPU.

---

## 7. Comparison: KServe Path A vs. Raw vLLM Deployment Baseline

| Architectural Dimension | Raw vLLM Deployment Baseline | KServe Path A | Operational Impact |
|---|---|---|---|
| **Control Plane Object** | Raw `apps/v1` `Deployment` | `serving.kserve.io/v1beta1` `InferenceService` | KServe abstracts container templates, probes, and networking under declarative CRDs |
| **Model Ingestion** | In-engine download to `/root/.cache/huggingface` inside main container | Decoupled `storage-initializer` init container downloading to `/mnt/models` | **Cold Start Caveat:** The GPU node sits idle and billing during the ~68s initContainer download. Pod restarts re-download weights unless shared persistent storage is attached. |
| **Runtime Abstraction** | Hardcoded container spec in deployment | `ClusterServingRuntime` (`kserve-vllmserver`) | Reusable runtime template across different models; decouples platform admin from model user |
| **Served Model Name** | `Qwen/Qwen3-4B-Instruct-2507` | `qwen3` | Runtime binds `--served-model-name={{.Name}}`. Must target the ISVC resource name. |
| **Time to First Token (TTFT)** | `126.58 ms` | `115.68 ms` | Performance is identical within normal variance (same vLLM v0.28.0 engine on L4). |
| **Weight Loading Time** | `38.26s` cold (`8.12s` with cached `emptyDir`) | `44.10s` cold from `/mnt/models` | Disk read speed from local emptyDir is consistent. |

---

## 8. Teardown & Cost Summary

- **Cluster Cleanup:** Executed `bash ai_infra_projects/vllm-gpu/cluster.sh delete`
- **Total Session Duration:** ~35 minutes
- **Nodes Incurred:** 1× `e2-standard-4` ($0.134/hr) + 1× `g2-standard-4` NVIDIA L4 ($0.70/hr)
- **Total Estimated Cost:** ~$0.48 CAD
