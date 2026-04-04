#!/usr/bin/env bash
# Install KServe v0.17.0 on an existing GKE cluster.
# Run this after cluster.sh create.

set -euo pipefail

KSERVE_VERSION="v0.17.0"
CERT_MANAGER_VERSION="v1.17.2"

echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "==> Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=180s

echo "==> Creating kserve namespace..."
kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing KServe ${KSERVE_VERSION}..."
# GKE already manages the inference.networking CRDs via kube-addon-manager
# (both .k8s.io and .x-k8s.io variants). Filter them out to avoid conflicts.
#
# kserve.yaml bundles CRDs and resources that reference them (e.g.
# ClusterStorageContainer). The API server may not have indexed the CRDs by the
# time kubectl processes the dependent resources, so we retry up to 3 times.
KSERVE_YAML=$(curl -sL "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml" \
  | python3 -c "
import sys
docs = sys.stdin.read().split('\n---\n')
filtered = [d for d in docs if not (
    'kind: CustomResourceDefinition' in d and 'inference.networking.' in d
)]
print('\n---\n'.join(filtered))
")
for i in 1 2 3; do
  echo "$KSERVE_YAML" | kubectl apply --server-side -f - && break
  echo "    Attempt $i failed — waiting 10s for CRDs to propagate..."
  sleep 10
done

echo "==> Waiting for KServe controller and webhooks to be ready..."
kubectl wait --for=condition=Available deployment --all -n kserve --timeout=180s

echo "==> Applying KServe cluster resources (serving runtimes)..."
# CRDs from kserve.yaml (e.g. ClusterStorageContainer) may not be indexed yet.
# Retry up to 3 times with a short wait for the API server to catch up.
for i in 1 2 3; do
  kubectl apply --server-side \
    -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml" \
    && break
  echo "    Attempt $i failed — waiting 10s for CRDs to propagate..."
  sleep 10
done

echo "==> Configuring Standard Mode + Gateway API..."
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"deploy": "{\"defaultDeploymentMode\": \"Standard\"}"}}'

kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"ingress": "{\"ingressGateway\": \"kserve/kserve-ingress-gateway\", \"enableGatewayApi\": true, \"kserveIngressGateway\": \"kserve/kserve-ingress-gateway\", \"disableIstioVirtualHost\": true, \"disableHTTPRouteTimeout\": true}"}}'

echo ""
echo "==> KServe install complete. Verifying..."
kubectl get pods -n kserve
echo ""
kubectl get crd | grep serving.kserve.io
