# Argo CD v3.3.9 – Small‑Team HA Install

This readme bootstraps a **production‑ready, Highly Available** Argo CD
instance for a small DevOps / Platform team (≈ < 100 Applications to start)
running on a single Kubernetes cluster.

> **External access:** this overlay ships an example `Ingress` in
> [`patches/argocd-server-ingress.yaml`](patches/argocd-server-ingress.yaml) with
> placeholder hostnames. Update the host/TLS secret annotations to match your
> environment before applying. Alternatively, you can expose the UI via
> `kubectl -n argocd-mip-team port-forward svc/argocd-server 8080:443` or a
> `Service` of `type: LoadBalancer` configured out of band.
> The server still runs in `--insecure` mode (HTTP) so any external front end is
> responsible for TLS termination. CLI usage: `argocd login <host> --grpc-web`.

## Repository layout

```
argo-setup/
├── README.md                     # what you’re reading now
└── patches/                      # overlay manifests
    ├── kustomization.yaml
    ├── patch-argocd-application-controller-resources.yaml
    ├── patch-argocd-repo-server-resources.yaml
    ├── patch-argocd-server-resources.yaml
    ├── patch-argocd-dex-server-resources.yaml
    ├── patch-argocd-redis-ha-statefulset.yaml
    ├── patch-argocd-cmd-params-cm.yaml
    ├── patch-argocd-cm.yaml
    ├── patch-argocd-rbac-cm.yaml                              # UI/API authorization (Layer 3)
    ├── patch-argocd-application-controller-clusterrole.yaml   # full-replace of upstream rules
    ├── patch-argocd-server-clusterrole.yaml                   # full-replace of upstream rules
    └── patch-argocd-applicationset-controller-clusterrole.yaml # empties out cluster-wide grants
```

> ClusterRoleBindings are inherited unchanged from the upstream HA base; the
> kustomization `namespace:` directive rewrites `subjects[].namespace` to
> `argocd-mip-team`, so no override is needed.
>
> See [`docs/rbac-layers.md`](../docs/rbac-layers.md) for the full RBAC &
> privilege map across all four layers, and the open hardening TODOs.

## Versioning strategy

We track the **latest released patch in the Argo CD 3.0 line**. In automation and docs we refer to this as `**v3.1.latest**`. At deploy time we *resolve* that alias to the actual tag (e.g., `v3.1.11`, `v3.1.12`, etc.) and commit the resolved tag into Git.

Pin that value in your overlays (below) when promoting to prod.

## Prerequisites

- Kubernetes cluster with ≥ 3 worker nodes (for HA anti‑affinity)
- `kubectl` v1.27+ and `kustomize` (stand‑alone or `kubectl kustomize`)
- Argo CD CLI installed locally
- A way to reach the cluster API (port-forward, bastion, VPN) — no Ingress
  is shipped here; see the note at the top of this file.

## Quick start

> Use this for a **manual bootstrap**; in GitOps you'd just sync the overlay.

```
# 0. Vars
ARGOCD_NS=argocd-mip-team

# Resolve latest 3.0 version (or pin to specific version)
export ARGOCD_SERIES=v3.0
export ARGOCD_VER=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases \
  | grep -E '"tag_name": *"'${ARGOCD_SERIES}'[0-9.]*"' \
  | cut -d '"' -f4 \
  | sort -Vr \
  | head -n1)
echo "Resolved latest 3.0 tag: $ARGOCD_VER"

# Update kustomization.yaml with resolved version
# BSD-Style
sed -i '' "s|/v[0-9.]*/manifests/ha/install.yaml|/${ARGOCD_VER}/manifests/ha/install.yaml|g" patches/kustomization.yaml
# GNU-Style
sed -i "s|/v[0-9.]*/manifests/ha/install.yaml|/${ARGOCD_VER}/manifests/ha/install.yaml|g" patches/kustomization.yaml

# 1. Namespace
kubectl create namespace $ARGOCD_NS

# 2. Upstream HA base (pinned tag)
kubectl apply -n $ARGOCD_NS -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VER}/manifests/ha/install.yaml

# 3. Apply our overlay (resource limits, RBAC tightening, CM/RBAC-CM settings)
kustomize build patches | kubectl apply -f -

# 4. Wait for pods
kubectl -n $ARGOCD_NS get pods -w

# 5. Initial admin password & rotate
ARGO_TEMP_PW=$(kubectl -n $ARGOCD_NS get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Initial "admin" password: $ARGO_TEMP_PW"
argocd login $ARGOCD_HOST --grpc-web
argocd account update-password
kubectl -n $ARGOCD_NS delete secret argocd-initial-admin-secret
```


