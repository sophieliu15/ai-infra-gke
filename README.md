# AI Inference Infrastructure on GKE

Hands-on projects exploring AI model serving and inference infrastructure on Google Kubernetes Engine.

## Projects

### [`kserve/`](kserve/)

KServe on GKE with Gateway API — production LLM serving from cluster setup to canary rollouts.

- Automated cluster create/delete scripts and KServe install (Standard Mode, no Knative, no Istio)
- DistilBERT sentiment analysis model served via InferenceService
- Inference via port-forward and GKE Gateway external IP
- Weight-based canary deployments using HTTPRoute `backendRefs` (90/10 traffic split verified end-to-end)
- Two upstream contributions fixing GKE Gateway incompatibilities:
  - HTTPRoute timeout field ([kserve/kserve#5313](https://github.com/kserve/kserve/pull/5313)) — merged
  - HTTPRoute regex path match ([kserve/kserve#5347](https://github.com/kserve/kserve/pull/5347)) — open, with companion docs PR ([kserve/website#646](https://github.com/kserve/website/pull/646))
- Detailed troubleshooting log (9 issues documented with root causes and fixes)

See [`kserve/README.md`](kserve/README.md) for architecture, design decisions, setup instructions, and troubleshooting.

### [`vllm-gpu/`](vllm-gpu/)

vLLM on GKE with NVIDIA T4 — self-hosted LLM serving on provisioned GPU hardware with an OpenAI-compatible API.

- Automated cluster create/delete/status script with T4 GPU pool autoscaling 0–1 and managed driver install (`gpu-driver-version=default`)
- GPU isolation via the taint + toleration + resource request pattern; decision documented with the three-lever mental model
- Planned: `microsoft/phi-2` served via vLLM, throughput/TTFT benchmark across `--max-num-seqs` settings, GPU-accelerated PyTorch training Job, and a KServe + vLLM composition that fronts vLLM with an `InferenceService` from [`kserve/`](kserve/)
- **Status:** in progress — scaffold and design decisions in place; deployment manifests and benchmarks to land next

See [`vllm-gpu/README.md`](vllm-gpu/README.md) for architecture, design decisions, and setup instructions.
