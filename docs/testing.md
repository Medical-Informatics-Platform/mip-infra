# Testing

The current upstream `main` branch relies on manual validation plus the
pre-commit hook. It does not yet ship a dedicated kind smoke-test or RBAC drift
script.

## Pre-commit hook

[`.githooks/pre-commit`](../.githooks/pre-commit) is the first line of defense.
Install it once per clone:

```bash
git config core.hooksPath .githooks
```

It enforces:

- static AppProject RBAC denylist checks (no static project may forget to
   blacklist `Role` and `RoleBinding`, unless explicitly opted out with
   `# rbac-lint: ignore`)
- feature-branch revision checks for critical manifests (`base/argo-projects.yaml`,
   `base/mip-infrastructure/mip-infrastructure.yaml`, `common/security/netpol.yaml`)

## Render checks

Before opening a PR, make sure the key manifests still render cleanly:

```bash
kubectl kustomize argo-setup/patches >/dev/null
kubectl apply --dry-run=client -f base/argo-projects.yaml >/dev/null
kubectl apply --dry-run=client -f projects/mip-infrastructure.yaml >/dev/null
```

If you changed a specific component under `common/` or `deployments/`, render
that path too.

## Cluster sanity checks

Once the manifests are applied to a real cluster, verify the bootstrap objects
and Applications show up as expected:

```bash
kubectl get applicationsets -n argocd-mip-team
kubectl get appprojects -n argocd-mip-team
argocd app list
argocd app get <app-name>
```

Expected steady state:

- the `default` AppProject is deny-all
- the static AppProjects exist in `argocd-mip-team`
- the `mip-infrastructure` ApplicationSet creates the expected Applications
- synced Applications move to `Healthy` after required secrets are present

## Secrets helper

[`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) is the only helper script
currently shipped on upstream `main`. Use it after the federation namespaces
exist to create the required `keycloak-credentials` and `mip-secret` objects.
