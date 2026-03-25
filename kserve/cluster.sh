#!/usr/bin/env bash
# GKE cluster for KServe Week 1-2 hands-on
# Cost: ~$0.40/hr while running (3x e2-standard-4). Delete after each session.

set -euo pipefail

PROJECT_ID="ai-infra-lab-86222"
CLUSTER_NAME="kserve-study"
ZONE="us-central1-a"
MACHINE_TYPE="e2-standard-4"
NUM_NODES=3

create() {
  echo "Creating cluster ${CLUSTER_NAME} in ${ZONE}..."
  gcloud container clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --num-nodes="${NUM_NODES}" \
    --gateway-api=standard \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --no-enable-basic-auth \
    --quiet

  echo "Fetching credentials..."
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}"

  echo "Cluster ready. kubectl context set."
  kubectl get nodes
}

delete() {
  echo "Deleting cluster ${CLUSTER_NAME}..."
  gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --quiet
  echo "Cluster deleted. No further charges."
}

usage() {
  echo "Usage: $0 [create|delete]"
  exit 1
}

case "${1:-}" in
  create) create ;;
  delete) delete ;;
  *)      usage ;;
esac
