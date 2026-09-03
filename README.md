# AI Inference Infrastructure on GKE

Hands-on projects exploring AI model serving and inference infrastructure on Google Kubernetes Engine.

## Projects

### [`kserve/`](kserve/)

KServe on GKE with Gateway API — production ML model serving from cluster setup to canary rollouts.

- Automated cluster setup/teardown and KServe install (Standard Mode, warm pods, no Knative/Istio sidecars)
- DistilBERT sentiment analysis model served via InferenceService
- Inference requests via port-forward and GKE Gateway external IP
- Weight-based canary deployments using HTTPRoute `backendRefs` (90/10 traffic split with model name parity)
- Upstream contribution fixing GKE Gateway timeout incompatibility:
  - HTTPRoute timeout field ([kserve/kserve#5313](https://github.com/kserve/kserve/pull/5313)) — merged
- Detailed troubleshooting log with root cause analysis and fixes

See [`kserve/README.md`](kserve/README.md) for setup instructions, architecture, and troubleshooting.

### [`vllm-gpu/`](vllm-gpu/)

vLLM on GKE with NVIDIA L4 — self-hosted LLM serving on provisioned GPU hardware with an OpenAI-compatible API.

- Automated cluster create/delete/status script with two L4 GPU pools (on-demand + Spot) autoscaling 0–1 and managed driver install (`gpu-driver-version=default`)
- On-demand-first scheduling priority using a GKE Custom Compute Class (`gpu-l4`) with automatic multi-zone failover
- GPU isolation via the taint + toleration + resource request pattern
- `Qwen/Qwen3-4B-Instruct-2507` served via vLLM v0.28.0 on NVIDIA L4 (24 GB VRAM)
- OpenAI-compatible API (`/v1/chat/completions`) and Prometheus metrics scraping (`/metrics`)
- Detailed troubleshooting log (ComputeClass labels, rollout strategies, engine timeouts, K8s service link env conflicts, max-model-len OOMs)

See [`vllm-gpu/README.md`](vllm-gpu/README.md) for setup instructions, architecture, and troubleshooting.
