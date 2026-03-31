# AI Inference Infrastructure on GKE

Hands-on projects exploring AI model serving and inference infrastructure on Google Kubernetes Engine.

## GCP Project

| Field | Value |
|---|---|
| Project ID | `ai-infra-lab-86222` |
| Region | `us-central1` |
| Budget guard | $50/month with auto-disable via Cloud Function |

## Projects

### [`kserve/`](kserve/)

KServe on GKE with Gateway API — from cluster setup to external inference.

- Automated cluster create/delete scripts and KServe install (Standard Mode, no Knative)
- DistilBERT sentiment analysis model served via InferenceService
- Inference via port-forward and GKE Gateway external IP
- Two upstream contributions fixing GKE Gateway incompatibilities:
  - HTTPRoute timeout field ([kserve/kserve#5313](https://github.com/kserve/kserve/pull/5313)) — PR merged
  - RegularExpression path match ([kserve/kserve#5319](https://github.com/kserve/kserve/issues/5319)) — in progress
- Detailed troubleshooting log (9 issues documented with root causes and fixes)

See [`kserve/README.md`](kserve/README.md) for full setup instructions, inference examples, and troubleshooting.
