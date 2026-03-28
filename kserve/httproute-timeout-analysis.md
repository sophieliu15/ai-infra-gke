# KServe + GKE Gateway: HTTPRoute Timeout Fix

## Problem

KServe v0.17.0 hardcodes `timeouts: request: 60s` on every HTTPRoute it creates
(`pkg/controller/v1beta1/inferenceservice/reconcilers/ingress/httproute_reconciler.go`).
GKE's Gateway controller does not support `spec.rules.timeouts` — it rejects the route
with `Accepted: False` / `UnsupportedValue`.

There is no KServe annotation, config flag, or InferenceService field to disable this.

## Code Walkthrough: How the Timeout Gets Hardcoded

Source: `pkg/controller/v1beta1/inferenceservice/reconcilers/ingress/httproute_reconciler.go`

### Step 1 — Package-level default (no config, no override)

```go
var DefaultTimeout = toGatewayAPIDuration(60)

func toGatewayAPIDuration(seconds int64) *gwapiv1.Duration {
    duration := gwapiv1.Duration(fmt.Sprintf("%ds", seconds))
    return &duration   // returns pointer to "60s"
}
```

`DefaultTimeout` is set once at package init. No ConfigMap, env var, or flag controls it.

### Step 2 — Every route builder uses it as a non-nil fallback

The same pattern repeats in `createRawPredictorHTTPRoute`, `createRawTransformerHTTPRoute`,
`createRawExplainerHTTPRoute`, and `createRawTopLevelHTTPRoute`:

```go
timeout := DefaultTimeout                                // always starts as "60s"
if isvc.Spec.Predictor.TimeoutSeconds != nil {           // user set a custom value?
    timeout = toGatewayAPIDuration(*isvc.Spec.Predictor.TimeoutSeconds)  // override value
}
```

You can change the **value** via `spec.predictor.timeout`, but you **cannot set it to nil**.
The code always assigns *something* to `timeout`.

### Step 3 — `createHTTPRouteRule` unconditionally wraps it in a Timeouts struct

```go
func createHTTPRouteRule(..., timeout *gwapiv1.Duration) gwapiv1.HTTPRouteRule {
    return gwapiv1.HTTPRouteRule{
        Matches:     routeMatches,
        Filters:     filters,
        BackendRefs: backendRefs,
        Timeouts: &gwapiv1.HTTPRouteTimeouts{   // <-- ALWAYS set, never nil
            Request: timeout,
        },
    }
}
```

Even if `timeout` were nil, `Timeouts` itself is still a non-nil pointer. There's no code
path that skips this field.

### Step 4 — Reconciler re-applies on every loop

The `reconcile*HTTPRoute` functions compare desired vs existing state (`semanticHttpRouteEquals`)
and call `r.client.Update()` on any diff. So if you manually patch the timeout off, KServe
sees a diff on the next reconciliation and **puts it back**.

### The chain that breaks GKE ingress

```
KServe creates HTTPRoute with spec.rules[*].timeouts.request: "60s"
  → GKE Gateway controller does NOT implement spec.rules.timeouts
  → Sets condition: Accepted=False, Reason=UnsupportedValue
  → KServe's reconcileHTTPRouteStatus() sees Accepted=False
  → Sets IngressReady=False → ingress never comes up
```

## Upstream PR: Proposed Fix

The right fix is **not** to remove timeouts entirely — other Gateway implementations (Envoy
Gateway, Istio) support it. The fix is to make it **conditional** so it's only set when the
controller supports it.

### Option A: ConfigMap flag in `inferenceservice-config` (recommended)

Add a `disableHTTPRouteTimeout` field to the ingress config. This is the smallest, most
backwards-compatible change:

```go
// In createHTTPRouteRule — only set Timeouts when non-nil
func createHTTPRouteRule(..., timeout *gwapiv1.Duration) gwapiv1.HTTPRouteRule {
    rule := gwapiv1.HTTPRouteRule{
        Matches:     routeMatches,
        Filters:     filters,
        BackendRefs: backendRefs,
    }
    if timeout != nil {
        rule.Timeouts = &gwapiv1.HTTPRouteTimeouts{Request: timeout}
    }
    return rule
}

// In each createRaw*HTTPRoute function — respect the config flag
var timeout *gwapiv1.Duration
if !ingressConfig.DisableHTTPRouteTimeout {
    timeout = DefaultTimeout
    if isvc.Spec.Predictor.TimeoutSeconds != nil {
        timeout = toGatewayAPIDuration(*isvc.Spec.Predictor.TimeoutSeconds)
    }
}
```

