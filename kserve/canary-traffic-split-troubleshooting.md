# Troubleshooting Canary Traffic Splits (KServe Standard Mode)

This document summarizes the investigation and resolution of 404 errors encountered during the Week 3 canary deployment hands-on lab using KServe Standard Mode and GKE Gateway API.

## 1. The Problem: 404 Errors during Traffic Split
While testing a weight-based canary split (90/10) between `distilbert-v1` and `distilbert-v2` using a single Gateway API `HTTPRoute`, approximately 10% of requests failed with a `404 Not Found` error.

**Symptom:**
*   90% of requests to `http://<GATEWAY_IP>/v2/models/distilbert-v1/infer` succeeded (200 OK).
*   10% of requests to the same URL failed with `{"error":"Model with name distilbert-v1 does not exist."}`.

## 2. Root Cause: Model-Name Aware V2 Protocol
In KServe **Standard Mode**, each `InferenceService` (ISVC) spawns a model server (HuggingFace runtime in this case) that is started with a `--model_name` argument. By default, this name matches the ISVC name.

*   **v1 ISVC** is started with `--model_name=distilbert-v1`.
*   **v2 ISVC** is started with `--model_name=distilbert-v2`.

The **V2 Inference Protocol** specifies that the model name is part of the URL path: `/v2/models/<model_name>/infer`.

When the `HTTPRoute` splits traffic, it sends the *entire* request (including the path) to the backend. When 10% of traffic hit the `v2` backend, the model server saw `distilbert-v1` in the path, checked its registry, found only `distilbert-v2`, and correctly reported that the model did not exist.

## 3. The Workaround: Standalone Deployment & Service
To resolve this without rewriting URL paths (which is complex in Gateway API for weight-based splits), we needed both backends to respond to the **same model name**. 

### Step 1: Manual Deployment Control
Since creating a second ISVC would force a new model name (e.g., `distilbert-v2`), we bypassed the KServe CRD and created a standard Kubernetes **Deployment** for the canary version.

### Step 2: Forcing the Model Name
In the canary Deployment's container arguments, we explicitly set:
`--model_name=distilbert-v1`

This allowed the "v2" container (using the newer model image) to register itself internally as `distilbert-v1`, making it compatible with the incoming request paths.

### Step 2b: Storage Initializer
The standalone Deployment also needs a `storage-initializer` init container (image: `kserve/storage-initializer:v0.17.0`) to download the model from HuggingFace into `/mnt/models` at startup, since KServe's ISVC controller isn't managing this pod.

### Step 2c: Controller at 0 Replicas
The KServe controller must stay scaled to 0 replicas throughout this process. If scaled back up, it will re-reconcile the HTTPRoutes with `RegularExpression` path matches that GKE Gateway rejects (kserve/kserve#5319), overwriting any manual route configuration.

### Step 3: Weighted Backend Routing
We created a separate Service (`canary-v2-predictor`) for this deployment and updated the `HTTPRoute` to split traffic between the original `distilbert-v1-predictor` Service and the new `canary-v2-predictor` Service.

```yaml
spec:
  rules:
  - backendRefs:
    - name: distilbert-v1-predictor
      port: 80
      weight: 90
    - name: canary-v2-predictor
      port: 80
      weight: 10
```

## 4. Future Native Solution: KServe #5335
An open proposal (**kserve/kserve#5335**) aims to support `canaryTrafficPercent` in RawDeployment (Standard) mode via Gateway API weights. Currently, `canaryTrafficPercent` is **silently ignored** in RawDeployment mode — no error or warning is surfaced. The proposal extends `RawHTTPRouteReconciler` to create weighted `backendRefs` when this field is set. Once implemented, this will solve the problem by:

*   **Automating Model Naming:** The controller would manage both stable and canary Deployments under the same ISVC, so both use the same `--model_name` (the parent ISVC name).
*   **Automating Plumbing:** KServe would create a second canary Deployment + Service and manage the weighted `HTTPRoute` backend references automatically.
*   **Maintaining Abstraction:** Users can perform canaries using the high-level `InferenceService` spec instead of dropping down to standard Kubernetes Deployments.
*   **Lifecycle Management:** The proposal includes promote (canary → stable), rollback, and status tracking (`latestRolledoutRevision`, traffic percentages).

## 5. Alternative (Less Recommended) Approaches
| Approach | Pros | Cons |
| :--- | :--- | :--- |
| **URL Rewriting** | No changes to model code/naming. | GKE Gateway API currently has limited support for *per-backend* path rewrites in weighted rules. |
| **Multiple Namespaces** | Uses standard ISVC names. | Requires complex cross-namespace routing and Service management. |
| **V1 Protocol** | Path includes model name but predict endpoint is more forgiving. | Works with simple `{"instances": ["text"]}` payloads, but fails with dict-style payloads like `{"instances": [{"text": "hello"}]}`. Not a general solution — the model name is still in the path. |

## 6. Architecture Conflict: Logical Name vs. Version Tag
There is a fundamental tension between **Management Intuition** (Admin view) and **Protocol Requirements** (Client view):

*   **The Management Intuition:** It feels intuitive to have different names (`distilbert-v1` and `distilbert-v2`) in Kubernetes to clearly distinguish between model versions.
*   **The Protocol Requirement:** To perform an **Infrastructure-level Canary** (where the Gateway API handles the split), the request from the client must be **identical** for both versions.

If the names are different, the URL paths are different. If the URL paths are different, the **Client** (not the infrastructure) has to decide which one to call. This breaks the canary pattern.

**Conclusion:** The most robust design pattern separates the **Logical Service Name** (e.g., `distilbert`) from the **Artifact Version** (e.g., Image Tag or Revision Label). The model server should always respond to the logical name to ensure path compatibility across revisions.

## 7. Final Recommendation for GKE Gateway
Until **#5335** is merged, the **Standalone Deployment + Service** approach is the most reliable "hacker" method for KServe Standard Mode canaries on GKE. It provides 100% control over the model name and routing, and it avoids the "reconciler fight" where the KServe controller might overwrite manual Gateway API configuration.

**Key Insight:** ML Canaries in Standard Mode require **Model Name Parity**. Whether automated or manual, the `v2` protocol's path reliance means the canary version MUST masquerade as the stable version's name to avoid 404s when traffic is routed via a single transparent endpoint.
