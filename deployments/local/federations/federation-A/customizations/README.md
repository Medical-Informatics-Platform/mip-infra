# Federation-A Customization Guide

## Overview

This setup provides **unlimited customization** for Exareme2 and MIP-Stack deployments through a two-layer approach:

1. **Layer 1: Helm Values** - For values exposed by upstream charts
2. **Layer 2: Kubernetes Resource Overlays** - For ANY Kubernetes field, even if not exposed by Helm

**Key Principle**: Version is managed in **ONE place** (`shared-apps/`), while customization is **unlimited** and federation-specific.

## Quick Reference

### Change Versions

| Component | File | Field |
|-----------|------|-------|
| Exareme2 | `shared-apps/exareme2/exareme2.yaml` | `targetRevision` |
| MIP-Stack | `shared-apps/mip-stack/mip-stack.yaml` | `targetRevision` |

### Customize Components

| Task | File | Type |
|------|------|------|
| Exareme2 Helm values | `exareme2-values.yaml` | YAML values |
| Exareme2 ArgoCD App | `exareme2-kustomize.yaml` | JSON patches |
| Exareme2 K8s resources | `overlays/exareme2/*.yaml` | K8s patches |
| MIP-Stack Helm values | `mip-stack-values.yaml` | YAML values |
| MIP-Stack ArgoCD App | `mip-stack-kustomize.yaml` | JSON patches |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  ArgoCD Applications (Two-Wave Sync)                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌────────────────────────────────────────────┐             │
│  │ Wave 1: federation-a-exareme2              │             │
│  │  ├─ Helm Chart (from shared-apps/)         │             │
│  │  ├─ shared-apps/exareme2/values.yaml       │             │
│  │  └─ federation-A/exareme2-values.yaml      │ ◄── Layer 1 │
│  └────────────────────────────────────────────┘             │
│                     ▼                                       │
│         Generates base Kubernetes resources                 │
│         (Deployment, Service, PVC, etc.)                    │
│                     ▼                                       │
│  ┌────────────────────────────────────────────┐             │
│  │ Wave 2: federation-a-exareme2-overlay      │             │
│  │  └─ overlays/exareme2/                     │             │
│  │     ├─ Deployment (CPU/RAM/replicas)       │             │
│  │     ├─ Worker (scaling)                    │             │
│  │     ├─ Service (LoadBalancer)              │             │
│  │     ├─ PVC (storage)                       │             │
│  │     ├─ ConfigMap (custom config)           │             │
│  │     └─ HPA (autoscaling)                   │ ◄── Layer 2 │
│  └────────────────────────────────────────────┘             │
│                     ▼                                       │
│         Server-Side Apply merges overlay with base          │
└─────────────────────────────────────────────────────────────┘
```

## Layer 1: Helm Values & ArgoCD Customization

### exareme2-values.yaml

Override Helm chart values exposed by the upstream chart:

```yaml
---
log_level: DEBUG
  
storage:
  cephfs:
    storageClassName: ceph-corbo-cephfs
```

### exareme2-kustomize.yaml

Customize the ArgoCD Application using JSON patches:

```yaml
---
# Set ArgoCD project
- op: replace
  path: /spec/project
  value: mip-argo-project-federation-a

# Set namespace
- op: replace
  path: /spec/destination/namespace
  value: federation-a

# Add federation-specific values file
- op: add
  path: /spec/sources/0/helm/valueFiles/-
  value: $values/deployments/.../exareme2-values.yaml

# Ignore fields managed by overlays/cluster
- op: add
  path: /spec/ignoreDifferences
  value:
    - group: apps
      kind: Deployment
      name: exareme2
      jsonPointers:
        - /spec/replicas              # HPA manages this
        - /spec/template/spec/containers/0/resources  # Overlay manages this
```

**Key**: The `ignoreDifferences` section tells ArgoCD to ignore specific fields that are managed by:
- **HPA** (for replicas)
- **Overlay patches** (for resources)

Without this, ArgoCD would constantly revert these fields to Helm chart defaults.

### mip-stack-values.yaml & mip-stack-kustomize.yaml

Same pattern as Exareme2 but without overlaying (less customizations available) - see examples above.

## Layer 2: Kubernetes Resource Overlays (Exareme2)

### Directory: overlays/exareme2/

Customize **any field** in generated Kubernetes resources, even if not exposed by Helm.

### Example: High-Performance Configuration

**overlays/exareme2/exareme2-deployment-patch.yaml**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exareme2
  namespace: federation-a
spec:
  replicas: 5  # Override chart default
  template:
    spec:
      containers:
        - name: exareme2
          resources:
            limits:
              cpu: "4"
              memory: 8Gi
            requests:
              cpu: "1"
              memory: 2Gi
          env:
            - name: FEDERATION_ID
              value: "federation-a"
            - name: MAX_CONCURRENT_QUERIES
              value: "50"
      nodeSelector:
        workload-type: compute-intensive
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "federation-a"
          effect: "NoSchedule"
```

