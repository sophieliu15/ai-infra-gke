# KServe on GKE

A hands-on study of production LLM/ML serving on Google Kubernetes Engine. This project runs a real inference workload (DistilBERT SST-2 sentiment classifier) on GKE using KServe's Standard Mode with Gateway API, exposed through a native GKE load balancer, with canary rollouts — all without Knative or Istio.

Along the way, I discovered two incompatibilities between KServe v0.17 and GKE's Gateway API controller, fixed both in a fork, and upstreamed the fixes as pull requests.

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

- **Cluster:** GKE Standard, 3× `e2-standard-4` nodes, Gateway API enabled.
- **Control plane:** KServe v0.17.0 in Standard Mode (no Knative, no Istio).
- **Ingress:** GKE Gateway API (native load balancer), host-based routing via HTTPRoute.
- **Model:** `distilbert-base-uncased-finetuned-sst-2-english` served by KServe's HuggingFace runtime.

## Upstream contributions

Two incompatibilities between KServe v0.17 and GKE Gateway API, both fixed in a fork and upstreamed:

**1. HTTPRoute timeout field rejected by GKE Gateway** — [kserve/kserve#5313 (merged)](https://github.com/kserve/kserve/pull/5313)
- KServe hardcoded `timeouts: {request: 60s}` on every HTTPRoute. GKE's Gateway controller does not implement `spec.rules.timeouts` and rejected the route with `UnsupportedValue`. Manual patches were reverted by the reconciler loop.
- **Fix:** added a `DisableHTTPRouteTimeout` config flag to `IngressConfig`, introduced a `resolveTimeout()` helper, and updated all 9 timeout blocks in `httproute_reconciler.go`. New unit tests added. Default behavior unchanged.
- Issue: [kserve/kserve#5311](https://github.com/kserve/kserve/issues/5311) · Analysis: [httproute-timeout-analysis.md](httproute-timeout-analysis.md) · Test report: [disable-httproute-timeout-test-report.md](disable-httproute-timeout-test-report.md)

**2. HTTPRoute regex path match rejected by GKE Gateway** — [kserve/kserve#5347 (open)](https://github.com/kserve/kserve/pull/5347)
- KServe's `createHTTPRouteMatch()` hardcoded `PathMatchRegularExpression` with pattern `^/.*$` (9 call sites). GKE Gateway only supports regex at Extended conformance and rejected the route with `GWCER104`. The dominant pattern is functionally equivalent to `PathPrefix: /`.
- **Fix:** added a `pathMatchType` config flag, `resolvePathMatch()` helper, updated all 9 call sites. 23 files changed across Go code, 11 Helm chart sources, configmaps, quick-install scripts, and OpenAPI/Python SDK artifacts. Same pattern as #5313.
- Issue: [kserve/kserve#5319](https://github.com/kserve/kserve/issues/5319) · Docs PR: [kserve/website#646](https://github.com/kserve/website/pull/646) · Analysis: [httproute-regex-path-analysis.md](httproute-regex-path-analysis.md) · Test report: [path-match-type-test-report.md](path-match-type-test-report.md)

## Key decisions

- **Standard Mode + Gateway API over Knative** — no cold starts on multi-GB LLMs, no Istio sidecar overhead on expensive GPU nodes, native support for long-lived streaming connections.
- **Canary via manual HTTPRoute weights, not `canaryTrafficPercent`** — the KServe field only works in Knative mode ([kserve/kserve#5335](https://github.com/kserve/kserve/issues/5335)). In Standard Mode I used weighted `backendRefs` and discovered the model-name-parity requirement the hard way (see the [Canary Deployments](#canary-deployments-weight-based-traffic-splitting) section).
- **Self-healing install script** — `install.sh` handles GKE-managed CRD conflicts, `kserve` namespace creation, webhook-readiness timing, and CRD-propagation races on `ClusterStorageContainer`.

### Why Standard Mode + Gateway API (not Knative)

KServe supports two deployment modes. We chose **Standard Mode with Gateway API** over the default Knative/serverless mode for several reasons:

| Concern                      | Knative (Serverless)                                                                            | Standard + Gateway API                                                  | Why it matters for LLMs                                                                                                                                    |
| ---------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Cold starts**              | Scales to zero — first request waits for pod startup + model load (seconds to minutes for LLMs) | Pods stay warm, no cold-start latency                                   | LLMs are multi-GB; loading into GPU memory takes 30s–5min. Unacceptable for user-facing inference.                                                         |
| **Sidecar overhead**         | Requires Istio sidecar injection — adds memory/CPU per pod, complicates networking              | No sidecars needed                                                      | GPU nodes are expensive — sidecar memory overhead competes with model memory.                                                                              |
| **Long-running connections** | Designed for request/response; streaming and long inference calls can hit Knative timeouts      | Native support for long-lived connections (important for LLM streaming) | LLM token streaming (SSE/WebSocket) requires persistent connections that outlast Knative's request timeout model.                                          |
| **Operational complexity**   | Must install and manage Knative Serving + Istio (or Kourier) + KServe                           | Just KServe + cert-manager — fewer moving parts                         | Fewer components to debug when GPU scheduling or model loading fails.                                                                                      |
| **GPU resource efficiency**  | Scale-to-zero means losing expensive GPU allocation; scale-up means re-loading multi-GB models  | Persistent pods keep models in GPU memory                               | A single A100 costs ~$2/hr — reloading a 70B model on every scale-up wastes both time and money. Keeping the pod warm is cheaper than repeated cold loads. |

**Tradeoff:** Knative mode has better built-in canary support (`canaryTrafficPercent` field works natively). In Standard Mode, canary rollouts require manual HTTPRoute `backendRefs` weight management or external tools (Argo Rollouts, Flagger). This is a known gap in KServe's Standard Mode feature parity.

**Bottom line:** For LLM and large model serving on GKE, Standard Mode + Gateway API is the recommended path. The cold-start and sidecar penalties of Knative outweigh its convenience features for production inference workloads.

## Outcomes

- End-to-end inference verified through external ingress: `curl → GKE Gateway → DistilBERT → {"predictions": [1, 0]}`.
- Canary rollout verified: 90/10 weighted traffic split across stable + canary backends, ~85/15 distribution observed over 100 requests.
- 2 upstream issues filed, 2 PRs opened (1 merged, 1 under review), 1 docs PR opened.

---

## Session Workflow

### Start of session
```bash
# 1. Create the cluster (~3-5 min)
bash cluster.sh create

# 2. Install KServe (~3-4 min)
bash install.sh
```

### End of session
```bash
# Delete the cluster to stop charges (~$0.40/hr while running)
bash cluster.sh delete
```

## Scripts

| Script | What it does |
|---|---|
| `cluster.sh create` | Creates GKE cluster `kserve-study` (3x e2-standard-4, us-central1-a, Gateway API enabled) |
| `cluster.sh delete` | Deletes the cluster and stops all charges |
| `install.sh` | Installs cert-manager v1.17.2 and KServe v0.17.0 in Standard Mode with Gateway API |

## Cluster Details

| Field | Value |
|---|---|
| Cluster name | `kserve-study` |
| Zone | `us-central1-a` |
| Nodes | 3x `e2-standard-4` (4 vCPU, 16 GB RAM each) |
| GKE version | 1.35 |
| KServe version | v0.17.0 |
| Deployment mode | Standard (warm pods, no Knative sidecars) |
| Ingress | Gateway API |

## Sending an Inference Request

Once the model pod is Running, use port-forward to reach it directly (works even if the Gateway is not yet programmed):

```bash
# Forward the predictor service to localhost
kubectl port-forward svc/distilbert-v1-predictor -n default 8080:80 &

# Send a prediction request (KServe v1 predict API)
curl -s http://localhost:8080/v1/models/distilbert-v1:predict \
  -H 'Content-Type: application/json' \
  -d '{"instances": ["This movie was absolutely fantastic", "What a terrible waste of time"]}'
```

**Expected response:**
```json
{"predictions": [1, 0]}
```

- `1` = POSITIVE sentiment
- `0` = NEGATIVE sentiment

The model is `distilbert-base-uncased-finetuned-sst-2-english` — DistilBERT fine-tuned on the Stanford Sentiment Treebank (SST-2) binary classification dataset.

### Via GKE Gateway (external ingress)

Once the Gateway is programmed and the HTTPRoute is `Accepted`, you can reach the model through the external IP:

```bash
# Get the Gateway external IP
GATEWAY_IP=$(kubectl get gateway kserve-ingress-gateway -n kserve \
  -o jsonpath='{.status.addresses[0].value}')

# Get the model's hostname from the InferenceService status
MODEL_HOST=$(kubectl get inferenceservice distilbert-v1 -n default \
  -o jsonpath='{.status.url}' | sed 's|https\?://||')

# Send a prediction request through the Gateway
curl -s http://${GATEWAY_IP}/v1/models/distilbert-v1:predict \
  -H "Host: ${MODEL_HOST}" \
  -H 'Content-Type: application/json' \
  -d '{"instances": ["This movie was absolutely fantastic", "What a terrible waste of time"]}'
```

The `Host` header is required because KServe uses host-based routing — the Gateway matches the hostname to decide which HTTPRoute (and therefore which backend service) to forward to.

**Prerequisites:**
- Gateway resource `kserve-ingress-gateway` exists in the `kserve` namespace (created by `install.sh`)
- `inferenceservice-config` has `enableGatewayApi: true` and `disableHTTPRouteTimeout: true` (see troubleshooting #8)
- HTTPRoute path match fix applied (see troubleshooting #9) — either via custom controller image or manual patch

## Canary Deployments (Weight-Based Traffic Splitting)

KServe Standard Mode does not support `canaryTrafficPercent` — that field only works in Knative/Serverless mode (tracked in [kserve/kserve#5335](https://github.com/kserve/kserve/issues/5335)). On GKE Gateway, canary deployments require manual HTTPRoute weight configuration.

### Key Insight: Model Name Parity

Both the stable and canary backends **must serve the same model name**. KServe's inference protocol includes the model name in the URL path (`/v1/models/<name>:predict`). If the canary has a different model name, requests routed to it return 404. This means you cannot simply create a second InferenceService — instead, create a standalone Deployment+Service with `--model_name` matching the stable version.

Full analysis: [canary-traffic-split-troubleshooting.md](canary-traffic-split-troubleshooting.md)

### Step-by-Step

**Prerequisites:** Cluster running, KServe installed with custom controller image that includes both the timeout and path match fixes, configured with `disableHTTPRouteTimeout: true` and `pathMatchType: "PathPrefix"` (see troubleshooting #8, #9). With these fixes, the controller creates HTTPRoutes that GKE Gateway accepts natively — no manual patching or scaling the controller to 0 is needed.

**1. Deploy the stable model (v1)**
```bash
kubectl apply -f distilbert-isvc.yaml
# Wait for pod ready
kubectl wait --for=condition=Ready pod \
  -l serving.kserve.io/inferenceservice=distilbert-v1 --timeout=300s
```

**2. Deploy canary v2 as a standalone Deployment+Service**
```bash
kubectl apply -f canary-v2-deployment.yaml   # Deployment + Service
```

The canary Deployment must include:
- `--model_name=distilbert-v1` (same as stable — this is critical)
- A `storage-initializer` init container to download the model
- Its own Service (`canary-v2-predictor`) targeting port 8080

**3. Wait for canary pod**
```bash
kubectl wait --for=condition=Ready pod -l app=canary-v2-predictor --timeout=300s
```

**4. Warmup canary v2**
```bash
kubectl port-forward svc/canary-v2-predictor 8081:80 &
curl -s http://localhost:8081/v1/models/distilbert-v1:predict \
  -H 'Content-Type: application/json' \
  -d '{"instances": ["warmup"]}'
kill %1
```

**5. Create canary HTTPRoute with 90/10 split**
```yaml
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
```

**6. Test the traffic split**
```bash
GATEWAY_IP=$(kubectl get gateway kserve-ingress-gateway -n kserve \
  -o jsonpath='{.status.addresses[0].value}')

# Send requests and verify both backends receive traffic
for i in $(seq 1 20); do
  curl -s "http://$GATEWAY_IP/v1/models/distilbert-v1:predict" \
    -H "Host: distilbert-canary-default.example.com" \
    -H "Content-Type: application/json" \
    -d '{"instances": ["This movie is great"]}'
  echo ""
done

# Check traffic distribution in pod logs
kubectl logs -l app=isvc.distilbert-v1-predictor --tail=100 | grep -c "POST /v1"
kubectl logs -l app=canary-v2-predictor --tail=100 | grep -c "POST /v1"
```

**Expected result:** ~90% of requests hit v1, ~10% hit canary-v2 (exact distribution varies at low request counts due to GKE load balancer behavior).

### Adjusting the Split

To shift traffic (e.g., promote to 50/50, then 0/100):
```bash
kubectl patch httproute distilbert-canary -n default --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
       {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}]'
```

### Common Mistakes to Avoid

- Creating a second ISVC for canary (model name mismatch causes 404s — use standalone Deployment instead)
- Not using the custom controller image with `pathMatchType: "PathPrefix"` (stock KServe creates regex paths that GKE rejects)
- Using dict-style payloads with v1 predict endpoint (see below)

### Payload Format

Use simple list-style payloads with the v1 predict endpoint:
```json
{"instances": ["text1", "text2"]}
```
Do **not** use dict-style payloads like `{"instances": [{"text": "hello"}]}` — these fail with a pandas `ValueError`.

## Troubleshooting Log

### 1. GKE Gateway API CRD conflict with KServe

**Problem:** `kserve.yaml` bundles `inference.networking.k8s.io` and `inference.networking.x-k8s.io` CRDs, but GKE already manages these via `kube-addon-manager` when the cluster is created with `--gateway-api=standard`. Applying with `--server-side` fails with field ownership conflicts on `.spec.versions` and `.metadata.annotations`.

**Symptom:** `Apply failed with 2 conflicts: conflicts with "kube-addon-manager"`, followed by cascading `namespaces "kserve" not found` errors because the apply aborts before creating the namespace.

**Fix:** Filter out CRD documents containing `inference.networking.` from `kserve.yaml` before applying. GKE's versions of these CRDs are already installed and KServe will use them. This is what `install.sh` does.

**Do NOT** use `--force-conflicts` — it takes ownership away from GKE's addon manager and can cause issues during GKE upgrades.

### 2. kserve.yaml does not create the `kserve` namespace

**Problem:** `kserve.yaml` contains namespace-scoped resources (Deployments, ConfigMaps, Services, etc.) that reference `namespace: kserve`, but the manifest itself does not include a `kind: Namespace` resource.

**Symptom:** Cluster-scoped resources (CRDs, ClusterRoles, webhooks) apply successfully, but all namespace-scoped resources fail with `Error from server (NotFound): namespaces "kserve" not found`.

**Fix:** Create the namespace before applying: `kubectl create namespace kserve`. `install.sh` does this automatically.

### 3. KServe webhook not ready when applying cluster resources

**Problem:** `kserve-cluster-resources.yaml` creates `ClusterServingRuntime` resources that are validated by the KServe webhook. If applied immediately after `kserve.yaml`, the webhook pods aren't running yet.

**Symptom:** `failed calling webhook "clusterservingruntime.kserve-webhook-server.validator": no endpoints available for service "kserve-webhook-server-service"`.

**Fix:** Wait for all deployments in the `kserve` namespace to be ready before applying cluster resources: `kubectl wait --for=condition=Available deployment --all -n kserve`. `install.sh` does this automatically.

### 4. `ClusterStorageContainer` not recognized on first install

**Problem:** `kserve.yaml` applies CRDs and CRD-instance resources in the same manifest. On first apply, the `ClusterStorageContainer` CRD is registered but the API server hasn't indexed it yet when the resource is applied.

**Symptom:** `error: unable to recognize "STDIN": no matches for kind "ClusterStorageContainer" in version "serving.kserve.io/v1alpha1"`.

**Fix:** Re-run `install.sh`. On the second run all CRDs are already registered, so the resource applies cleanly. Idempotent — no data is lost.

### 5. InferenceService stuck: `ingressGateway is required`

**Problem:** When Gateway API is enabled in `inferenceservice-config`, KServe still validates that the legacy `ingressGateway` field is non-empty (a hold-over from Istio mode).

**Symptom:** `fails to create NewRawKubeReconciler for predictor: invalid ingress config - ingressGateway is required`. No predictor pod is created.

**Fix:** Include `ingressGateway` in the ingress config patch even though Gateway API is what's actually used:
```json
{"ingressGateway": "kserve/kserve-ingress-gateway", "enableGatewayApi": true, "kserveIngressGateway": "kserve/kserve-ingress-gateway", "disableIstioVirtualHost": true}
```
`install.sh` already includes this. Also set `disableIstioVirtualHost: true` to suppress Istio VirtualService reconciliation warnings.

### 6. HuggingFace `storageUri` format

**Problem:** KServe's storage initializer requires the HuggingFace URI to follow `hf://owner/model` format.

**Symptom:** `Invalid Hugging Face URI format. Expected 'hf://owner/model[:revision]', got 'hf://distilbert-base-uncased-finetuned-sst-2-english'`.

**Fix:** Always include the owner namespace: `hf://distilbert/distilbert-base-uncased-finetuned-sst-2-english`.

### 7. KServe HuggingFace task name for classification

**Problem:** KServe's HuggingFace server uses its own task name enum, not the HuggingFace pipeline API names.

**Symptom:** `Unsupported task: text-classification. Currently supported tasks are: ... sequence_classification ...`.

**Fix:** Use `--task=sequence_classification` (not `text-classification`) in the InferenceService args.

### 8. GKE Gateway rejects KServe HTTPRoutes with timeouts (fixed upstream)

**Symptom:** HTTPRoute `Accepted: False` with reason `UnsupportedValue`. InferenceService stays `IngressReady: False`. No external URL is assigned.

**Fix:** Set `disableHTTPRouteTimeout: true` in the `inferenceservice-config` ConfigMap. Requires the custom controller image until the next KServe release includes the merged PR. Full context, root cause, and upstream PR details are in [Upstream contributions](#upstream-contributions).

**Config:**
```json
{
  "enableGatewayApi": true,
  "kserveIngressGateway": "kserve/kserve-ingress-gateway",
  "disableHTTPRouteTimeout": true
}
```

**Custom image:** build the KServe controller from the fork (see [Upstream contributions](#upstream-contributions)) and push to your own registry, then set the controller image in the `kserve-controller-manager` Deployment.

### 9. GKE Gateway rejects KServe HTTPRoute regex path (fixed in fork)

**Symptom:** HTTPRoute `Accepted: False` with `GWCER104: Paths must start with a '/' character "^/.*$"`.

**Fix:** Set `pathMatchType: "PathPrefix"` in the `inferenceservice-config` ConfigMap. Requires the custom controller image until the upstream PR is merged and released. Full context, root cause, and upstream PR details are in [Upstream contributions](#upstream-contributions).

**Config:**
```json
{
  "enableGatewayApi": true,
  "kserveIngressGateway": "kserve/kserve-ingress-gateway",
  "disableHTTPRouteTimeout": true,
  "pathMatchType": "PathPrefix"
}
```

**Custom image:** build the KServe controller from the fork (see [Upstream contributions](#upstream-contributions)) and push to your own registry, then set the controller image in the `kserve-controller-manager` Deployment.

**Legacy workaround (without custom image):** Scale the controller to 0, then patch the HTTPRoute path to `PathPrefix: /`:
```bash
kubectl scale deploy kserve-controller-manager -n kserve --replicas=0
kubectl patch httproute <name> --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/matches/0/path/type","value":"PathPrefix"},
       {"op":"replace","path":"/spec/rules/0/matches/0/path/value","value":"/"}]'
```