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

- **Cluster:** GKE Standard, `us-central1-a`. Default pool: 1× `e2-standard-4` (single node — cluster is torn down after each session, HA not required). GPU pool: 1× `n1-standard-4` + NVIDIA T4, autoscaling 0–1 (quota-capped at 1 T4).
- **GPU isolation:** taint `nvidia.com/gpu=present:NoSchedule` on the GPU pool — only tolerating pods land there.
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

### Other decisions
_To be filled in: GPU pool autoscaling 0–1 over static provisioning, vLLM image pinning (not `latest`), prefix-caching on/off rationale._

## Outcomes

_To be filled in as vLLM deploy, load benchmark, and KServe+vLLM bridge land._

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

| Script              | What it does                                                                                                                                                                                                            |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cluster.sh create` | Creates GKE cluster `vllm-gpu-study` (1x `e2-standard-4` default pool + GPU node pool: 1x `n1-standard-4` + T4, autoscaling 0–1, Gateway API enabled, taint `nvidia.com/gpu=present:NoSchedule`, driver auto-installed) |
| `cluster.sh delete` | Deletes the cluster and stops all charges                                                                                                                                                                               |
| `cluster.sh status` | Shows nodes by pool and current GPU node count (should be 0 when no GPU pods scheduled)                                                                                                                                 |

## Cluster Details

| Field              | Value                                                               |
| ------------------ | ------------------------------------------------------------------- |
| Cluster name       | `vllm-gpu-study`                                                    |
| Zone               | `us-central1-a`                                                     |
| Default pool       | 1x `e2-standard-4` (4 vCPU, 16 GB RAM)                              |
| GPU pool           | 1x `n1-standard-4` + NVIDIA T4 (autoscaling 0–1, quota-capped)      |
| GPU taint          | `nvidia.com/gpu=present:NoSchedule`                                 |
| GPU driver install | `gpu-driver-version=default` (managed by GKE — no manual DaemonSet) |
| Ingress            | Gateway API (enabled for future KServe + vLLM composition)          |
| Workload Identity  | enabled                                                             |

## Troubleshooting

_To be filled in as issues surface. Known watch-outs:_
- **vLLM image pull time** — multi-GB image, 5–10 min on a cold T4 node. If a pod sits in `ContainerCreating` right after the node provisions, check `kubectl describe pod` for pull progress before assuming a config bug.
- **GPU quota=1** — only one GPU workload at a time. Scale vLLM to 0 before launching a training Job, scale back to 1 after the Job completes.
- **HuggingFace auth** — Phi-2 is open, but gated replacements (Llama, Gemma variants) need `HF_TOKEN` as an env var sourced from a K8s Secret.
