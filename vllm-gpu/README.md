# vLLM + GPU Scheduling on GKE

A hands-on project self-hosting an open-weights LLM (`microsoft/phi-2`) on a GKE GPU node via vLLM, exposed through an OpenAI-compatible API, and running GPU-accelerated PyTorch training Jobs on the same node pool. A follow-up iteration fronts vLLM with a KServe `InferenceService` to compose the serving stack from the [`kserve/`](../kserve/) project.

> **Status:** in progress — cluster script and key design decisions in place; deployment manifests, load benchmark, and KServe+vLLM composition to land next.

## Architecture

```
┌──────────┐   OpenAI API   ┌────────────────┐   nvidia.com/gpu=present   ┌──────────────────┐
│  Client  │───────────────▶│  vLLM Service  │────────────────────────────▶│  T4 GPU Node     │
└──────────┘  :8000/v1/...  │  (Deployment)  │  toleration + nodeSelector │  (Phi-2 loaded)  │
                            └────────────────┘                             └──────────────────┘
```

- **Cluster:** GKE Standard, `us-west1-b` (Oregon — see [region choice](#region-us-west1) below). Default pool: 1× `e2-standard-4` (single node, no HA — cluster is torn down after each session).
- **GPU pools (two):** on-demand T4 pool + Spot T4 pool, both spanning `us-west1-b/c/a` with `--location-policy=ANY`. Autoscaler prefers on-demand over Spot and `b` over other zones; falls through on stockout. Global T4 quota = 1 → at most one GPU node runs at a time.
- **GPU isolation:** taint `nvidia.com/gpu=present:NoSchedule` on both GPU pools — only tolerating pods land there.
- **Model:** `microsoft/phi-2` (fits T4 16 GB at fp16). Pinned vLLM image tag (not `latest`).
- **Single-GPU workflow:** quota=1, so vLLM must be scaled to 0 before launching a concurrent GPU training Job, then scaled back up after.

## Key decisions

### GPU isolation: taint + toleration + resource request

Three independent levers combine to place a pod on the T4 node. Getting the mental model straight up front avoids "why is my CPU pod on the expensive GPU node" and "why is vLLM stuck `Pending`" surprises.

| Lever            | Set on                                   | Value                                                                  | Role                                                                  |
| ---------------- | ---------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Taint            | GPU node (applied by `cluster.sh`)       | `nvidia.com/gpu=present:NoSchedule`                                    | Repels pods by default                                                |
| Toleration       | Pod spec (vLLM Deployment, training Job) | `key: nvidia.com/gpu`, `operator: Exists`, `effect: NoSchedule`        | Lets the pod bypass the taint — does **not** attract it               |
| Resource request | Pod spec                                 | `resources.limits."nvidia.com/gpu": 1`                                 | Actually pulls the pod to the GPU node (only pool with this resource) |

Notes on the choices:
- **Taint is a gate, not a magnet.** The resource request is what routes the pod. Without the request, a tolerating pod could land on either pool.
- **`Exists` over `Equal`.** The value (`present`) is a trivial label — `Exists` tolerates any future value change.
- **GKE auto-injects the toleration** for any pod that requests `nvidia.com/gpu`, so writing it explicitly is often redundant. Keep it anyway for readability — reviewers shouldn't need GKE domain knowledge to see that the pod is GPU-scheduled.

### Region: `us-west1`

Originally provisioned in `us-central1-a`; switched to `us-west1-b` after the 2026-04-16 smoketest hit repeated `FailedScaleUp: GCE out of resources` on on-demand T4 scale-ups. `us-central1` is Google's ML hub and is consistently contested for older GPU SKUs like T4. `us-west1` has historically better T4 on-demand availability, at a small latency cost (~20 ms from Toronto) that is invisible for this workflow (no real-time user traffic; only `kubectl` + `curl` for benchmarking).

Same regional T4 + Spot T4 + L4 quota (1 each) is pre-approved in every US/Canada region, so switching is a zone/region config change only — no quota request needed.

### Two-pool GPU setup + multi-zone failover

| Layer             | Config                                                               | Handles                                          |
| ----------------- | -------------------------------------------------------------------- | ------------------------------------------------ |
| On-demand pool    | `gpu-pool-ondemand`, T4, autoscale 0–1 total                         | Preferred — no preemption, predictable benchmarks |
| Spot pool         | `gpu-pool-spot`, T4 + `--spot`, autoscale 0–1 total                  | Fallback — cheaper, ~30s preempt notice          |
| Multi-zone        | Both pools: `--node-locations=us-west1-b,us-west1-c,us-west1-a`      | Zone-level stockouts                             |
| Location policy   | Both pools: `--location-policy=ANY`                                  | Autoscaler picks whichever zone has capacity      |
| Total-node cap    | Both pools: `--total-max-nodes=1`                                    | Honours global GPU quota (1 T4)                  |

GKE's autoscaler deprioritizes Spot pools when a non-Spot equivalent exists, so the on-demand pool is tried first automatically. Pods need only the `nvidia.com/gpu` toleration; GKE-spot taint is a label only (not a taint) on current GKE versions, so no Spot-specific toleration is required.

### Other decisions
_To be filled in: vLLM image pinning (not `latest`), prefix-caching on/off rationale._

## Outcomes

### GPU node pool smoketest (Spot T4)

Verified the three GPU scheduling levers end-to-end with a minimal CUDA pod (`nvidia/cuda:12.2.2-base-ubuntu22.04` running `nvidia-smi`). Pod applied → autoscaler triggered → T4 node provisioned → pod scheduled → `nvidia-smi` succeeded.

```
POD             NODE                                             STATUS
gpu-smoketest   gke-vllm-gpu-study-gpu-pool-spot-*               Running

NAME                                         POOL            SPOT   GPU
gke-vllm-gpu-study-gpu-pool-spot-*           gpu-pool-spot   true   nvidia-tesla-t4

Taints:    nvidia.com/gpu=present:NoSchedule
Capacity:  nvidia.com/gpu: 1

Tesla T4 | Driver 580.105.08 | CUDA 13.0 | 15360 MiB
```

**Stockout detour.** On-demand T4 in `us-central1-a` returned `FailedScaleUp: GCE out of resources` on every attempt — GCE was out of T4 inventory in that zone. Added a second node pool `gpu-pool-spot` with `--spot` (separate capacity pool, ~70% cheaper, preemptible with ~30s notice). Spot T4 provisioned within ~90s on first try; autoscaler fell through to it after the on-demand pool hit backoff.

**Spot taint quirk.** GKE applied a `cloud.google.com/gke-spot=true` **label** to the Spot node but **not** the matching `NoSchedule` taint some docs describe. So the matching toleration is not strictly required for scheduling — only the explicit `nvidia.com/gpu=present:NoSchedule` taint we set on the pool gates placement. Keep the Spot toleration in pod specs as defence-in-depth (future GKE versions may start auto-tainting); it is harmless when the taint is absent.

---

## Session Workflow

### Start of session
```bash
# Create the cluster + GPU pool (GPU pool starts at 0 nodes; T4 provisions on demand)
bash cluster.sh create
```

### Mid-session state check
```bash
bash cluster.sh status
```
GPU node count should be `0` when idle — a T4 provisions only when a pod requesting `nvidia.com/gpu` is scheduled.

### End of session
```bash
# Delete the cluster to stop charges
bash cluster.sh delete
```

Default pool alone costs ~$0.13/hr; a T4 node adds ~$0.35/hr while provisioned. Always delete at session end.

## Scripts

| Script              | What it does                                                                                                                                                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cluster.sh create` | Creates GKE cluster `vllm-gpu-study` in `us-west1-b` with Gateway API + Workload Identity: 1× `e2-standard-4` default pool + two T4 node pools (`gpu-pool-ondemand` and `gpu-pool-spot`, both `n1-standard-4`, autoscale 0–1 total, zones `b,c,a`, `--location-policy=ANY`) |
| `cluster.sh delete` | Deletes the cluster and stops all charges                                                                                                                                                                                                                                 |
| `cluster.sh status` | Shows nodes by pool, accelerator, spot, and zone labels                                                                                                                                                                                                                   |

## Cluster Details

| Field                     | Value                                                                         |
| ------------------------- | ----------------------------------------------------------------------------- |
| Cluster name              | `vllm-gpu-study`                                                              |
| Region / zone             | `us-west1` (Oregon) / `us-west1-b`                                            |
| Default pool              | 1× `e2-standard-4` (4 vCPU, 16 GB RAM), zone `us-west1-b`                     |
| On-demand GPU pool        | `gpu-pool-ondemand`: 1× `n1-standard-4` + NVIDIA T4, `--total-max-nodes=1`    |
| Spot GPU pool             | `gpu-pool-spot`: 1× `n1-standard-4` + NVIDIA T4 (`--spot`), `--total-max-nodes=1` |
| GPU pool zones            | `us-west1-b, us-west1-c, us-west1-a` (with `--location-policy=ANY`)           |
| Global GPU quota          | 1 T4 across all regions → at most one GPU node runs at a time                 |
| GPU taint                 | `nvidia.com/gpu=present:NoSchedule` (on both pools)                           |
| GPU driver install        | `gpu-driver-version=default` (managed by GKE — no manual DaemonSet)           |
| Ingress                   | Gateway API (enabled for future KServe + vLLM composition)                    |
| Workload Identity         | enabled                                                                       |

## Troubleshooting

_To be filled in as issues surface. Known watch-outs:_
- **vLLM image pull time** — multi-GB image, 5–10 min on a cold T4 node. If a pod sits in `ContainerCreating` right after the node provisions, check `kubectl describe pod` for pull progress before assuming a config bug.
- **GPU quota=1** — only one GPU workload at a time. Scale vLLM to 0 before launching a training Job, scale back to 1 after the Job completes.
- **HuggingFace auth** — Phi-2 is open, but gated replacements (Llama, Gemma variants) need `HF_TOKEN` as an env var sourced from a K8s Secret.