**overlays/exareme2/exareme2-hpa.yaml**

Add resources not in the chart:

```yaml
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: exareme2-hpa
  namespace: federation-a
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: exareme2
  minReplicas: 5
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Provided Overlay Files

| File | Patches | Purpose |
|------|---------|---------|
| `exareme2-deployment-patch.yaml` | Deployment/exareme2 | CPU, RAM, env vars, node selectors |
| `exareme2-service-patch.yaml` | Service/exareme2 | LoadBalancer, annotations |
| `exareme2-pvc-patch.yaml` | PVC/exareme2-data | Storage size |
| `exareme2-configmap-patch.yaml` | ConfigMap/exareme2-config | Custom configuration |
| `exareme2-hpa.yaml` | HPA/exareme2-hpa | **NEW** resource for autoscaling |

All overlays are combined in `overlays/exareme2/kustomization.yaml` and deployed via `exareme2-overlay-app.yaml` (sync-wave: 2).

## Common Tasks

### Increase CPU/Memory

Edit `overlays/exareme2/exareme2-deployment-patch.yaml`:

```yaml
resources:
  limits:
    cpu: "8"      # ← Change
    memory: 16Gi  # ← Change
```

### Add Environment Variables

In `exareme2-deployment-patch.yaml`:

```yaml
env:
  - name: MY_NEW_VAR
    value: "my-value"
```

### Adjust Autoscaling

Edit `overlays/exareme2/exareme2-hpa.yaml`:

```yaml
spec:
  minReplicas: 3   # ← Change
  maxReplicas: 50  # ← Change
  metrics:
    - type: Resource
      resource:
        name: memory  # ← Can change metric
        target:
          type: Utilization
          averageUtilization: 80  # ← Change threshold
```

### Increase Storage

Edit `overlays/exareme2/exareme2-pvc-patch.yaml`:

```yaml
spec:
  resources:
    requests:
      storage: 1Ti  # ← Change
```

### Create New Overlay

1. Create `overlays/exareme2/my-new-resource.yaml`
2. Add to `overlays/exareme2/kustomization.yaml`:
   ```yaml
   resources:
     - my-new-resource.yaml
   ```
3. Test: `kubectl kustomize overlays/exareme2`
4. Commit and push

## File Structure

```
federation-A/
├── customizations/
│   ├── README.md (this file)
│   │
│   ├── exareme2-values.yaml             ← Layer 1: Helm values
│   ├── exareme2-kustomize.yaml          ← Layer 1: ArgoCD App patches
│   ├── exareme2-overlay-app.yaml        ← Layer 2: Overlay Application
│   │
│   ├── mip-stack-values.yaml            ← Layer 1: Helm values
│   ├── mip-stack-kustomize.yaml         ← Layer 1: ArgoCD App patches
│   │
│   ├── REFERENCE-advanced-kustomization-examples.yaml  ← 📚 REFERENCE ONLY (untested alternative)
│   │
│   └── overlays/
│       └── exareme2/                    ← Layer 2: K8s resource patches
│           ├── kustomization.yaml       ← ACTIVE kustomization
│           ├── README.md                ← Overlay documentation
│           ├── exareme2-deployment-patch.yaml
│           ├── exareme2-service-patch.yaml
│           ├── exareme2-pvc-patch.yaml
│           ├── exareme2-configmap-patch.yaml
│           └── exareme2-hpa.yaml
│
├── kustomization.yaml                   ← Federation kustomization
└── federation-a.yaml                    ← Federation metadata

shared-apps/
├── exareme2/
│   ├── exareme2.yaml          ← DEFAULT SOURCE OF TRUTH (ex: chart version)
│   └── values.yaml            ← Shared Helm values
└── mip-stack/
    ├── mip-stack.yaml         ← DEFAULT SOURCE OF TRUTH (ex: chart version)
    └── values.yaml            ← Shared Helm values
