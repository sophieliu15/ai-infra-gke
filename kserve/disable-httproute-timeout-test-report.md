# DisableHTTPRouteTimeout — Manual Test Report

**Date:** 2026-03-28
**Cluster:** `kserve-study` (GKE, `us-central1-a`, 3x `e2-standard-4`, v1.34.4-gke.1130000)
**GKE Gateway Class:** `gke-l7-global-external-managed`
**KServe Version:** v0.17.0 with custom controller from branch `fix/disable-httproute-timeout`
**Fork:** https://github.com/sophieliu15/kserve/tree/fix/disable-httproute-timeout
**Related Issue:** https://github.com/kserve/kserve/issues/5311

## Summary

Verified that setting `disableHTTPRouteTimeout: true` in the `inferenceservice-config` ConfigMap causes the KServe controller to omit the `spec.rules[*].timeouts` field from HTTPRoutes. This resolves the GKE Gateway incompatibility where the controller rejects routes with `Accepted: False` / `UnsupportedValue` because GKE does not implement `spec.rules.timeouts`.

**Result:** With the fix, the HTTPRoute is accepted by GKE Gateway and end-to-end inference works through the external load balancer.

## Environment Setup

### 1. Create GKE Cluster

```bash
# Using project cluster script (or equivalent):
gcloud container clusters create kserve-study \
  --zone us-central1-a \
  --num-nodes 3 \
  --machine-type e2-standard-4 \
  --gateway-api standard
```

### 2. Install cert-manager and KServe v0.17.0

```bash
# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=180s

# KServe (filter out GKE-managed inference.networking CRDs)
kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -
curl -sL "https://github.com/kserve/kserve/releases/download/v0.17.0/kserve.yaml" \
  | python3 -c "
import sys
docs = sys.stdin.read().split('\n---\n')
filtered = [d for d in docs if not (
    'kind: CustomResourceDefinition' in d and 'inference.networking.' in d
)]
print('\n---\n'.join(filtered))
" | kubectl apply --server-side -f -

# Wait for CRD if ClusterStorageContainer fails
kubectl wait --for=condition=Established crd/clusterstoragecontainers.serving.kserve.io --timeout=60s
# Re-run the kserve.yaml apply above if it errored on ClusterStorageContainer

kubectl wait --for=condition=Available deployment --all -n kserve --timeout=180s
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.17.0/kserve-cluster-resources.yaml
```

### 3. Build and Push Custom Controller Image

```bash
# From the fork checkout:
cd /path/to/kserve  # sophieliu15/kserve, branch fix/disable-httproute-timeout

# Build
docker build -t us-central1-docker.pkg.dev/<PROJECT_ID>/kserve-dev/kserve-controller:disable-timeout .

# Push (ensure Artifact Registry repo exists and docker auth is configured)
docker push us-central1-docker.pkg.dev/<PROJECT_ID>/kserve-dev/kserve-controller:disable-timeout
```

For this test, the image was:
```
us-central1-docker.pkg.dev/ai-infra-lab-86222/kserve-dev/kserve-controller:disable-timeout
```

### 4. Configure KServe: Standard Mode + Gateway API + DisableHTTPRouteTimeout

```bash
# Standard deployment mode
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"deploy": "{\"defaultDeploymentMode\": \"Standard\"}"}}'

# Gateway API with disableHTTPRouteTimeout: true
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"ingress": "{\"ingressGateway\": \"kserve/kserve-ingress-gateway\", \"enableGatewayApi\": true, \"kserveIngressGateway\": \"kserve/kserve-ingress-gateway\", \"disableIstioVirtualHost\": true, \"disableHTTPRouteTimeout\": true}"}}'
```

### 5. Swap Controller Image

```bash
kubectl set image deployment/kserve-controller-manager \
  manager=us-central1-docker.pkg.dev/ai-infra-lab-86222/kserve-dev/kserve-controller:disable-timeout \
  -n kserve

kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=120s
```

