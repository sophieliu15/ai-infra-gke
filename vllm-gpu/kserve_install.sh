#!/usr/bin/env bash
# Install KServe v0.20.0 on an existing GKE cluster for vllm-gpu experiments.
# Run this after cluster.sh create.

set -euo pipefail

KSERVE_VERSION="v0.20.0"
CERT_MANAGER_VERSION="v1.17.0"

echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "==> Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=180s

echo "==> Creating kserve namespace..."
kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing KServe ${KSERVE_VERSION} with refined CRD filtering..."
# GKE already manages Gateway API and inferencepools.inference.networking.k8s.io (v1)
# via kube-addon-manager. We must filter out inferencepools.inference.networking.k8s.io
# while retaining inferencepools.inference.networking.x-k8s.io (v1alpha2) which
# KServe's llmisvc controller requires.
KSERVE_YAML=$(curl -sL "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml" \
  | python3 -c "
import sys
docs = sys.stdin.read().split('\n---\n')
filtered = []
for d in docs:
    if 'kind: CustomResourceDefinition' in d and 'name: inferencepools.inference.networking.k8s.io' in d:
        continue
    filtered.append(d)
print('\n---\n'.join(filtered))
")

echo "==> Applying filtered KServe manifests (server-side apply with retry)..."
for i in 1 2 3; do
  echo "$KSERVE_YAML" | kubectl apply --server-side -f - && break
  echo "    Attempt $i failed — waiting 10s for CRDs to propagate..."
  sleep 10
done

echo "==> Waiting for KServe controllers to be ready..."
for d in kserve-controller-manager llmisvc-controller-manager kserve-localmodel-controller-manager; do
  echo "Checking deployment/$d..."
  kubectl wait --for=condition=Available "deployment/$d" -n kserve --timeout=300s || \
    kubectl describe "deployment/$d" -n kserve
done

echo "==> Applying KServe cluster resources (serving runtimes)..."
for i in 1 2 3; do
  kubectl apply --server-side \
    -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml" \
    && break
  echo "    Attempt $i failed — waiting 10s for CRDs to propagate..."
  sleep 10
done

echo "==> Verifying kserve-vllmserver ClusterServingRuntime..."
kubectl patch clusterservingruntime kserve-vllmserver --type=json \
  -p '[{"op": "replace", "path": "/spec/containers/0/command/0", "value": "python3"}]'
kubectl get clusterservingruntime kserve-vllmserver -o yaml | head -n 35

echo "==> Configuring Standard Deployment Mode and Storage Initializer..."
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"deploy": "{\"defaultDeploymentMode\": \"Standard\"}"}}'

kubectl patch configmap/inferenceservice-config -n kserve --type=merge -p '{
  "data": {
    "storageInitializer": "{\"image\":\"kserve/storage-initializer:v0.20.0\",\"memoryRequest\":\"1Gi\",\"memoryLimit\":\"4Gi\",\"cpuRequest\":\"500m\",\"cpuLimit\":\"2\",\"caBundleConfigMapName\":\"\",\"caBundleVolumeMountPath\":\"/etc/ssl/custom-certs\",\"enableModelcar\":true,\"cpuModelcar\":\"10m\",\"memoryModelcar\":\"15Mi\",\"uidModelcar\":1010}",
    "ingress": "{\"enableGatewayApi\":false,\"kserveIngressGateway\":\"kserve/kserve-ingress-gateway\",\"ingressGateway\":\"knative-serving/knative-ingress-gateway\",\"localGateway\":\"knative-serving/knative-local-gateway\",\"localGatewayService\":\"knative-local-gateway.istio-system.svc.cluster.local\",\"ingressDomain\":\"example.com\",\"ingressClassName\":\"istio\",\"domainTemplate\":\"{{ .Name }}-{{ .Namespace }}.{{ .IngressDomain }}\",\"urlScheme\":\"http\",\"disableIstioVirtualHost\":true,\"disableIngressCreation\":false,\"disableHTTPRouteTimeout\":false}"
  }
}'

echo "==> Patching ClusterStorageContainer default resources (4Gi memory limit)..."
kubectl patch clusterstoragecontainer default --type=merge -p '{
  "spec": {
    "container": {
      "resources": {
        "limits": {"cpu": "2", "memory": "4Gi"},
        "requests": {"cpu": "500m", "memory": "1Gi"}
      }
    }
  }
}'

echo "==> Restarting kserve-controller-manager to load updated config..."
kubectl rollout restart deployment kserve-controller-manager -n kserve
kubectl rollout status deployment kserve-controller-manager -n kserve --timeout=180s

echo ""
echo "==> KServe v0.20.0 install complete! Controller status:"
kubectl get pods -n kserve
echo ""
echo "CRDs installed:"
kubectl get crd | grep -E 'serving.kserve.io|inference.networking'
