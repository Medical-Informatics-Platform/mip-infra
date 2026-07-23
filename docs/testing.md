# Testing

Three layers of validation run before changes reach `main`:

1. **Pre-commit hook + render checks** — fast, local.
2. **Argo CD overlay smoke test** (`kind-argo-smoke.yml`) — RBAC/PDB/netpol
   assertions against the HA Argo CD install on an ephemeral kind cluster.
3. **Component e2e** (`e2e.yml`) — on PRs that bump a cluster component
   (typically Renovate), the changed component is deployed on kind **through
   Argo CD** at the PR's revision and its services are exercised.

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

## Argo CD overlay smoke test (kind)

[`scripts/kind-argo-test.sh`](../scripts/kind-argo-test.sh) spins up a kind
cluster (1 control-plane + 3 workers — the redis-ha anti-affinity needs 3
schedulable nodes), applies `argo-setup/patches`, and asserts:

- all HA workloads reach Ready
- the tightened ClusterRoles are effective (positive + negative
  SubjectAccessReviews)
- PDBs exist and select live pods
- static AppProjects apply; `default` stays deny-all
- the repo-server NetworkPolicy actually blocks unauthorized traffic

CI runs it on PRs touching `argo-setup/**` and the static projects
([`kind-argo-smoke.yml`](../.github/workflows/kind-argo-smoke.yml)). Locally:

```bash
bash scripts/kind-argo-test.sh            # spin up, test, tear down
KEEP=1 bash scripts/kind-argo-test.sh     # leave the cluster running
```

## Component e2e (kind + Argo CD)

[`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml) maps the files a
PR changes to **profiles** (mapping lives in
[`scripts/e2e/changed-profiles.sh`](../scripts/e2e/changed-profiles.sh)) and
runs [`scripts/e2e/run-e2e.sh`](../scripts/e2e/run-e2e.sh) for each requested
profile on its own runner. Every profile installs the full HA Argo CD overlay
first, then deploys the component exactly like production — as an Argo CD
Application — and asserts *service-level* health: Argo `Synced`/`Healthy`,
rollout status, and in-cluster `curl` against the Services asserting response
**content** (an ingress 200 alone proves nothing about the app behind it).

| Profile | Triggered by | Deploys | Key assertions |
|---|---|---|---|
| `exareme2` | `deployments/shared-apps/exareme2/**`, federation exareme2 overrides | federation-A exareme2 | app Healthy; controller/worker/aggregation rollouts; PVCs Bound; `/healthcheck` (controller verifies its workers); `/algorithms` non-empty |
| `mip-stack` | `deployments/shared-apps/mip-stack/**`, federation mip-stack overrides | exareme2 (merged pin) + mip-stack | everything above; backend + UI rollouts; `pg_isready`; UI serves HTML; backend answers on a known endpoint |
| `eck` | `common/monitoring/**` | ECK operator (at the PR's `operator.version`) + 1-node ES + Kibana | Elasticsearch/Kibana CRs report `green`; ES `/_cluster/health` green via API; Kibana `/api/status` available |
| `haproxy` | `common/haproxy-ingress/**`, its out-of-band RBAC | haproxy-public + MetalLB + cert-manager | app Healthy; Service holds the pinned VIP; default cert Ready; echo-backend body served through the Ingress; unknown Host refused |
| `datacatalog` | `common/datacatalog/**` | datacatalog | app Healthy; rollouts; PVCs Bound; backend actuator `UP`; frontend serves HTML |
| `render` | `common/submariner/**`, federation-Z files | nothing (build-only) | submariner charts + federation overlays `kustomize build` cleanly |

Submariner gets no live profile: a single kind cluster cannot form an IPsec
mesh, so only the chart render is checked.

### How the PR revision reaches Argo CD

Committed Application manifests must keep `targetRevision: main` (enforced by
`check-main-revisions.yml`). The e2e runner renders the manifests and rewrites
`targetRevision: main` → the PR **head SHA** at runtime, then asserts that no
`main` reference and no `mip-deployments` reference survived (the `check_zero`
pattern). Argo CD inside kind then fetches that commit from the public repo.

Consequences:

- the branch must be **pushed** before the e2e can run (also true locally)
- fork PRs are skipped — Argo cannot fetch fork commits from the upstream
  repo URL. Renovate PRs are same-repo, so they are always tested.
- the e2e tests the PR head, not the would-be merge result

### Kind shims (`tests/e2e/`)

The production cluster contract is faked with the smallest possible shims;
production manifests and values deploy unmodified except where kind cannot
comply:

| Production expectation | CI shim |
|---|---|
| StorageClasses `ceph-corbo-cephfs`, `ceph-corbo-cephfs-retain` (CephFS, RWX) | same names backed by `rancher.io/local-path`; RWX claims downgraded to RWO via CI values |
| MetalLB pool `pool-no-auto` with VIP 148.187.143.44 | MetalLB installed with a /32 pool containing exactly that VIP (haproxy profile) |
| cert-manager + letsencrypt ClusterIssuers | cert-manager installed; letsencrypt issuers apply but ACME readiness is never load-bearing (a CI-only argocd-cm health override keeps Ready=False ClusterIssuers from degrading the app) |
| Keycloak at iam.ebrains.eu | `keycloak.enabled: false` + dummy `keycloak-credentials` (authentication off) |
| public ingress hosts | ingress disabled in federation/datacatalog profiles; exercised by the haproxy profile instead |
| interactive `scripts/gen_secrets.sh` | non-interactive `scripts/e2e/ci-secrets.sh` |

### Running a profile locally

```bash
git push origin HEAD                 # Argo must be able to fetch the commit
PROFILE=exareme2 KEEP=1 bash scripts/e2e/run-e2e.sh
kind delete cluster --name mip-e2e   # when done
```

`HEAD_SHA=<sha>` overrides the synced revision; `CLUSTER=<name>` the kind
cluster name. In CI each profile can also be run on demand via
`workflow_dispatch` (profile input).

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

[`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) creates the per-federation
`keycloak-credentials` and `mip-secret` objects (and the common datacatalog
secret) interactively. Use it after the federation namespaces exist. CI uses
the non-interactive [`scripts/e2e/ci-secrets.sh`](../scripts/e2e/ci-secrets.sh)
instead.
