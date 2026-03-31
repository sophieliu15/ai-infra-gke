# HTTPRoute Regex Path Match — GKE Gateway Incompatibility Analysis

**Issue:** KServe #9 in [README.md](README.md)
**Related:** Issue #8 (timeout fix, kserve/kserve#5313) — same reconciler, same pattern
**Date:** 2026-03-30

---

## Problem

KServe's HTTPRoute reconciler hardcodes `PathMatchRegularExpression` as the path match type for all Gateway API HTTPRoute rules. GKE's Gateway controller does not support `RegularExpression` path matches and rejects the route with:

```
GWCER104: Paths must start with a '/' character "^/.*$"
```

The HTTPRoute stays `Accepted: False`, the InferenceService never gets an external URL, and external ingress is broken.

### Root Cause

**File:** `pkg/controller/v1beta1/inferenceservice/reconcilers/ingress/httproute_reconciler.go:111-118`

```go
func createHTTPRouteMatch(prefix string) gwapiv1.HTTPRouteMatch {
    return gwapiv1.HTTPRouteMatch{
        Path: &gwapiv1.HTTPPathMatch{
            Type:  ptr.To(gwapiv1.PathMatchRegularExpression),  // hardcoded
            Value: ptr.To(prefix),
        },
    }
}
```

Every call site passes the match type through this single function. The regex *pattern* is parameterized, but the match *type* is not — it is always `RegularExpression`.

### Regex Patterns Used

Defined in `pkg/constants/constants.go:786-801`:

| Function | Pattern | Used For |
|---|---|---|
| `FallbackPrefix()` | `^/.*$` | Catch-all: predictor, transformer, top-level routes |
| `PredictPrefix()` | `^/v1/models/[\\w-]+(:predict)?` | (Currently unused in HTTPRoute reconciler) |
| `ExplainPrefix()` | `^/v1/models/[\\w-]+:explain$` | Top-level explainer route |
| `PathBasedExplainPrefix()` | `(/v1/models/[\\w-]+:explain)$` | Path-based explainer route |

`FallbackPrefix()` is used in **6 of 9** call sites — it's the most common pattern and the one GKE rejects.

### Call Sites (9 total)

| Line | Function | Pattern | Purpose |
|---|---|---|---|
| 194 | `createRawPredictorHTTPRoute` | `FallbackPrefix()` | Predictor host catch-all |
| 254 | `createRawTransformerHTTPRoute` | `FallbackPrefix()` | Transformer host catch-all |
| 408 | `createRawTopLevelHTTPRoute` | `ExplainPrefix()` | Top-level :explain route |
| 424 | `createRawTopLevelHTTPRoute` | `FallbackPrefix()` | Top-level → transformer |
| 430 | `createRawTopLevelHTTPRoute` | `FallbackPrefix()` | Top-level → predictor |
| 448 | `createRawTopLevelHTTPRoute` | `path + PathBasedExplainPrefix()` | Path-based :explain |
| 456 | `createRawTopLevelHTTPRoute` | `path + "/"` | Path-based → transformer |
| 462 | `createRawTopLevelHTTPRoute` | `path + "/"` | Path-based → predictor |

### Why KServe Uses Regex

KServe routes different API endpoints to different backends (predictor, transformer, explainer) under a single hostname. Regex gives fine-grained control — e.g., routing `/v1/models/foo:explain` to the explainer while `/v1/models/foo:predict` goes to the transformer.

However, the dominant pattern is `FallbackPrefix()` = `^/.*$`, which is just a catch-all. This is functionally equivalent to `PathPrefix: /`.

---

## GKE Gateway API Constraints

The Gateway API spec defines three path match types: `Exact`, `PathPrefix`, and `RegularExpression`. But the spec marks `RegularExpression` as **Extended** conformance — implementations are not required to support it.

GKE's Gateway controller only supports:
- `Exact` — exact string match
- `PathPrefix` — prefix-based match (most common)

GKE does **not** support `RegularExpression`. Any HTTPRoute using it is rejected.

---

## Options

### Option A: Config Flag (`PathMatchType` field)

Add a new `pathMatchType` field to `IngressConfig` that lets operators choose the match type. When set to `"PathPrefix"`, `createHTTPRouteMatch()` uses `PathMatchPathPrefix` instead of `PathMatchRegularExpression`, and the regex patterns are replaced with equivalent prefix paths.

**Pros:**
- Follows the established `DisableHTTPRouteTimeout` pattern — reviewers are familiar with it.
- Backwards compatible — default stays `RegularExpression`, existing non-GKE deployments are untouched.
- Single config change for operators: `"pathMatchType": "PathPrefix"`.

**Cons:**
- Regex → prefix conversion is lossy. `ExplainPrefix()` = `^/v1/models/[\\w-]+:explain$` cannot be exactly expressed as a prefix. Would need to become `PathPrefix: /v1/models/` which is less specific (matches predict paths too), or require restructuring the routing.
- However, this only matters for the top-level HTTPRoute when both predictor and explainer are present. The component-specific HTTPRoutes (predictor, transformer) use `FallbackPrefix()` which converts cleanly to `PathPrefix: /`.

**Conversion table:**

