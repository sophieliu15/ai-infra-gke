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
- **GPU pools (two):** on-demand T4 pool + Spot T4 pool, both spanning `us-west1-b/c/a` with `--location-policy=ANY`. Zone failover on `FailedScaleUp` is automatic. On-demand-vs-Spot priority is enforced by a [GKE Custom Compute Class](#on-demand-first-priority-custom-compute-class) (`compute-class.yaml`) that lists `gpu-pool-ondemand` before `gpu-pool-spot`; pods opt in via `nodeSelector: cloud.google.com/compute-class: gpu-t4`. Global T4 quota = 1 → at most one GPU node runs at a time.
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

**Heads up: the GKE cluster autoscaler picks the *cheapest* pool first by default, which is Spot — not on-demand.** Per the [GKE autoscaler docs](https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler), it "attempts to expand the least expensive possible node pool." The Spot-specific toleration that older GKE docs mention is not required either: current GKE versions apply `cloud.google.com/gke-spot=true` as a **label** only (no matching `NoSchedule` taint), so only the explicit `nvidia.com/gpu` taint gates placement. On-demand-first priority is therefore imposed explicitly via a Custom Compute Class (next section).

### On-demand-first priority: Custom Compute Class

`compute-class.yaml` defines a `ComputeClass` named `gpu-t4` with two priority entries — `gpu-pool-ondemand` first, `gpu-pool-spot` second. The autoscaler walks the list top-to-bottom: on `FailedScaleUp` for the on-demand pool (stockout, no inventory, zone failures exhausted), it falls through to Spot automatically. Pods opt in with a single line:

```yaml
spec:
  nodeSelector:
    cloud.google.com/compute-class: gpu-t4
```

Design choices:

| Field                          | Value                              | Why                                                                                                               |
| ------------------------------ | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `priorities[0].nodepools`      | `[gpu-pool-ondemand]`              | Preferred pool. No preemption, predictable benchmarks.                                                            |
| `priorities[1].nodepools`      | `[gpu-pool-spot]`                  | Fallback only. Used when on-demand returns `FailedScaleUp` across all three zones.                                |
| `nodePoolAutoCreation.enabled` | `false`                            | Both pools are already created by `cluster.sh`. Don't let CCC provision extras behind my back on a quota=1 cluster. |
| `whenUnsatisfiable`            | `DoNotScaleUp`                     | If both pools fail, leave the pod `Pending` rather than placing it on the default CPU pool (which has no GPU anyway, but keeps intent explicit). |

Alternatives considered and ruled out: the [priority expander](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/expander/priority/readme.md) isn't configurable on GKE's managed autoscaler; a Spot-pool taint + opt-in toleration is simpler but gives a hard gate, not a fallback — a stocked-out on-demand pool leaves the pod `Pending` until you edit the pod spec.

### Other decisions
_To be filled in: vLLM image pinning (not `latest`), prefix-caching on/off rationale._

## GPU smoketest walkthrough

Before deploying anything real (vLLM, training Jobs), run a minimal CUDA pod that only calls `nvidia-smi`. Four independent things have to work for a GPU workload to schedule, and each can fail silently on a fresh cluster:

1. **Autoscaler scale-up** — the GPU pool is 0 nodes when idle; the pending pod has to trigger provisioning of a T4 node in a zone with capacity.
2. **GPU driver install** — `gpu-driver-version=default` tells GKE to install the NVIDIA driver before the node registers as Ready. A misconfigured pool can come up Ready without a driver.
3. **Taint / toleration match** — the `nvidia.com/gpu=present:NoSchedule` taint on the pool has to be cleared by a pod toleration.
4. **GPU advertisement** — the node has to report `nvidia.com/gpu: 1` in its `Capacity` so the scheduler places the pod and the device plugin hands the GPU to the container.

The smoketest exercises all four in ~2 minutes for ~$0.003 per run. Running it at the start of a session catches pool-config regressions before a 5–10 min vLLM image pull makes diagnostics painful.

### Run it

```bash
# 1. Create the cluster (default pool Ready, GPU pools idle at 0 nodes,
#    ComputeClass gpu-t4 applied)
bash cluster.sh create

# 2. Apply the smoketest pod — selects compute-class gpu-t4 and triggers
#    the on-demand T4 scale-up (Spot only if on-demand is stocked out)
kubectl apply -f gpu-smoketest.yaml

# 3. Watch the provisioning
kubectl get pods -w
kubectl get nodes -w                          # in a second pane
kubectl describe pod gpu-smoketest            # for autoscaler events

# 4. Verify the GPU is advertised + the container sees it
kubectl describe node <gpu-node>              # Capacity.nvidia.com/gpu: 1
kubectl logs gpu-smoketest                    # nvidia-smi output
```

### What to look for at each stage

The progression should be: **pod `Pending`** → autoscaler `TriggeredScaleUp` event → **new node `NotReady`** (driver installing) → **node `Ready`** with `nvidia.com/gpu: 1` in `Capacity` → **pod `Running`** → `nvidia-smi` prints the T4.

Expected output (from the 2026-04-16 run):

```
# kubectl get pods
POD             NODE                                             STATUS
gpu-smoketest   gke-vllm-gpu-study-gpu-pool-spot-*               Running

# kubectl get nodes -L ... (pool, spot, accelerator)
NAME                                         POOL            SPOT   GPU
gke-vllm-gpu-study-gpu-pool-spot-*           gpu-pool-spot   true   nvidia-tesla-t4
```

```
# kubectl describe node <gpu-node>
Taints:    nvidia.com/gpu=present:NoSchedule
Capacity:  nvidia.com/gpu: 1
```

```
# kubectl logs gpu-smoketest
Tesla T4 | Driver 580.105.08 | CUDA 13.0 | 15360 MiB
```

### What might go wrong

- **`FailedScaleUp: GCE out of resources`** — GCE is out of T4 inventory in the target zones. Quota is a ceiling, not a reservation; an approved quota can still return `out of resources`. See [Two-pool GPU setup + multi-zone failover](#two-pool-gpu-setup--multi-zone-failover) — multi-zone `--location-policy=ANY` handles zone-level stockouts within a pool, the ComputeClass falls through from on-demand to Spot across pools, and region-level stockouts (`us-central1` for T4) argue for switching to `us-west1` or swapping T4→L4. *Worked example:* the 2026-04-16 smoketest hit exactly this in `us-central1-a` — on-demand backed off three times, a new Spot T4 pool then provisioned in ~90s on the first try (separate inventory). That session is why this project now defaults to `us-west1` with a two-pool config and a Custom Compute Class for explicit priority.
- **Node `Ready` but `nvidia.com/gpu` missing from `Capacity`** — driver install didn't run. Verify `gpu-driver-version=default` on the pool; without it, GKE expects you to run the NVIDIA DaemonSet yourself.
- **Pod stuck `Pending` with `untolerated taint`** — the pod spec is missing the `nvidia.com/gpu` toleration, or the pool taint doesn't match. GKE auto-injects the toleration when a pod requests `nvidia.com/gpu`, so this usually means the resource request itself is missing.
- **Spot toleration surprise.** Modern GKE applies `cloud.google.com/gke-spot=true` as a **label only**, not the matching `NoSchedule` taint older docs describe. The Spot toleration in `gpu-smoketest.yaml` is therefore defence-in-depth — harmless today, forward-compatible if GKE restores auto-tainting.

### Teardown

```bash
kubectl delete -f gpu-smoketest.yaml   # optional; cluster delete covers it
bash cluster.sh delete
```

Default pool alone costs ~$0.13/hr; a T4 node adds ~$0.35/hr on-demand (~$0.11/hr Spot). Always delete at session end.

## Scripts

| Script              | What it does                                                                                                                                                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cluster.sh create` | Creates GKE cluster `vllm-gpu-study` in `us-west1-b` with Gateway API + Workload Identity: 1× `e2-standard-4` default pool + two T4 node pools (`gpu-pool-ondemand` and `gpu-pool-spot`, both `n1-standard-4`, autoscale 0–1 total, zones `b,c,a`, `--location-policy=ANY`), then applies `compute-class.yaml` so pods get on-demand-first priority with Spot fallback |
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
| Pool priority             | ComputeClass `gpu-t4` — on-demand first, Spot fallback on `FailedScaleUp`     |
| GPU driver install        | `gpu-driver-version=default` (managed by GKE — no manual DaemonSet)           |
| Ingress                   | Gateway API (enabled for future KServe + vLLM composition)                    |
| Workload Identity         | enabled                                                                       |

## Troubleshooting

_To be filled in as issues surface. Known watch-outs:_
- **vLLM image pull time** — multi-GB image, 5–10 min on a cold T4 node. If a pod sits in `ContainerCreating` right after the node provisions, check `kubectl describe pod` for pull progress before assuming a config bug.
- **GPU quota=1** — only one GPU workload at a time. Scale vLLM to 0 before launching a training Job, scale back to 1 after the Job completes.
- **HuggingFace auth** — Phi-2 is open, but gated replacements (Llama, Gemma variants) need `HF_TOKEN` as an env var sourced from a K8s Secret.