## Resource sizing

**All patch files below double that baseline** to give safe headroom for a small but growing team. Adjust downward if cluster‑constrained; upward as you add apps.

### Current sizing baked into patches


| Component                     | Replicas | CPU Request | CPU Limit | Mem Request | Mem Limit |
| ------------------------------- | ---------- | ------------- | ----------- | ------------- | ----------- |
| argocd-application-controller | 2        | 500m        | 2         | 1Gi         | 2Gi       |
| argocd-repo-server            | 2        | 500m        | 2         | 1Gi         | 2Gi       |
| argocd-server (API/UI)        | 2        | 200m        | 1         | 512Mi       | 1Gi       |
| argocd-dex-server             | 2        | 100m        | 400m      | 256Mi       | 512Mi     |
| argocd-redis-ha (per pod)     | 3        | 200m        | 1         | 512Mi       | 1Gi       |

> To monitor pod usage and adjust: `kubectl top pods` or Prometheus

## Kustomize overlay install

The overlay adjusts **only what we need**: resources limitations, HA replica counts, TLS‑terminating ingress, `server.insecure`, and our Argo CD config overrides (resourceTrackingMethod, instanceLabelKey, installationID).

### patches/kustomization.yaml

See the live file in [`patches/kustomization.yaml`](patches/kustomization.yaml)
— the canonical list of patches lives there, not duplicated here.
The overlay uses the modern `patches:` field (not the deprecated
`patchesStrategicMerge`).

**Apply once:**

```
# Resolve and update version first
export ARGOCD_VER=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases \
  | grep -E '"tag_name": *"v3.0[0-9.]*"' \
  | cut -d '"' -f4 \
  | sort -Vr \
  | head -n1)
sed -i "s|/v[0-9.]*/manifests/ha/install.yaml|/${ARGOCD_VER}/manifests/ha/install.yaml|g" patches/kustomization.yaml

# Then apply
kustomize build patches | kubectl apply -f -
```

## Config: argocd-cm customizations

We set several global behaviors in `patch-argocd-cm.yaml`:


| Key                                  | Value                         | Why                                                                      |
| -------------------------------------- | ------------------------------- | -------------------------------------------------------------------------- |
| `application.resourceTrackingMethod` | `label`                       | Track managed resources by label; helps with pruning & external tooling. |
| `application.instanceLabelKey`       | `argocd.argoproj.io/instance` | Override default instance label key; matches our team label convention.  |
| `installationID`                     | `mip-team-argo-cd`            | Unique install identifier (multi‑cluster analytics, logs).              |

## Bootstrap secrets

The upstream HA install ships an `argocd-secret` skeleton that needs to be
populated with at minimum the server signing key, and (when SSO is wired up)
the Dex / OIDC client secret. Use [`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh)
to generate the values, then apply via your secret-management workflow
(SOPS / sealed-secrets / external-secrets) — do **not** check the populated
`argocd-secret` into git.

## Post-install checks

```
kubectl -n argocd-mip-team get ingress
kubectl -n argocd-mip-team get certificate argocd-tls -o yaml | grep -E 'Ready|Not Ready'
argocd login argocd.example.com --grpc-web
argocd version
```
