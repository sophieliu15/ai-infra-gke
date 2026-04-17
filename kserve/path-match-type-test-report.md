# PathMatchType — Manual Test Report

**Date:** 2026-04-04
**Cluster:** `kserve-study` (GKE, `us-central1-a`, 3x `e2-standard-4`)
**GKE Gateway Class:** `gke-l7-global-external-managed`
**KServe Version:** v0.17.0 with custom controller from branch `fix/path-match-type`
**Fork:** https://github.com/sophieliu15/kserve/tree/fix/path-match-type
**Related Issue:** https://github.com/kserve/kserve/issues/5319

## Summary

Verified that setting `pathMatchType: "PathPrefix"` in the `inferenceservice-config` ConfigMap causes the KServe controller to use `PathPrefix` path matches instead of `RegularExpression` in HTTPRoutes. This resolves the GKE Gateway incompatibility where GKE rejects regex path matches with `GWCER104: Paths must start with '/' character` because GKE does not implement Extended conformance for `RegularExpression` path matches.

**Result:** With the fix, HTTPRoutes use `PathPrefix: /` instead of `RegularExpression: ^/.*$`, are accepted by GKE Gateway, and end-to-end inference works through the external load balancer.

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
bash ai_infra_projects/kserve/install.sh
```

Or manually:

```bash
# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=180s

# KServe (filter out GKE-managed inference.networking CRDs, retry for CRD race)
kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -
KSERVE_YAML=$(curl -sL "https://github.com/kserve/kserve/releases/download/v0.17.0/kserve.yaml" \
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
  echo "Attempt $i failed — waiting 10s for CRDs to propagate..."
  sleep 10
done

kubectl wait --for=condition=Available deployment --all -n kserve --timeout=180s
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.17.0/kserve-cluster-resources.yaml
```

### 3. Build and Push Custom Controller Image

```bash
# From the fork checkout:
cd /path/to/kserve  # sophieliu15/kserve, branch fix/path-match-type

# Build (no --target needed; final stage is unnamed)
docker build -t us-central1-docker.pkg.dev/<PROJECT_ID>/kserve-dev/kserve-controller:path-match-type .

# Push (ensure Artifact Registry repo exists and docker auth is configured)
docker push us-central1-docker.pkg.dev/<PROJECT_ID>/kserve-dev/kserve-controller:path-match-type
```

For this test, the image was:
```
us-central1-docker.pkg.dev/ai-infra-lab-86222/kserve-dev/kserve-controller:path-match-type
```

### 4. Configure KServe: Standard Mode + Gateway API + PathMatchType

```bash
# Standard deployment mode
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"deploy": "{\"defaultDeploymentMode\": \"Standard\"}"}}'

# Gateway API with disableHTTPRouteTimeout + pathMatchType
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic \
  -p '{"data": {"ingress": "{\"ingressGateway\": \"kserve/kserve-ingress-gateway\", \"enableGatewayApi\": true, \"kserveIngressGateway\": \"kserve/kserve-ingress-gateway\", \"disableIstioVirtualHost\": true, \"disableHTTPRouteTimeout\": true}"}}'

# Add pathMatchType (merge into existing ingress config)
kubectl get configmap/inferenceservice-config -n kserve -o jsonpath='{.data.ingress}' \
  | python3 -c "
import sys, json
config = json.loads(sys.stdin.read())
config['pathMatchType'] = 'PathPrefix'
patch = json.dumps({'data': {'ingress': json.dumps(config)}})
print(patch)
" | xargs -0 kubectl patch configmap/inferenceservice-config -n kserve --type=strategic -p
```

### 5. Swap Controller Image

```bash
kubectl set image deployment/kserve-controller-manager \
  manager=us-central1-docker.pkg.dev/ai-infra-lab-86222/kserve-dev/kserve-controller:path-match-type \
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
  name: distilbert-v1
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

### Verify HTTPRoutes Use PathPrefix (Not RegularExpression)

```bash
kubectl get httproute distilbert-v1 -o jsonpath='{range .spec.rules[*]}{.matches[*].path}{"\n"}{end}'
kubectl get httproute distilbert-v1-predictor -o jsonpath='{range .spec.rules[*]}{.matches[*].path}{"\n"}{end}'
```

**Expected output:**
```
{"type":"PathPrefix","value":"/"}
```

**Actual output (2026-04-04):**
```
{"type":"PathPrefix","value":"/"}
```

Both HTTPRoutes (`distilbert-v1` and `distilbert-v1-predictor`) use `PathPrefix` instead of `RegularExpression`. This confirms the `pathMatchType` config flag correctly switches the path match type.

### Verify HTTPRoutes Accepted by GKE Gateway

```bash
kubectl get httproute distilbert-v1 -o jsonpath='{.status.parents[0].conditions}' | python3 -m json.tool
```

