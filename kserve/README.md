# KServe on GKE (Standard Mode + Gateway API)

Deploy a real inference workload (`DistilBERT` SST-2 sentiment classifier) on GKE using KServe Standard Mode with GKE Gateway API (native load balancer), featuring warm pod serving, host-based routing, and weighted canary rollouts — without Knative or Istio.

## Architecture

```
┌──────────┐    HTTPS     ┌────────────────┐   HTTPRoute    ┌────────────────────┐
│  Client  │─────────────▶│  GKE Gateway   │───────────────▶│  KServe Predictor  │
└──────────┘              │  (Gateway API) │   host-based   │  (DistilBERT pod)  │
                          └────────────────┘     routing    └────────────────────┘
                                                                      │
                                                                      ▼
                                                            ┌────────────────────┐
                                                            │  HuggingFace model │
                                                            │  (SST-2 fine-tuned)│
                                                            └────────────────────┘
```

- **Cluster:** GKE Standard, `us-central1-a`, Gateway API enabled.
- **Control plane:** KServe v0.17.0 in Standard Mode (warm pods, no Knative/Istio sidecars).
- **Ingress:** GKE Gateway API, host-based routing via HTTPRoute.
- **Model:** `distilbert-base-uncased-finetuned-sst-2-english` served by KServe's HuggingFace runtime.

## Prerequisites

| Requirement | Detail |
| --- | --- |
| GCP project | With billing enabled |
| Tools | `gcloud`, `kubectl`, `curl` |
| Auth | `gcloud auth login` and `gcloud config set project <project-id>` |

### Cluster & Control Plane Specs

| Field | Value |
| --- | --- |
| Cluster name | `kserve-study` |
| Zone | `us-central1-a` |
| Nodes | 3× `e2-standard-4` (4 vCPU, 16 GB RAM each) |
| GKE version | 1.35 |
| KServe version | v0.17.0 |
| Deployment mode | Standard (warm pods, no Knative sidecars) |
| Ingress | GKE Gateway API (`gateway.networking.k8s.io/v1`) |
| Model runtime | KServe HuggingFace Runtime (`sequence_classification` task) |
| Cost | ~$0.40/hr total (3× e2-standard-4). Always delete the cluster when done. |

## Quickstart

### 1. Create the cluster

```bash
bash cluster.sh create
```

This creates a 3-node GKE cluster with Gateway API enabled (`--gateway-api=standard`). Takes ~3–5 minutes.

### 2. Install KServe (Standard Mode)

```bash
bash install.sh
```

Installs cert-manager v1.17.2 and KServe v0.17.0 in Standard Mode with Gateway API configured. Takes ~3–4 minutes.

### 3. Deploy the model

```bash
kubectl apply -f distilbert-isvc.yaml
kubectl wait --for=condition=Ready pod -l serving.kserve.io/inferenceservice=distilbert-v1 --timeout=300s
```

Downloads `distilbert-base-uncased-finetuned-sst-2-english` from HuggingFace and starts the predictor container.

### 4. Send an inference request

#### Option A: Via port-forward (immediate verification)

```bash
# Forward the predictor service to port 8080
kubectl port-forward svc/distilbert-v1-predictor 8080:80 &

# Send prediction request (KServe v1 predict API)
curl -s http://localhost:8080/v1/models/distilbert-v1:predict \
  -H 'Content-Type: application/json' \
  -d '{"instances": ["This movie was absolutely fantastic", "What a terrible waste of time"]}'
```

Expected response:
```json
{"predictions": [1, 0]}
```
(`1` = POSITIVE sentiment, `0` = NEGATIVE sentiment)

#### Option B: Via GKE Gateway (external ingress)

```bash
# Get Gateway external IP
GATEWAY_IP=$(kubectl get gateway kserve-ingress-gateway -n kserve -o jsonpath='{.status.addresses[0].value}')

# Get model hostname from InferenceService status
MODEL_HOST=$(kubectl get inferenceservice distilbert-v1 -o jsonpath='{.status.url}' | sed 's|https\?://||')

# Send request with Host header required for Gateway routing
curl -s http://${GATEWAY_IP}/v1/models/distilbert-v1:predict \
  -H "Host: ${MODEL_HOST}" \
  -H 'Content-Type: application/json' \
  -d '{"instances": ["This movie was absolutely fantastic", "What a terrible waste of time"]}'
```

### 5. (Optional) Run a canary deployment (90/10 traffic split)

In KServe Standard Mode, canary rollouts use weighted HTTPRoute `backendRefs` with a matching `--model_name`.

