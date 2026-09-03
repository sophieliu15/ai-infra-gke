#!/usr/bin/env bash
# GKE cluster for vLLM + GPU Week 5-8 hands-on (Phase 2).
#
# Region: us-west1 (Oregon). Picked over us-central1 after us-central1-a
# repeatedly returned `FailedScaleUp: GCE out of resources` for on-demand
# T4s on 2026-04-16 — us-central1 is Google's ML hub and is consistently
# contested for older GPU SKUs.
#
# GPU: NVIDIA L4 on g2-standard-4 (migrated from T4/n1-standard-4 on
# 2026-09-03). Three reasons, all pointing the same way:
#   1. T4 has a published GCP end-of-support date of 2027-08-01.
#   2. vLLM's Turing (sm_75) support is decaying — FlashInfer was dropped
#      from SM75 backends in v0.24.0 and newer model families ship with no
#      SM75 kernels at all.
#   3. T4 is fp16-only. The current crop of small open models is bf16-native
#      (Gemma 3 overflows to NaN in fp16), so a T4 quietly disqualifies most
#      of them. L4 is Ada (sm_89) and supports bf16.
# Bonus: L4 is offered in all three us-west1 zones; T4 is only in -a and -b,
# so the three-zone failover design below never actually worked on T4.
#
# Cost while running (one GPU node at a time — global GPU quota = 1):
#   - Default CPU pool:  ~$0.13/hr (1x e2-standard-4)
#   - On-demand L4 pool: ~$0.70/hr per node (no preemption)
#   - Spot L4 pool:      ~$0.22/hr per node (~30s preempt notice)
#   All figures approximate; check current us-west1 pricing before relying
#   on them for a budget estimate.
#
# Stockout resilience: both GPU pools span 3 zones (us-west1-b/c/a) with
# --location-policy=ANY. Cluster autoscaler tries the preferred zone first
# and falls through to other zones on FailedScaleUp.
#
# On-demand-first priority: GKE's cluster autoscaler picks the cheapest
# pool (Spot) by default. To enforce "on-demand first, Spot fallback,"
# `cluster.sh create` applies a Custom Compute Class (compute-class.yaml)
# that lists gpu-pool-ondemand before gpu-pool-spot. Pods opt in via
# `nodeSelector: cloud.google.com/compute-class: gpu-l4`.
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

# G2 is a GPU-attached machine family: g2-standard-4 ships with exactly one
# L4. The --accelerator flag is still required so GKE installs the driver.
GPU_MACHINE_TYPE="g2-standard-4"
GPU_TYPE="nvidia-l4"
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
    --node-labels="gpu=l4,capacity=${capacity}" \
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

  echo "Applying ComputeClass gpu-l4 (on-demand first, Spot fallback)..."
  kubectl apply -f "$(dirname "$0")/compute-class.yaml"

  echo
  echo "Cluster ready. kubectl context set."
  kubectl get nodes
  echo
  echo "Both GPU pools idle at 0 nodes. An L4 provisions only when a pod"
  echo "selects compute-class gpu-l4 and requests nvidia.com/gpu. On-demand"
  echo "is tried first; Spot is used only on FailedScaleUp of on-demand."
  echo "Zone failover within each pool is automatic (--location-policy=ANY)."
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