| Regex Pattern | PathPrefix Equivalent | Exact? |
|---|---|---|
| `^/.*$` (FallbackPrefix) | `PathPrefix: /` | Yes, equivalent |
| `^/v1/models/[\\w-]+:explain$` (ExplainPrefix) | `PathPrefix: /v1/models/` | Broader — also matches predict |
| `(/v1/models/[\\w-]+:explain)$` (PathBasedExplainPrefix) | `PathPrefix: {path}/v1/models/` | Broader |
| `{path}/` (path-based) | `PathPrefix: {path}/` | Yes, equivalent |

### Option B: Unconditional Switch to PathPrefix

Replace `PathMatchRegularExpression` with `PathMatchPathPrefix` everywhere, unconditionally. Drop the regex patterns from `constants.go` and use simple path prefixes.

**Pros:**
- Simplest change — no config flag, no branching logic.
- Compatible with ALL Gateway API implementations (Istio, Envoy Gateway, GKE, etc.).
- Aligns with what the newer `llmisvc` controller already does (uses `PathMatchPathPrefix` in its test fixtures at `pkg/controller/v1alpha2/llmisvc/fixture/gwapi_builders.go:359`).

**Cons:**
- Breaking change for users who depend on regex precision (e.g., explainer-only routing).
- Can't merge upstream without broader discussion — this changes behavior for everyone.
- The explain route becomes less specific: `PathPrefix: /v1/models/` matches both predict and explain paths. Would need to rely on rule ordering (longer/more-specific prefix first) or split into separate HTTPRoutes.

### Option C: Smart Match Type Resolution

Create a `resolvePathMatch()` function (parallel to `resolveTimeout()`) that inspects both the config flag AND the pattern. If the pattern is a simple catch-all (`^/.*$` or `path + "/"`), use `PathPrefix`. If it's a true regex, keep `RegularExpression` (or error if GKE mode is on).

**Pros:**
- Most precise — catch-alls get PathPrefix (fixing GKE), real regexes keep working.
- Could warn or error clearly when a regex pattern can't be represented as PathPrefix.

**Cons:**
- More complex than needed. Adds pattern-inspection logic that may break on future pattern changes.
- Over-engineering for the current use case.

---

## Recommendation: Option A (Config Flag)

Option A is the right choice for the same reasons the timeout fix used a config flag:

1. **Upstream-friendly.** A config flag is non-breaking, opt-in, and easy for reviewers to approve. It follows the precedent set by `DisableHTTPRouteTimeout`, which was accepted in kserve/kserve#5313.

2. **Solves the GKE problem completely.** For the standard KServe deployment (predictor only, no explainer), `FallbackPrefix()` → `PathPrefix: /` is a perfect 1:1 conversion. This covers the overwhelming majority of real-world deployments.

3. **The explainer edge case is manageable.** When an explainer is present, the regex-based explain route (`^/v1/models/[\\w-]+:explain$`) becomes `PathPrefix: /v1/models/`. This is broader, but because HTTPRoute rules are evaluated in order and the explain rule is added *before* the catch-all fallback, traffic still routes correctly — the more specific prefix wins.

4. **Aligns with the llmisvc precedent.** The newer `llmisvc` controller already uses `PathMatchPathPrefix`, suggesting the KServe project is trending away from regex matches.

### Implementation Plan

**Config (`configmap.go`):**
```go
type IngressConfig struct {
    // ... existing fields ...
    PathMatchType string `json:"pathMatchType,omitempty"` // "RegularExpression" (default) or "PathPrefix"
}
```

**Resolver (`httproute_reconciler.go`):**
```go
func resolvePathMatch(pathMatchType string, regexPattern string, prefixEquivalent string) gwapiv1.HTTPRouteMatch {
    if pathMatchType == "PathPrefix" {
        return gwapiv1.HTTPRouteMatch{
            Path: &gwapiv1.HTTPPathMatch{
                Type:  ptr.To(gwapiv1.PathMatchPathPrefix),
                Value: ptr.To(prefixEquivalent),
            },
        }
    }
    // Default: use original regex behavior
    return gwapiv1.HTTPRouteMatch{
        Path: &gwapiv1.HTTPPathMatch{
            Type:  ptr.To(gwapiv1.PathMatchRegularExpression),
            Value: ptr.To(regexPattern),
        },
    }
}
```

**Call site update (each of 9 sites):**
```go
// Before:
routeMatch := []gwapiv1.HTTPRouteMatch{createHTTPRouteMatch(constants.FallbackPrefix())}

// After:
routeMatch := []gwapiv1.HTTPRouteMatch{resolvePathMatch(ingressConfig.PathMatchType, constants.FallbackPrefix(), "/")}
```

**Prefix equivalents table for implementation:**

| Call Site | Regex Arg | Prefix Arg |
|---|---|---|
| Predictor/Transformer/TopLevel catch-all | `FallbackPrefix()` = `^/.*$` | `/` |
| TopLevel explainer | `ExplainPrefix()` = `^/v1/models/[\\w-]+:explain$` | `/v1/models/` |
| Path-based explainer | `path + PathBasedExplainPrefix()` | `path + "/v1/models/"` |
| Path-based predict/transform | `path + "/"` | `path + "/"` |

**Tests:** Mirror the timeout tests — verify each route type produces `PathPrefix` when configured, and `RegularExpression` when not.

**Config YAML:**
```json
{
  "enableGatewayApi": true,
  "kserveIngressGateway": "kserve/kserve-ingress-gateway",
  "disableHTTPRouteTimeout": true,
  "pathMatchType": "PathPrefix"
}
```
