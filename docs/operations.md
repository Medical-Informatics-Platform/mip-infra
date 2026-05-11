# Operations

Day-2 tasks: feature-branch development, adding federations, adding clusters, adding shared apps, customising values.

## Feature-branch workflow

To deploy a feature branch alongside `main` without disturbing it:

### 1. Install the pre-commit hook

The hook prevents accidentally committing `main` revisions while on a feature branch (and runs the AppProject RBAC lint).

```bash
cp .githooks/pre-commit .git/hooks/
chmod +x .git/hooks/pre-commit
```

### 2. Point the ApplicationSet at your branch

If your changes need [`base/mip-infrastructure/mip-infrastructure.yaml`](../base/mip-infrastructure/mip-infrastructure.yaml) to track your branch, edit:

- `spec.generators[*].git.revision`
- `spec.template.spec.source.targetRevision`

Change `main` → `<your-branch>`. The pre-commit hook blocks the commit if you forget.

### 3. Deploy your branch

Same flow as the main bootstrap, but scoped to your branch name:

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
SAFE_BRANCH_NAME=$(echo "$CURRENT_BRANCH" | sed 's/[^a-zA-Z0-9]/-/g')

# Refresh the AppProject generators from your branch
kubectl apply -f base/argo-projects.yaml

argocd app create "${SAFE_BRANCH_NAME}-infra-clusterset" \
  --repo https://github.com/Medical-Informatics-Platform/mip-infra.git \
  --path base/mip-infrastructure \
  --revision "$CURRENT_BRANCH" \
  --project mip-argo-project-infrastructure \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd-mip-team

argocd app sync "${SAFE_BRANCH_NAME}-infra-clusterset"
argocd app get  "${SAFE_BRANCH_NAME}-infra-clusterset"
```

### 4. Tear down

```bash
argocd app delete "${SAFE_BRANCH_NAME}-infra-clusterset" --yes
argocd app delete "${SAFE_BRANCH_NAME}-argo-projects"    --yes
```

## Adding a federation

1. Create a new directory under `deployments/local/federations/`, e.g.`federation-B/` in the correct repository.
2. Copy `kustomization.yaml` and `customizations/` from an existing federation (the `federation-A` skeleton is a good starting point).
3. Update `namePrefix` in `kustomization.yaml` to your federation name.
4. Adjust per-federation values in `customizations/`.
5. Commit and push to the branch the ApplicationSet tracks. The `mip-infrastructure` ApplicationSet auto-discovers the new directory and creates the wrapper Application; `argo-projects` ApplicationSet creates the matching `mip-argo-project-federation-<name>` AppProject.
6. Provision the per-federation secrets — see [getting-started.md §3](getting-started.md#3-provision-required-secrets).

## Customising applications per federation

Each federation patches the shared app templates from `deployments/shared-apps/`. To override values:

1. Edit `deployments/local/federations/<fed>/customizations/<app>-values.yaml`.
2. If you need structural overrides, modify the matching kustomize patch(e.g. `exareme2-kustomize.yaml`).

Argo CD detects the change on the next sync.

## Adding a shared application

To make a new application available to every federation:

1. Add the app under `deployments/shared-apps/<my-app>/` (manifests or Helm chart + values).
2. Reference it from each federation's `kustomization.yaml` that should pull it in.
3. Verify the destination AppProject permits the resource kinds your app needs by reviewing the relevant manifests under [`../projects/static/`](../projects/static/) or [`../projects/templates/federation/`](../projects/templates/federation/).

## Bumping Argo CD

See [argo-setup/README.md](../argo-setup/README.md#bumping-argo-cd).