```

## Decision Tree

```
Need to customize?
│
├─ Change version?
│  └─ Edit shared-apps/<component>/<component>.yaml
│
├─ Helm value (exposed in chart)?
│  └─ Edit <component>-values.yaml
│
├─ ArgoCD Application spec (project, namespace)?
│  └─ Edit <component>-kustomize.yaml (JSON patches)
│
└─ Kubernetes resource field (resources, env, etc)?
   └─ Edit overlays/<component>/<resource>-patch.yaml
      or create new overlay file
```

## Testing Locally

```bash
# Test overlay generation
cd overlays/exareme2
kubectl kustomize .

# Test federation kustomization
cd ../../../..
kubectl kustomize .

# Dry-run apply
kubectl kustomize . | kubectl apply --dry-run=client -f -
```

## Troubleshooting

### Changes Not Appearing

1. Check sync status:
   ```bash
   argocd app get federation-a-exareme2
   argocd app get federation-a-exareme2-overlay
   ```

2. Verify sync waves (overlay should be wave "n+1", base should be "n"):
   ```bash
   kubectl get app -n argocd-mip-team -l federation=federation-a
   ```

3. Force sync:
   ```bash
   argocd app sync federation-a-exareme2-overlay
   ```

### ArgoCD Keeps Reverting Changes

Check that `ignoreDifferences` is set in `exareme2-kustomize.yaml`:

```bash
kubectl get app federation-a-exareme2 -n argocd-mip-team -o yaml | grep -A 10 ignoreDifferences
```

If missing, add the JSON patch shown in the "Layer 1" section above.

### Resources Being Replaced Instead of Merged

Ensure Server-Side Apply is enabled in overlay app (`exareme2-overlay-app.yaml`):

```yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true
```

### Overlay Not Being Applied

Check that the overlay Application is deployed:

```bash
kubectl get app federation-a-exareme2-overlay -n argocd-mip-team
```

If missing, ensure `exareme2-overlay-app.yaml` is included in the federation's `kustomization.yaml`.

## Multi-Federation Setup

For additional federations (B, C), copy the customization structure:

```bash
# For a smaller federation-B
cp -r federation-A/customizations federation-B/customizations

# Customize for federation-B:
# - Update namespace/project in *-kustomize.yaml
# - Adjust resources in overlays/ (smaller config)
# - Update exareme2-overlay-app.yaml metadata
```

Each federation gets tailored resources without modifying shared-apps!

Example resource profiles:

| Federation | Replicas | CPU | Memory | Storage | HPA |
|------------|----------|-----|--------|---------|-----|
| A (Large) | 5 | 4 cores | 8Gi | 500Gi | 5-20 pods |
| B (Small) | 2 | 1 core | 2Gi | 100Gi | No HPA |
| C (Huge) | 10 | 8 cores | 16Gi | 1Ti | 10-50 pods |

## Advanced: Alternative Kustomization Approaches

The file `REFERENCE-advanced-kustomization-examples.yaml` shows an **alternative (untested)** approach to structuring kustomization with advanced features:

- **Strategic merge patches** (more explicit than simple resources)
- **JSON 6902 patches** (surgical changes to specific fields)
- **Common labels/annotations** (applied to all resources)
- **Image substitution** (useful for private registries)
- **Init containers** (pre-deployment initialization)
- **Security contexts** (fsGroup, runAsUser, etc.)

**Status**: Reference/example only - NOT currently used

**Current Approach**: Simple `overlays/exareme2/kustomization.yaml` that just lists resource files

**When to Consider the Alternative**:
- You need JSON 6902 patches for very specific field modifications
- You want to apply common labels/annotations to all resources at once
- You need to substitute image registries
- Your team prefers more explicit patch types

**If you want to try it**: Copy the content into `overlays/exareme2/kustomization.yaml` and test thoroughly with `kubectl kustomize overlays/exareme2`

## Best Practices

1. **Version management**: Always change versions in `shared-apps/` only
2. **Helm first**: Use Helm values for fields exposed by the chart
3. **Overlays for power**: Use overlays for fields not exposed by Helm
4. **Document patches**: Comment why each overlay exists
5. **Minimal patches**: Only include fields you're actually changing
6. **Test locally**: Run `kubectl kustomize` before committing
7. **Use ignoreDifferences**: For fields managed by HPA or other controllers

## Reference

- [ArgoCD Multi-Source Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [Kubernetes Server-Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)

