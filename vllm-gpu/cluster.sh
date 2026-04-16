#!/usr/bin/env bash
# GKE cluster for vLLM + GPU Week 5-8 hands-on (Phase 2).
#
# Cost while running:
#   - Default CPU pool: ~$0.13/hr (1x e2-standard-4). Single node — no HA,
#     but this cluster is recreated every session so HA is irrelevant.
#   - GPU pool: ~$0.35/hr per T4 node (on-demand). Autoscales 0-1; a T4 only
#     provisions when a pod requesting nvidia.com/gpu with a matching
#     toleration is scheduled.
#
# Delete the cluster at the end of each session to avoid creep — even with
# the GPU pool at 0, the default pool keeps billing.

set -euo pipefail

PROJECT_ID="ai-infra-lab-86222"
CLUSTER_NAME="vllm-gpu-study"
ZONE="us-central1-a"

# Default CPU pool (system workloads, Gateway API controller, KServe control plane).
DEFAULT_MACHINE_TYPE="e2-standard-4"
DEFAULT_NUM_NODES=1

# GPU pool (quota-capped at 1 T4 as of 2026-04-13 — see Phase 2 Plan).
GPU_POOL_NAME="gpu-pool"
GPU_MACHINE_TYPE="n1-standard-4"
GPU_TYPE="nvidia-tesla-t4"
GPU_COUNT=1
GPU_TAINT="nvidia.com/gpu=present:NoSchedule"

create() {
  echo "Creating cluster ${CLUSTER_NAME} in ${ZONE}..."
  gcloud container clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${DEFAULT_MACHINE_TYPE}" \
    --num-nodes="${DEFAULT_NUM_NODES}" \
    --gateway-api=standard \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --no-enable-basic-auth \
    --quiet

  echo "Adding GPU node pool ${GPU_POOL_NAME} (autoscaling 0-1, driver auto-install)..."
  gcloud container node-pools create "${GPU_POOL_NAME}" \
    --cluster="${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${GPU_MACHINE_TYPE}" \
    --accelerator="type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=default" \
    --enable-autoscaling \
    --num-nodes=0 \
    --min-nodes=0 \
    --max-nodes=1 \
    --node-taints="${GPU_TAINT}" \
    --node-labels="gpu=t4" \
    --quiet

  echo "Fetching credentials..."
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}"

  echo
  echo "Cluster ready. kubectl context set."
  kubectl get nodes
  echo
  echo "GPU pool starts at 0 nodes. A T4 provisions only when a pod requests"
  echo "nvidia.com/gpu with toleration matching '${GPU_TAINT}'."
}

delete() {
  echo "Deleting cluster ${CLUSTER_NAME}..."
  gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --quiet
  echo "Cluster deleted. No further charges."
}

status() {
  echo "Nodes (by pool + accelerator):"
  kubectl get nodes \
    -L cloud.google.com/gke-nodepool \
    -L cloud.google.com/gke-accelerator
  echo
  local gpu_count
  gpu_count=$(kubectl get nodes -l cloud.google.com/gke-accelerator -o name 2>/dev/null | wc -l | tr -d ' ')
  echo "GPU nodes currently provisioned: ${gpu_count} (should be 0 when no GPU pods scheduled)"
}

usage() {
  echo "Usage: $0 [create|delete|status]"
  exit 1
}

case "${1:-}" in
  create) create ;;
  delete) delete ;;
  status) status ;;
  *)      usage ;;
esac
