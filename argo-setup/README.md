# Argo CD – Small‑Team HA Install

This overlay bootstraps a **production-ready, Highly Available** Argo CD instance for a small DevOps / Platform team (≈ < 100 Applications to start) running on a single Kubernetes cluster.

> **External access:** an `Ingress` is shipped in [`patches/argocd-server-ingress.yaml`](patches/argocd-server-ingress.yaml). It assumes a Traefik ingress class with a `letsencrypt` cluster issuer and uses `argocd.example.com` as a placeholder — rewrite that to your real DNS record before applying (the [Bootstrap](#bootstrap) section below does this with a one-liner `sed`). The server runs in `--insecure` mode so Traefik terminates TLS; CLI usage: `argocd login <host> --grpc-web`. If you don't have an ingress controller yet, port-forward instead: `kubectl -n argocd-mip-team port-forward svc/argocd-server 8080:443`.

## Repository layout

```
argo-setup/
├── README.md                       # what you're reading now
├── upstream-snapshot/              # vendored upstream RBAC for drift-check
└── patches/
    ├── kustomization.yaml
    ├── argocd-server-ingress.yaml
    ├── poddisruptionbudgets.yaml
    ├── patch-argocd-application-controller-resources.yaml
    ├── patch-argocd-repo-server-resources.yaml
    ├── patch-argocd-server-resources.yaml
    ├── patch-argocd-dex-server-resources.yaml
    ├── patch-argocd-redis-ha-statefulset.yaml
    ├── patch-argocd-cmd-params-cm.yaml
    ├── patch-argocd-cm.yaml
    ├── patch-argocd-rbac-cm.yaml                                  # UI/API authorization (Layer 3)
    ├── patch-argocd-application-controller-clusterrole.yaml       # full-replace of upstream rules
    ├── patch-argocd-server-clusterrole.yaml                       # full-replace of upstream rules
    ├── patch-argocd-applicationset-controller-clusterrole.yaml    # empties out cluster-wide grants
    ├── patch-argocd-application-controller-clusterrolebinding.yaml
    ├── patch-argocd-server-clusterrolebinding.yaml
    └── patch-argocd-applicationset-controller-clusterrolebinding.yaml
```

> ClusterRoleBindings are inherited from the upstream HA base, but we still patch them explicitly: kustomize's `namespace:` directive does **not** reliably rewrite `subjects[].namespace` on cluster-scoped bindings coming from a remote base, so we point them at `argocd-mip-team` via the `patch-argocd-*-clusterrolebinding.yaml` patches.
> 
> See [`docs/rbac-layers.md`](../docs/rbac-layers.md) for the full RBAC and privilege map across all four layers, and the open hardening TODOs.

## Versioning strategy

We pin a **specific Argo CD release** in [`patches/kustomization.yaml`](patches/kustomization.yaml). Renovate (or a manual PR) bumps the pinned tag.

See [Bumping Argo CD](#bumping-argo-cd) below for the upgrade procedure.

## Prerequisites

- Kubernetes cluster with ≥ 3 schedulable worker nodes (HA anti-affinity for the 3-replica redis statefulset).
- `kubectl` v1.27+ and `kustomize` (standalone or `kubectl kustomize`).
- Argo CD CLI installed locally.
- A way to reach the cluster API (Ingress, port-forward, bastion, VPN).

## Bootstrap

> Use this for a **manual bootstrap**; in GitOps you'd just sync the overlay.

```bash
ARGOCD_NS=argocd-mip-team
ARGOCD_HOST=argocd.your-domain.tld           # your real DNS record

# 1. Rewrite the placeholder hostname in the overlay
#    BSD-style (macOS):
LC_ALL=C find . -type f -not -path '*/.git/*' \
  -exec sed -i '' "s/argocd.example.com/${ARGOCD_HOST}/g" {} +
#    GNU-style (Linux):
LC_ALL=C find . -type f -not -path '*/.git/*' \
  -exec sed -i "s/argocd.example.com/${ARGOCD_HOST}/g" {} +

# 2. Namespace
kubectl create namespace "$ARGOCD_NS"

# 3. Apply the overlay (upstream HA base + our patches in one shot).
#    Server-side apply is REQUIRED: the `applicationsets.argoproj.io` CRD
#    exceeds the 256 KiB limit for the client-side `last-applied-configuration`
#    annotation, and a plain `kubectl apply` fails with
#      metadata.annotations: Too long: may not be more than 262144 bytes
kustomize build patches \
  | kubectl apply -n "$ARGOCD_NS" --server-side -f -

# 4. Wait for the server rollout
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server

# 5. Read the bootstrap admin password and rotate
ARGO_TEMP_PW=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Initial 'admin' password: $ARGO_TEMP_PW"
argocd login "$ARGOCD_HOST" --grpc-web --username admin
argocd account update-password
kubectl -n "$ARGOCD_NS" delete secret argocd-initial-admin-secret --ignore-not-found
```

## Resource sizing

The baked-in requests/limits roughly double the upstream baseline to give safe headroom for a small but growing team. Adjust down if cluster-constrained, up as you add apps. Monitor with `kubectl top pods` or Prometheus.

| Component                     | Replicas | CPU Request | CPU Limit | Mem Request | Mem Limit |
| ----------------------------- | -------- | ----------- | --------- | ----------- | --------- |
| argocd-application-controller | 2        | 500m        | 2         | 1Gi         | 2Gi       |
| argocd-repo-server            | 2        | 500m        | 2         | 1Gi         | 2Gi       |
| argocd-server (API/UI)        | 2        | 200m        | 1         | 512Mi       | 1Gi       |
| argocd-dex-server             | 2        | 100m        | 400m      | 256Mi       | 512Mi     |
| argocd-redis-ha (per pod)     | 3        | 200m        | 1         | 512Mi       | 1Gi       |

## What the overlay changes

The canonical list of patches lives in [`patches/kustomization.yaml`](patches/kustomization.yaml) — it uses the modern `patches:` field (not the deprecated `patchesStrategicMerge`). The overlay's job is to adjust **only what we need** on top of the upstream HA manifest:

- Resource requests/limits (table above) and HA replica counts.
- Traefik `Ingress` + `--insecure` on `argocd-server` (TLS terminated at ingress).
- PodDisruptionBudgets for every workload.
- `seccompProfile: RuntimeDefault` on every pod (PSS-restricted).
- ClusterRole tightening (full-replace of upstream rules — see the note in `kustomization.yaml`).
- ClusterRoleBinding namespace rewrites.
- `argocd-cm` / `argocd-rbac-cm` / `argocd-cmd-params-cm` config (below).

## Config: `argocd-cm` customizations

Set in [`patches/patch-argocd-cm.yaml`](patches/patch-argocd-cm.yaml).

| Key                                  | Value                                  | Why                                                                            |
| ------------------------------------ | -------------------------------------- | ------------------------------------------------------------------------------ |
| `url`                                | `https://argocd.example.com`           | Public URL — rewritten by the `sed` step in [Bootstrap](#bootstrap).           |
| `application.resourceTrackingMethod` | `label`                                | Track managed resources by label; helps with pruning and external tooling.     |
| `application.instanceLabelKey`       | `argocd.argoproj.io/instanceTracking`  | Avoids collision with the standard `app.kubernetes.io/instance` Helm stamps.   |
| `installationID`                     | `mip-team-argo-cd`                     | Unique install identifier (multi-cluster analytics, logs).                     |
| `resource.respectRBAC`               | `normal`                               | Respect destination-cluster RBAC when listing resources.                       |
| `kustomize.buildOptions`             | `--enable-helm`                        | Allow kustomize overlays to inflate Helm charts (used by our deployments).    |
| `timeout.reconciliation`             | `180s`                                 | Upstream default; revisit if controller CPU is high or apps lag.               |
| `resource.exclusions`                | `EndpointSlice`, `Endpoints`, `Lease`  | Skip noisy / high-churn kinds Argo never reconciles as desired state.          |

`argocd-rbac-cm` (Layer 3 authz) is documented separately — see [`docs/rbac-layers.md`](../docs/rbac-layers.md).

## Bootstrap secrets

The upstream HA install ships an `argocd-secret` skeleton that needs to be populated with at minimum the server signing key, and (when SSO is wired up) the Dex / OIDC client secret. Use [`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) to generate the values, then apply via your secret-management workflow (SOPS / sealed-secrets / external-secrets) — do **not** check the populated `argocd-secret` into git.

## Post-install checks

```bash
ARGOCD_NS=argocd-mip-team
kubectl -n "$ARGOCD_NS" get pods
kubectl -n "$ARGOCD_NS" get ingress
kubectl -n "$ARGOCD_NS" get certificate argocd-server-tls \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
argocd login "$ARGOCD_HOST" --grpc-web
argocd version
```

## Bumping Argo CD

1. Pick the new tag (latest patch in the current minor line, or a deliberate minor bump after reviewing the upstream changelog).
2. Bump the pinned tag in [`patches/kustomization.yaml`](patches/kustomization.yaml) (the `resources:` entry pointing at `raw.githubusercontent.com/argoproj/argo-cd/<TAG>/manifests/ha/install.yaml`).
3. Run the RBAC drift check - it reads the upstream URL from `kustomization.yaml`, so do this *after* step 2:
   ```bash
   bash scripts/check-upstream-argo-clusterroles.sh
   ```
   It covers all three ClusterRoles we patch (`argocd-application-controller`, `argocd-server`, `argocd-applicationset-controller`) plus the seven namespaced `Role`s tracked in [`upstream-snapshot/roles.yaml`](upstream-snapshot/roles.yaml). If it reports drift, read the diff and decide for each new upstream rule whether it belongs in our tightened patches (`patch-argocd-{application-controller,server,applicationset-controller}-clusterrole.yaml`). Then refresh both snapshots in one shot and commit them in the same PR as the version bump:
   ```bash
   bash scripts/check-upstream-argo-clusterroles.sh --update
   ```
4. Re-render the overlay locally: `kubectl kustomize patches >/dev/null`.
5. Open a PR; CI runs the kustomize render and the drift check.
6. After merge, re-apply against the live cluster — `argo-setup/` is bootstrapped out-of-band, not self-managed by Argo CD:
   ```bash
   kustomize build argo-setup/patches \
     | kubectl apply -n argocd-mip-team --server-side --force-conflicts -f -
   kubectl -n argocd-mip-team rollout status deploy/argocd-server
   kubectl -n argocd-mip-team rollout status statefulset/argocd-application-controller
   ```
   > **Why `--force-conflicts`:** if any object on the cluster was ever applied client-side (the old `kubectl apply` without `--server-side`), its fields are owned by the manager `kubectl-client-side-apply`. A plain server-side apply will refuse to overwrite those fields with `Apply failed with N conflict(s)`. `--force-conflicts` transfers ownership to the `kubectl` server-side manager — safe here because the rendered overlay is the source of truth. After the first run, ownership is consistent and the flag is a no-op on subsequent bumps.