### 6. Create Gateway Resource

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  gatewayClassName: gke-l7-global-external-managed
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF
```

## Test Execution

### Deploy InferenceService

```bash
kubectl apply -f - <<'EOF'
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: distilbert-sst2
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      args:
        - --task=sequence_classification
      storageUri: hf://distilbert/distilbert-base-uncased-finetuned-sst-2-english
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
EOF
```

### Verify HTTPRoute Has No Timeouts Field

```bash
kubectl get httproute distilbert-sst2 -o json | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for i, rule in enumerate(d.get('spec',{}).get('rules',[])):
    t = rule.get('timeouts')
    print(f'Rule {i}: timeouts={t}')
"
```

**Expected output:**
```
Rule 0: timeouts=None
```

**Actual output (2026-03-28):**
```
Rule 0: timeouts=None
```

This confirms the `DisableHTTPRouteTimeout` flag correctly prevents the controller from setting `spec.rules[*].timeouts` on the HTTPRoute.

### Verify HTTPRoute Accepted by GKE Gateway

```bash
kubectl get httproute distilbert-sst2 -o json | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d.get('status',{}).get('parents',[]):
    for c in p.get('conditions',[]):
        print(f'{c[\"type\"]}: {c[\"status\"]} - {c.get(\"reason\",\"\")} {c.get(\"message\",\"\")[:120]}')
"
```

**Expected:** `Accepted: True`

**Actual output (2026-03-28):**
```
ResolvedRefs: True - ResolvedRefs
Accepted: True - Accepted
```

> **Note:** There is a separate GKE incompatibility with KServe's regex path match (`^/.*$`).
> GKE rejects it with `GWCER104: Paths must start with '/'`. This is unrelated to the
> timeout fix and requires a separate patch (scale controller to 0, patch path to
> `PathPrefix: /`). See "Known Limitations" below.

### Verify End-to-End Inference Through Gateway

```bash
# Get Gateway external IP
GATEWAY_IP=$(kubectl get gateway kserve-ingress-gateway -n kserve \
  -o jsonpath='{.status.addresses[0].value}')

# Send inference request
curl -s \
  -H "Host: distilbert-sst2-default.example.com" \
  -H "Content-Type: application/json" \
  -d '{"instances": ["This movie was fantastic", "I hated every minute of it"]}' \
  http://${GATEWAY_IP}/v1/models/distilbert-sst2:predict
```

**Expected:** `{"predictions":[1,0]}` (1=POSITIVE, 0=NEGATIVE)

**Actual output (2026-03-28):**
```json
{"predictions":[1,0]}
```

### Comparison: Without the Fix (stock KServe v0.17.0)

With the stock controller (no `DisableHTTPRouteTimeout` flag), the HTTPRoute contains:

```yaml
spec:
  rules:
  - timeouts:
      request: 60s
```

And GKE Gateway rejects it:

```
Accepted: False - UnsupportedValue
```

This causes `IngressReady=False` on the InferenceService, and no external traffic can reach the model.

## Unit Tests

All new and existing tests pass:

```bash
cd /path/to/kserve
go test ./pkg/controller/v1beta1/inferenceservice/reconcilers/ingress/ -v -count=1
```

New test functions added:
- `TestResolveTimeout` — 4 cases: disabled/enabled × with/without user-specified timeout
- `TestCreateHTTPRouteRuleNilTimeout` — 2 cases: nil timeout omits field, non-nil sets it
- `TestCreateRawPredictorHTTPRouteDisableTimeout` — 2 cases: full predictor route with flag on/off

## Known Limitations

This fix addresses the `timeouts` incompatibility only. A separate GKE Gateway issue exists:

- **KServe regex path match:** KServe uses `RegularExpression` type with `^/.*$`
- **GKE rejection:** `GWCER104: Paths must start with '/' character`
- **Workaround:** Scale controller to 0, patch HTTPRoute paths to `PathPrefix: /`
- **Proper fix:** Needs a separate config flag or auto-detection of GKE Gateway capabilities

## Files Changed

1. `pkg/apis/serving/v1beta1/configmap.go` — Added `DisableHTTPRouteTimeout bool` to `IngressConfig`
2. `pkg/controller/.../httproute_reconciler.go` — Added `resolveTimeout()` helper; modified `createHTTPRouteRule` to conditionally set `Timeouts`; updated all 9 timeout blocks in 4 route-builder functions
3. `pkg/controller/.../httproute_reconciler_test.go` — Added 3 test functions (6 cases)