**Expected:** `Accepted: True`, no `GWCER104` error

**Actual output (2026-04-04):**
```json
[
    {
        "lastTransitionTime": "2026-04-04T16:44:03Z",
        "message": "",
        "reason": "ResolvedRefs",
        "status": "True",
        "type": "ResolvedRefs"
    },
    {
        "lastTransitionTime": "2026-04-04T16:44:03Z",
        "message": "",
        "reason": "Accepted",
        "status": "True",
        "type": "Accepted"
    },
    {
        "lastTransitionTime": "2026-04-04T16:44:03Z",
        "message": "",
        "reason": "ReconciliationSucceeded",
        "status": "True",
        "type": "Reconciled"
    }
]
```

### Verify InferenceService Ready

```bash
kubectl get inferenceservice distilbert-v1
```

**Actual output (2026-04-04):**
```
NAME            URL                                        READY   AGE
distilbert-v1   http://distilbert-v1-default.example.com   True    7m31s
```

### Verify End-to-End Inference Through Gateway

```bash
# Get Gateway external IP
GATEWAY_IP=$(kubectl get gateway kserve-ingress-gateway -n kserve \
  -o jsonpath='{.status.addresses[0].value}')

# Send inference request
curl -s \
  -H "Host: distilbert-v1-default.example.com" \
  -H "Content-Type: application/json" \
  -d '{"instances": ["This movie is great", "This movie is terrible"]}' \
  http://${GATEWAY_IP}/v1/models/distilbert-v1:predict
```

**Expected:** `{"predictions":[1,0]}` (1=POSITIVE, 0=NEGATIVE)

**Actual output (2026-04-04):**
```json
{"predictions":[1,0]}
```

### Comparison: Without the Fix (stock KServe v0.17.0)

With the stock controller (no `pathMatchType` flag), the HTTPRoute contains:

```yaml
spec:
  rules:
  - matches:
    - path:
        type: RegularExpression
        value: "^/.*$"
```

And GKE Gateway rejects it:

```
Accepted: False
Message: "GWCER104: Paths must start with '/' character"
```

This causes `IngressReady=False` on the InferenceService, and no external traffic can reach the model via the Gateway.

## Unit Tests

All new and existing tests pass:

```bash
cd /path/to/kserve
go test ./pkg/controller/v1beta1/inferenceservice/reconcilers/ingress/ -v -count=1
```

New test functions added:
- `TestResolvePathMatch` — 5 cases: default (empty string), explicit `RegularExpression`, `PathPrefix`, various regex patterns with their prefix equivalents
- `TestCreateRawPredictorHTTPRoutePathMatchType` — 2 integration cases: full predictor route with `PathPrefix` vs default `RegularExpression`

## Files Changed (23 total)

**Core Go code (3 files):**
1. `pkg/apis/serving/v1beta1/configmap.go` — Added `PathMatchType string` to `IngressConfig`
2. `pkg/controller/.../httproute_reconciler.go` — Added `resolvePathMatch()` helper; updated all 9 path match call sites in route-builder functions to use it
3. `pkg/controller/.../httproute_reconciler_test.go` — Added 7 test cases (5 unit + 2 integration)

**Helm charts (11 files):**
4. `charts/kserve-resources/values.yaml`
5. `charts/kserve-resources/README.md` (generated by helm-docs)
6. `charts/kserve-resources/files/common/configmap.yaml`
7. `charts/kserve-resources/files/common/configmap-patch.yaml`
8. `charts/kserve-llmisvc-resources/values.yaml`
9. `charts/kserve-llmisvc-resources/README.md` (generated by helm-docs)
10. `charts/kserve-llmisvc-resources/files/common/configmap.yaml`
11. `charts/kserve-llmisvc-resources/files/common/configmap-patch.yaml`
12. `charts/_common/common-patches/configmap-patch.yaml`
13. `charts/_common/kserve-resources-specific.yaml`
14. `charts/_common/kserve-llmisvc-resources-specific.yaml`

**ConfigMap manifests (2 files):**
15. `config/configmap/inferenceservice.yaml`
16. `config/overlays/test/configmap/inferenceservice.yaml`

**Quick-install scripts (3 files, generated):**
17. `hack/setup/quick-install/kserve-knative-mode-full-install-with-manifests.sh`
18. `hack/setup/quick-install/kserve-standard-mode-full-install-with-manifests.sh`
19. `hack/setup/quick-install/llmisvc-full-install-with-manifests.sh`

**OpenAPI / Python SDK (4 files, generated):**
20. `pkg/openapi/openapi_generated.go`
21. `pkg/openapi/swagger.json`
22. `python/kserve/docs/V1beta1IngressConfig.md`
23. `python/kserve/kserve/models/v1beta1_ingress_config.py`