Users on GKE would set `disableHTTPRouteTimeout: "true"` in the `inferenceservice-config`
ConfigMap. Everyone else keeps the current behavior by default.

### Option B: Only set timeout when user explicitly specifies it

Remove `DefaultTimeout` entirely and only populate the field when `TimeoutSeconds` is set
on the InferenceService spec:

```go
var timeout *gwapiv1.Duration
if isvc.Spec.Predictor.TimeoutSeconds != nil {
    timeout = toGatewayAPIDuration(*isvc.Spec.Predictor.TimeoutSeconds)
}
```

This is cleaner but changes default behavior — existing users who rely on the implicit 60s
timeout would lose it. Would need to be called out in release notes.

### Recommendation

**Option A** is safer for an upstream PR — it's opt-in, backwards-compatible, and follows
KServe's existing pattern of using the `inferenceservice-config` ConfigMap for ingress
behavior. The PR should include:

1. Add `DisableHTTPRouteTimeout` to `IngressConfig` struct
2. Modify `createHTTPRouteRule` to accept nil timeout
3. Update each `createRaw*HTTPRoute` to check the flag
4. Add unit tests for both flag states
5. Update docs for GKE Gateway users

## Workarounds for the "Operator Fight" (Reconciliation Loop)

Because KServe acts as a Kubernetes Operator, its controller constantly watches the state of resources it owns. If you manually patch the `HTTPRoute`, KServe will immediately detect a difference from its desired state (60s timeout) and put the timeout back. Since GKE Gateway API often provisions real GCP Cloud Load Balancers, this rapid reconciliation loop can prevent the load balancer from ever provisioning correctly.

Here are three ways to handle this in a lab environment:

### 1. The "Dirty Lab Hack" (Continuous Patch Loop)

Run a loop in a separate terminal to continuously strip the timeout while the load balancer provisions.

```bash
# In a separate terminal pane
while true; do
  kubectl patch httproute <httproute-name> -n <namespace> --type=json \
    -p='[{"op":"remove","path":"/spec/rules/0/timeouts"},
         {"op":"remove","path":"/spec/rules/1/timeouts"}]' 2>/dev/null
  sleep 1
done
```
* **Pros:** Zero extra installation.
* **Cons:** Extremely hacky, spams the Kubernetes API server.

### 2. Scale the KServe Controller to 0 (For Static Testing)

Once KServe has created the `InferenceService`, pods, and the initial `HTTPRoute`, temporarily pause KServe itself:

```bash
kubectl scale deploy kserve-controller-manager -n kserve --replicas=0
```
Then run the single `kubectl patch` command. Since the controller is dead, it cannot revert your patch.

* **Pros:** Very easy and clean for static testing.
* **Cons:** You cannot deploy new models or change scaling until you scale the controller back up to 1.

### 3. The "Cloud Native" Way (Kyverno Mutating Webhook)

Install a lightweight policy engine like Kyverno to cleanly intercept the API request and strip the field *before* it reaches the cluster, completely solving the operator fight.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: strip-kserve-httproute-timeout
spec:
  rules:
  - name: remove-timeouts
    match:
      any:
      - resources:
          kinds:
          - HTTPRoute
          namespaces:
          - kserve
    mutate:
      patchesJson6902: |-
        - path: /spec/rules/0/timeouts
          op: remove
        - path: /spec/rules/1/timeouts
          op: remove
```
* **Pros:** Permanent fix for the cluster; KServe thinks it applied the timeout, but etcd never saves it.
* **Cons:** Requires installing another component (Kyverno) on the cluster.

## If You Need Actual Timeouts

GKE handles timeouts via GCPBackendPolicy, not HTTPRoute:

```yaml
apiVersion: networking.gke.io/v1
kind: GCPBackendPolicy
metadata:
  name: kserve-predictor-timeout
  namespace: <namespace>
spec:
  default:
    timeoutSec: 60
  targetRef:
    group: ""
    kind: Service
    name: <predictor-service-name>
```

## References

- KServe source: `httproute_reconciler.go` — `DefaultTimeout = toGatewayAPIDuration(60)`
- [GKE GatewayClass Capabilities](https://cloud.google.com/kubernetes-engine/docs/how-to/gatewayclass-capabilities) — `timeouts` not listed
- [GKE GCPBackendPolicy](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-gateway-resources)
- [KServe PR #3952](https://github.com/kserve/kserve/pull/3952) — introduced Gateway API support
