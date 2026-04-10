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