```bash
# 1. Deploy canary v2 as a standalone Deployment + Service (matching --model_name=distilbert-v1)
kubectl apply -f canary-v2-deployment.yaml
kubectl wait --for=condition=Ready pod -l app=canary-v2-predictor --timeout=300s

# 2. Warm up canary v2
kubectl port-forward svc/canary-v2-predictor 8081:80 &
curl -s http://localhost:8081/v1/models/distilbert-v1:predict -H 'Content-Type: application/json' -d '{"instances": ["warmup"]}'
kill %1

# 3. Apply 90/10 weighted HTTPRoute
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: distilbert-canary
  namespace: default
spec:
  parentRefs:
  - name: kserve-ingress-gateway
    namespace: kserve
  hostnames:
  - "distilbert-canary-default.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: distilbert-v1-predictor
      port: 80
      weight: 90
    - name: canary-v2-predictor
      port: 80
      weight: 10
EOF

# 4. Test traffic distribution
GATEWAY_IP=$(kubectl get gateway kserve-ingress-gateway -n kserve -o jsonpath='{.status.addresses[0].value}')
for i in $(seq 1 20); do
  curl -s "http://$GATEWAY_IP/v1/models/distilbert-v1:predict" \
    -H "Host: distilbert-canary-default.example.com" \
    -H "Content-Type: application/json" \
    -d '{"instances": ["This movie is great"]}'
  echo ""
done

# Check logs to verify split (~90% to v1, ~10% to canary-v2)
kubectl logs -l app=isvc.distilbert-v1-predictor --tail=100 | grep -c "POST /v1"
kubectl logs -l app=canary-v2-predictor --tail=100 | grep -c "POST /v1"
```

To adjust the split (e.g. 50/50):
```bash
kubectl patch httproute distilbert-canary --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
       {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}]'
```

### 6. Tear down

```bash
bash cluster.sh delete
```

Delete the cluster when finished to avoid ongoing charges.

## Troubleshooting

### 1. GKE Gateway API CRD conflict with KServe

**Symptom:** Applying `kserve.yaml` with `--server-side` fails with `Apply failed with 2 conflicts: conflicts with "kube-addon-manager"`, followed by cascading `namespaces "kserve" not found` errors.

**Root cause:** `kserve.yaml` bundles `inference.networking.k8s.io` and `inference.networking.x-k8s.io` CRDs, which GKE already manages when created with `--gateway-api=standard`.

**Fix:** Filter out CRDs containing `inference.networking.` from `kserve.yaml` before applying. `install.sh` handles this automatically. Do **not** use `--force-conflicts` as it strips ownership from GKE's addon manager.

### 2. `kserve.yaml` does not create the `kserve` namespace

**Symptom:** Cluster-scoped resources apply, but namespace-scoped resources fail with `Error from server (NotFound): namespaces "kserve" not found`.

**Root cause:** Official `kserve.yaml` manifests reference `namespace: kserve` on resources but omit a `kind: Namespace` definition.

**Fix:** Explicitly create the namespace first: `kubectl create namespace kserve` (handled by `install.sh`).

### 3. KServe webhook not ready when applying cluster resources

**Symptom:** `failed calling webhook "clusterservingruntime.kserve-webhook-server.validator": no endpoints available for service "kserve-webhook-server-service"`.

**Root cause:** Applying `kserve-cluster-resources.yaml` before the webhook pod in the `kserve` namespace has finished starting.

**Fix:** Wait for all deployments in `kserve` to be ready:
```bash
kubectl wait --for=condition=Available deployment --all -n kserve --timeout=300s
```

### 4. `ClusterStorageContainer` not recognized on first install

**Symptom:** `error: unable to recognize "STDIN": no matches for kind "ClusterStorageContainer" in version "serving.kserve.io/v1alpha1"`.

**Root cause:** CRDs and CRD instances are applied in the same manifest. The API server has not indexed the newly registered CRD when the instance is evaluated.

**Fix:** Re-run `install.sh`. On the second pass, the CRD is registered and the resource applies cleanly.

### 5. InferenceService stuck: `ingressGateway is required`

**Symptom:** Reconciler fails with `invalid ingress config - ingressGateway is required`. No predictor pod is created.

**Root cause:** When Gateway API is enabled in `inferenceservice-config`, KServe still validates that legacy `ingressGateway` is non-empty.

**Fix:** Provide `ingressGateway` in the ingress patch alongside `enableGatewayApi: true` and `disableIstioVirtualHost: true`:
```json
{
  "ingressGateway": "kserve/kserve-ingress-gateway",
  "enableGatewayApi": true,
  "kserveIngressGateway": "kserve/kserve-ingress-gateway",
  "disableIstioVirtualHost": true
}
```

