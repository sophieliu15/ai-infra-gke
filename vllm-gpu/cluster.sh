#!/usr/bin/env bash
# GKE cluster for vLLM + GPU Week 5-8 hands-on (Phase 2).
#
# Region: us-west1 (Oregon). Picked over us-central1 after us-central1-a
# repeatedly returned `FailedScaleUp: GCE out of resources` for on-demand
# T4s on 2026-04-16 — us-central1 is Google's ML hub and is consistently
# contested for older GPU SKUs.
#
# Cost while running (one GPU node at a time — global T4 quota = 1):
#   - Default CPU pool:  ~$0.13/hr (1x e2-standard-4)
#   - On-demand T4 pool: ~$0.35/hr per node (no preemption)
#   - Spot T4 pool:      ~$0.10/hr per node (~30s preempt notice)
#
# Stockout resilience: both GPU pools span 3 zones (us-west1-b/c/a) with
# --location-policy=ANY. Cluster autoscaler tries the preferred zone first
# and falls through to other zones on FailedScaleUp. GKE also prefers the
# non-Spot pool when both pools can satisfy a pending pod, so Spot only
# takes traffic if on-demand is out across all zones.
#
# Always delete the cluster at session end — default pool keeps billing
# even when both GPU pools are idle at 0 nodes.

set -euo pipefail

PROJECT_ID="ai-infra-lab-86222"
CLUSTER_NAME="vllm-gpu-study"
ZONE="us-west1-b"
# Multi-zone locations for GPU pools. us-west1-b listed first as the
# preferred zone; autoscaler falls through to c, then a on stockout.
GPU_NODE_LOCATIONS="us-west1-b,us-west1-c,us-west1-a"

DEFAULT_MACHINE_TYPE="e2-standard-4"
DEFAULT_NUM_NODES=1

GPU_MACHINE_TYPE="n1-standard-4"
GPU_TYPE="nvidia-tesla-t4"
GPU_COUNT=1
GPU_TAINT="nvidia.com/gpu=present:NoSchedule"

ONDEMAND_POOL="gpu-pool-ondemand"
SPOT_POOL="gpu-pool-spot"

# $1=pool name, $2=capacity label value (ondemand|spot), $3=extra flags (e.g. "--spot" or "")
create_gpu_pool() {
  local pool_name="$1"
  local capacity="$2"
  local extra="$3"
  echo "Adding GPU pool ${pool_name} (${capacity}, zones: ${GPU_NODE_LOCATIONS})..."
  # shellcheck disable=SC2086
  gcloud container node-pools create "${pool_name}" \
    --cluster="${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --node-locations="${GPU_NODE_LOCATIONS}" \
    --machine-type="${GPU_MACHINE_TYPE}" \
    --accelerator="type=${GPU_TYPE},count=${GPU_COUNT},gpu-driver-version=default" \
    --enable-autoscaling \
    --location-policy=ANY \
    --num-nodes=0 \
    --total-min-nodes=0 \
    --total-max-nodes=1 \
    --node-taints="${GPU_TAINT}" \
    --node-labels="gpu=t4,capacity=${capacity}" \
    ${extra} \
    --quiet
}

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

  create_gpu_pool "${ONDEMAND_POOL}" "ondemand" ""
  create_gpu_pool "${SPOT_POOL}"     "spot"     "--spot"

  echo "Fetching credentials..."
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}"

  echo
  echo "Cluster ready. kubectl context set."
  kubectl get nodes
  echo
  echo "Both GPU pools idle at 0 nodes. A T4 provisions only when a pod requests"
  echo "nvidia.com/gpu with toleration matching '${GPU_TAINT}'. Autoscaler"
  echo "prefers on-demand over Spot and us-west1-b over other zones; falls"
  echo "through on 'GCE out of resources'."
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
  echo "Nodes (by pool + accelerator + spot + zone):"
  kubectl get nodes \
    -L cloud.google.com/gke-nodepool \
    -L cloud.google.com/gke-accelerator \
    -L cloud.google.com/gke-spot \
    -L topology.kubernetes.io/zone
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
