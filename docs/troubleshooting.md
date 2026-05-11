# Troubleshooting

Common failure modes for the MIP infra GitOps flow, and how to read Argo CD status quickly.

## Reading Argo CD status

```bash
argocd app list                  # one-line health of every Application
argocd app get  <app-name>       # full status, last sync, conditions
argocd app diff <app-name>       # what Git wants vs what the cluster has
argocd app sync <app-name>       # force a reconciliation
```

| Status | Meaning |
|---|---|
| 🟢 **Synced + Healthy** | Cluster matches Git; workload is up. |
| 🟡 **OutOfSync** | Git changed (or someone hand-edited a resource). Usually fixed by `argocd app sync`. |
| 🔴 **Degraded** | Resources applied but not healthy (CrashLoopBackOff, failing readiness, etc.). |
| ❌ **Failed / Unknown** | Sync error — check `argocd app get` conditions and the controller logs. |

## Common issues

### "Permission denied" creating the infra Application

The destination AppProject does not exist yet. The bootstrap is staged on purpose — see [getting-started.md §5](getting-started.md#5-bootstrap-the-appprojects).
Order is: `default` AppProject → `mip-argo-project-infrastructure` →`argo-projects` ApplicationSet → everything else.

### "Cannot delete default AppProject"

Some Argo CD installs protect it. Either:
- Force it: `argocd proj delete default --cascade` (admin required).
- Or rely on the deny-all override in [`base/argo-projects.yaml`](../base/argo-projects.yaml) — it overwrites `default` with empty allowlists.

### Application stuck `OutOfSync` or `Unknown`

```bash
argocd app sync <app>
argocd app get  <app>     # look at the Conditions block
```

Typical causes:
- The branch in `--revision` doesn't exist or doesn't contain `--path`.
- Manifest errors (Kustomize build failure, Helm template error).
- The destination namespace or AppProject is missing.

### Application stuck `Deleting` because of finalizers

Many Applications in this repo carry Argo CD's resource finalizer:
`resources-finalizer.argocd.argoproj.io`. That is useful when deleting an
Application should also delete its managed resources before the Application
object itself disappears.

Not every Application should use it. For controller-plus-custom-resource stacks
where teardown must happen in a strict order, omitting the Argo CD Application
finalizer is often the safer choice.

First check whether the Application really is in delete flow:

```bash
kubectl get applications.argoproj.io -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers'

argocd app get <app>
kubectl get application <app> -n <argocd-namespace> -o yaml
```

What to look for:
- `metadata.deletionTimestamp` is set and `metadata.finalizers` still contains
  `resources-finalizer.argocd.argoproj.io`.
- `argocd app get <app>` shows a `DeletionError` condition.
- If the Application manages child Applications, fix the child first. The parent
  will stay stuck until the child deletion completes.
- Check the live managed resources too. A controller-owned resource may still
  have its own finalizers, which blocks Argo from finishing the delete.

Example from this repo:
- `common-submariner` can stay in `Deleting` while waiting on the child
  Application `submariner-operator`.
- The live `Submariner` custom resource may still exist in
  `submariner-operator` with finalizers such as
  `controllers.submariner.io/cleanup` and `foregroundDeletion` while the
  operator performs uninstall cleanup.

Current repo behavior for Submariner:
- The child Applications in [common/submariner/submariner.yaml](../common/submariner/submariner.yaml) intentionally omit the Argo CD Application finalizer.
- This avoids tearing down the `submariner-operator` Deployment and the live `Submariner` custom resource in the same cascading delete.
- This is deliberate for production too: the normal lifecycle is deploy once and update in place, so orphaning the live Submariner resources is safer than risking an accidental cascading teardown of cluster networking.
- If you actually want to uninstall Submariner, delete the `Submariner` custom resource first, wait for its cleanup finalizers to clear, then remove the remaining workloads.

Useful checks:

```bash
kubectl get application <app> -n <argocd-namespace> -o jsonpath='{.status.conditions[*].type}{"\n"}{.status.conditions[*].message}{"\n"}'

kubectl get <kind> <name> -n <namespace> -o yaml | rg 'deletionTimestamp|finalizers'
```

Safe order of operations:
- Prefer to let the owning controller finish cleanup first.
- If a child Application is stuck, inspect its managed resources before touching
  the parent Application.
- Remove an Application finalizer manually only as a last resort, after you have
  confirmed that orphaning the remaining resources is acceptable or that the
  resources are already gone.

Last resort manual escape hatch:

```bash
kubectl patch application <app> -n <argocd-namespace> --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

Use that only when you understand what will be left behind. Clearing the Argo CD
Application finalizer does not clear finalizers on managed resources.

### Helm "invalid map key" errors

Example: `invalid map key: map[interface {}]interface {}{".Values.controller.cleanup_file_folder":interface {}(nil)}`

Cause: a values file uses a Go template expression as a YAML map key
(invalid). Inspect the offending values file for:
- Template expressions used as keys.
- Bad indentation.
- Unquoted special characters.

### Workload pods stuck `ContainerCreating` / `Init`

The pod is waiting for a secret. Run [`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) (see [getting-started.md §3](getting-started.md#3-provision-required-secrets)) and resync.

### Browser cannot reach the Argo CD UI, but `argocd login --grpc-web` works

If you followed [remote-access.md](remote-access.md) Option B, check the exact URL in the browser:

- `argocd login <argocd-host>:8443 --grpc-web ...` uses the local SSH tunnel.
- `https://<argocd-host>:8443/` is the matching browser URL.
- `https://<argocd-host>/` is different: with `/etc/hosts` pointing the host to `127.0.0.1`, the browser will try local port `443`, which fails unless you also forwarded local `443`.
- If you bypass the local override and hit the real public Ingress on `443`, the connection may still time out if your source IP is not allowlisted.

### `haproxy-public` Ingress stays `Progressing` with empty `ADDRESS`

Argo CD keeps an Ingress `Progressing` when `.status.loadBalancer` stays empty.
For the public HAProxy controller, check the status publication path in this
order:

```bash
kubectl get ingress -A -o wide | grep haproxy-public
kubectl -n ingress-nginx get svc haproxy-public-controller -o wide
kubectl get certificate -A
kubectl -n ingress-nginx logs deploy/haproxy-public-controller --tail=100
```

What to look for:
- The `haproxy-public-controller` Service must already have its external IP.
- A missing TLS secret can block a specific Ingress, but if multiple `haproxy-public` Ingresses with ready certificates still show no `ADDRESS`, the common issue is controller status publication rather than cert-manager.
- RBAC in [base/mip-infrastructure/rbac/haproxy-public-rbac.yaml](../base/mip-infrastructure/rbac/haproxy-public-rbac.yaml) must allow `update` and `patch` on `ingresses/status`.
- The controller image pin lives in [common/haproxy-ingress/manifests/haproxy-public-deployment.yaml](../common/haproxy-ingress/manifests/haproxy-public-deployment.yaml).
- On staging, `haproxytech/kubernetes-ingress:3.2.6` was observed reconciling backend config without backfilling Ingress `status.loadBalancer`; this repo now pins `3.2.8`.

### `portalbackend-*` pod stuck at `1/2`

Known bug. Delete the init job and the deployment proceeds:

```bash
kubectl delete -n federation-<X> job create-dbs
```

### "Branch not found" / "Path not found"

Argo CD couldn't resolve `--revision` + `--path` against the repo. Check that:
- The branch name is spelled exactly (case-sensitive).
- The path exists at that revision (try `git ls-tree <branch> -- <path>`).
- The repo is registered with Argo CD (`argocd repo list`).

### Pre-commit hook does nothing

You probably copied it but forgot to enable it:

```bash
cp .githooks/pre-commit .git/hooks/
chmod +x .git/hooks/pre-commit
```

Or, repo-wide: `git config core.hooksPath .githooks`.

### Sync introduces RBAC and fails loudly

Working as designed. AppProjects denylist `Role`, `RoleBinding`, `ClusterRole`,  `ClusterRoleBinding`, webhooks, and (mostly) CRDs. If a chart
upgrade newly ships RBAC, the sync will fail before doing damage. Either:

- Drop the RBAC from the chart (preferred), or
- allowlist explicitly in the relevant AppProject manifest under [`../projects/static/`](../projects/static/) or [`../projects/templates/federation/`](../projects/templates/federation/) after reviewing the extra permissions.

## Glossary

| Term | Definition |
|---|---|
| **Application** | An Argo CD object that maps a Git path to a Kubernetes target. |
| **ApplicationSet** | Generator that materialises many Applications from a template (list, git, cluster…). |
| **AppProject** | Security boundary for Applications: which repos, clusters, namespaces, and resource kinds are allowed. |
| **Federation** | A data-sharing network of medical institutions (`federation-A`, `federation-B`, …). |
| **GitOps** | Deployment model where Git is the source of truth and a controller reconciles the cluster to it. |
| **Kustomize** | Template-free YAML overlay tool used throughout this repo. |
| **Sync** | Argo CD reconciling cluster state to Git. |
| **OutOfSync** | Cluster doesn't match Git. |
| **Self-Heal** | Argo CD auto-correcting drift caused by manual cluster edits. |
| **Prune** | Deleting resources that exist in the cluster but no longer in Git. |