### 6. HuggingFace `storageUri` format invalid

**Symptom:** `Invalid Hugging Face URI format. Expected 'hf://owner/model[:revision]', got 'hf://distilbert-base-uncased-finetuned-sst-2-english'`.

**Root cause:** KServe's storage-initializer requires the owner prefix in the URI.

**Fix:** Always include the owner: `hf://distilbert/distilbert-base-uncased-finetuned-sst-2-english`.

### 7. HuggingFace task name unsupported

**Symptom:** `Unsupported task: text-classification. Currently supported tasks are: ... sequence_classification ...`.

**Root cause:** KServe's HuggingFace server uses internal enum names rather than HuggingFace pipeline API names.

**Fix:** Pass `--task=sequence_classification` in the InferenceService container args.

### 8. GKE Gateway rejects KServe HTTPRoutes with timeouts

**Symptom:** HTTPRoute `Accepted: False` with reason `UnsupportedValue`. InferenceService remains `IngressReady: False` and assigns no external URL.

**Root cause:** KServe hardcodes `timeouts: {request: 60s}` on generated HTTPRoutes. GKE Gateway API controller does not implement `spec.rules.timeouts` and rejects the spec.

**Fix:** Configure `disableHTTPRouteTimeout: true` in `inferenceservice-config`:
```json
{
  "enableGatewayApi": true,
  "kserveIngressGateway": "kserve/kserve-ingress-gateway",
  "disableHTTPRouteTimeout": true
}
```
*(Note: Requires KServe v0.17+ containing merged PR [#5313](https://github.com/kserve/kserve/pull/5313)).*

## How it works

### Standard Mode + Gateway API vs Knative

KServe supports two serving architectures. **Standard Mode with Gateway API** is used here instead of default Knative/serverless mode:

| Concern | Knative (Serverless) | Standard Mode + Gateway API | Why it matters for LLM/ML serving |
| --- | --- | --- | --- |
| **Cold starts** | Scales to zero; cold requests wait for pod startup + model load | Pods stay warm; zero cold-start latency | Multi-GB model loading into VRAM/RAM takes seconds to minutes. Unacceptable for interactive inference. |
| **Sidecar overhead** | Requires Istio sidecar per pod | No sidecars needed | Sidecars consume CPU/RAM competing with model memory on node. |
| **Long connections** | Request/response focus; prone to Knative timeouts | Native support for streaming/persistent connections | Token streaming (SSE/WebSockets) requires persistent HTTP connections. |
| **Operational stack** | Knative Serving + Istio/Kourier + KServe | KServe + Gateway API controller | Fewer moving parts to debug when scheduling or loading models. |
| **Resource cost** | Scale-to-zero drops GPU node; scale-up reloads multi-GB model | Persistent warm allocations | Reloading multi-GB weights on every scale-up wastes compute time and GPU budget. |

**Tradeoff:** Knative natively supports `canaryTrafficPercent`. In Standard Mode, canary rollouts require weighted HTTPRoute `backendRefs`.

### Canary design & model name parity

In KServe Standard Mode, KServe's inference protocol includes the model name in the URL path (`/v1/models/<name>:predict`).

If traffic is split between two separate `InferenceService` specs with different names (`distilbert-v1` vs `distilbert-v2`), requests routed to the `v2` pod for `/v1/models/distilbert-v1:predict` return a `404 Not Found`.

**Design Pattern:**
1. Deploy `distilbert-v1` as the primary `InferenceService`.
2. Deploy the canary `v2` as a standalone `Deployment` + `Service` passing `--model_name=distilbert-v1` (matching the primary model name).
3. Bind both backend services to a single weighted `HTTPRoute`.

### Upstream contribution: GKE Gateway HTTPRoute timeout fix

- **PR:** [kserve/kserve#5313](https://github.com/kserve/kserve/pull/5313) (Merged)
- **Issue:** [kserve/kserve#5311](https://github.com/kserve/kserve/issues/5311)
- **Details:** Added `DisableHTTPRouteTimeout` config flag to KServe's `IngressConfig` and `resolveTimeout()` helper across `httproute_reconciler.go`. Allows KServe to omit the `timeouts` field when deploying on controllers (like GKE Gateway) that do not support spec-level timeouts.

## Scripts

| Script | What it does |
| --- | --- |
| `cluster.sh create` | Creates GKE cluster `kserve-study` (3× `e2-standard-4`, `us-central1-a`, Gateway API enabled) |
| `cluster.sh delete` | Deletes the cluster and stops all charges |
| `install.sh` | Installs cert-manager v1.17.2 and KServe v0.17.0 in Standard Mode with Gateway API |