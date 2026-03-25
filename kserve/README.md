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