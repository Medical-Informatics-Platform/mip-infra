# Operations

Everyday tasks: work on a feature branch, add a federation, switch the notebook hub to the API proxy, change values, add a shared application, update dependencies.

## Work on a feature branch

Deploy a branch next to `main` without touching it.

1. Install the pre-commit hook. It stops you from committing `main` revisions on a feature branch, and runs the AppProject RBAC lint:

   ```bash
   cp .githooks/pre-commit .git/hooks/
   chmod +x .git/hooks/pre-commit
   ```

2. If the branch needs [`base/mip-infrastructure/mip-infrastructure.yaml`](../base/mip-infrastructure/mip-infrastructure.yaml) to follow it, change `main` to the branch in `spec.generators[*].git.revision` and `spec.template.spec.source.targetRevision`. The hook blocks the commit if you forget one.

3. Deploy the branch:

   ```bash
   CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   SAFE_BRANCH_NAME=$(echo "$CURRENT_BRANCH" | sed 's/[^a-zA-Z0-9]/-/g')

   kubectl apply -f base/argo-projects/argo-projects.yaml   # AppProject generators from the branch

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

4. Remove it:

   ```bash
   argocd app delete "${SAFE_BRANCH_NAME}-infra-clusterset" --yes
   argocd app delete "${SAFE_BRANCH_NAME}-argo-projects"    --yes
   ```

## Add a federation

### Local federation (everything on this cluster)

1. Create `deployments/local/federations/federation-<name>/`. Copy `kustomization.yaml` and `customizations/` from `federation-A`.
2. Set `namePrefix` in `kustomization.yaml` to the federation name, and adjust the values in `customizations/`.
3. Commit and push to the branch the ApplicationSet follows. The `mip-infrastructure` ApplicationSet creates the federation's Application. The `argo-projects` ApplicationSet creates its AppProject `mip-argo-project-federation-<name>`.
4. Create the federation's Secrets ([getting-started.md, step 6](getting-started.md#6-create-the-secrets)).
5. Notebooks need nothing more. Within five minutes the CronJob `mip-notebook-rbac-manager` binds the notebook operator and JupyterHub in the new namespace. Check: `kubectl -n federation-<name> get rolebinding mip-notebook-operator mip-jupyterhub`.

### Hybrid federation (controller here, workers on remote nodes)

1. Create `deployments/hybrid/federations/<federation>/mip-infrastructure/` from `federation-Z`: `kustomization.yaml`, `customizations/`, `network-policies.yaml`, `submariner-policies/` (worker DNS names, one `ipBlock` per remote pod CIDR, the ServiceExport) and `remote-networks.yaml` (pod and service CIDR of each remote node).
2. Copy `remote-node/` and `enrollment/` for the new federation. The sites follow its runbook.
3. Commit and push. The ApplicationSets find `deployments/hybrid/federations/*/mip-infrastructure`, and `federation-remote-networks` reads its `remote-networks.yaml`.
4. Create the federation's Secrets, as for a local federation.
5. Join each remote node ([hybrid-federations.md](hybrid-federations.md#add-a-remote-node)).
6. Notebooks work as for a local federation.

## Add a remote node to a hybrid federation

See [hybrid-federations.md](hybrid-federations.md#add-a-remote-node) and the runbook `deployments/hybrid/federations/<federation>/remote-node/README.md`.

## Switch the hub to the notebook API proxy

The proxy (`common/notebook-operator/manifests/api-proxy.yaml`) runs before any hub uses it. The hub side needs the `madgik/mip` chart value `jupyterhub.apiProxy`.

1. Check the proxy: `kubectl -n mip-notebooks-system get deploy notebook-api-proxy certificate notebook-api-proxy` and `kubectl -n federation-<x> get configmap notebook-api-proxy-ca`.
2. Set `jupyterhub.apiProxy.enabled: true` in `deployments/shared-apps/mip-stack/values.yaml`, sync, and spawn a notebook.
3. Set `apiServer.hubDirect: false` in `common/security/federation/values.yaml`, sync, and spawn again. The hub can no longer reach the API server directly.

## Change the values of one federation

Each federation patches the shared applications of `deployments/shared-apps/`:

1. Edit `deployments/local/federations/<federation>/customizations/<app>-values.yaml`.
2. For structural changes, edit the matching Kustomize patch, such as `exareme2-kustomize.yaml`.

Argo CD applies the change at the next sync.

## Add a shared application

1. Add it under `deployments/shared-apps/<app>/`: manifests, or a Helm chart with values.
2. Reference it from the `kustomization.yaml` of each federation that needs it.
3. Check that the AppProject allows the resource kinds it uses: [`projects/static/`](../projects/static/) and [`projects/templates/federation/`](../projects/templates/federation/).

## Update Argo CD

See [argo-setup/README.md](../argo-setup/README.md#bumping-argo-cd).

## Dependency updates

Two bots open pull requests. Nothing merges without review.

**Renovate** ([`renovate.json5`](../renovate.json5)) covers everything except GitHub Actions. Its Dependency Dashboard issue lists every tracked dependency.

- External charts (exareme2, mip-stack, datacatalog): the `targetRevision` commit and its `# <version>` comment move together. The shared-apps baselines and the overrides under `deployments/hybrid/federations/**` get separate pull requests; the exareme2 chart and `exaflow_images.version` move in one.
- Argo CD (`argo-setup/patches/kustomization.yaml`): the pull request runs the ClusterRole drift check and the kind smoke test. Follow [argo-setup/README.md](../argo-setup/README.md#bumping-argo-cd) before you merge.
- The Submariner charts, the ECK stack (annotated keys in `common/monitoring/eck/values.yaml`, one pull request) and the HAProxy ingress image.
- The yq and kustomize binaries of CI: version and SHA-256 together.
- The images of the Submariner gateway-node DaemonSets (`common/submariner/operator/gateway-*.yaml`). `alpine/kubectl` gets patch and digest updates only: the watchdog's kubectl must stay within one minor version of the central API server, so change its minor by hand, together with the cluster.

**Dependabot** ([`.github/dependabot.yml`](../.github/dependabot.yml)) updates the GitHub Actions once a month, in one pull request, pinned by SHA with a `# vX.Y.Z` comment. Renovate's GitHub Actions manager is off, so the bots never open the same update.
