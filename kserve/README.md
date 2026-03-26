# KServe on GKE

Automated setup for running KServe on Google Kubernetes Engine, covering model serving, REST inference, and canary deployments.

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
| Project | `ai-infra-lab-86222` |
| Zone | `us-central1-a` |
| Nodes | 3x `e2-standard-4` (4 vCPU, 16 GB RAM each) |
| GKE version | 1.34 |
| KServe version | v0.17.0 |
| Deployment mode | Standard (warm pods, no Knative sidecars) |
| Ingress | Gateway API |

## Sending an Inference Request

Once the model pod is Running, use port-forward to reach it directly (works even if the Gateway is not yet programmed):

```bash
# Forward the predictor service to localhost
kubectl port-forward svc/distilbert-sst2-predictor -n default 8080:80 &

# Send a prediction request (KServe v1 predict API)
curl -s http://localhost:8080/v1/models/distilbert-sst2:predict \
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

### 8. GKE Gateway rejects KServe HTTPRoutes with timeouts (open)

**Problem:** KServe sets `timeouts: request: 60s` on all generated HTTPRoutes. GKE's Gateway controller does not support the `timeouts` field.

**Symptom:** Gateway stays `PROGRAMMED: False` with event: `HTTPRoute "default/distilbert-sst2" is misconfigured, err: Timeouts are not supported.`

**Status:** Open — blocks external URL from being assigned. Inference works via `kubectl port-forward` in the meantime. Must be resolved before Week 3 canary deployments.

**Potential fix:** Investigate KServe config option to suppress timeout generation on HTTPRoutes, or use Istio as the gateway implementation.