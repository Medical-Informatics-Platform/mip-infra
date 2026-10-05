# RBAC & Privilege Map

> One page, four layers. Read top-down. Each layer narrows the layer above.
> Every "⚠" marks a known gap or wider-than-necessary grant.

```
 ┌──────────────────────────────────────────────────────────────┐
 │ Layer 1 — Kubernetes ServiceAccount RBAC (ClusterRole)       │ what the SA *can* do
 ├──────────────────────────────────────────────────────────────┤
 │ Layer 2 — Argo CD AppProject (white/blacklist)               │ what an App is *allowed* to sync
 ├──────────────────────────────────────────────────────────────┤
 │ Layer 3 — Argo CD UI/API RBAC (argocd-rbac-cm)               │ who can drive Argo
 ├──────────────────────────────────────────────────────────────┤
 │ Layer 4 — Workload-internal RBAC (Role/RoleBinding shipped)  │ what each pod can do
 └──────────────────────────────────────────────────────────────┘
```

The effective privilege of any sync is `Layer 1 ∩ Layer 2`.
Defense-in-depth fails when Layer 1 is broader than Layer 2.

---

## Layer 1 — ServiceAccount ClusterRoles

Two SAs, both cluster-scoped. Sources:
[`patch-argocd-application-controller-clusterrole.yaml`](../argo-setup/patches/patch-argocd-application-controller-clusterrole.yaml),
[`patch-argocd-server-clusterrole.yaml`](../argo-setup/patches/patch-argocd-server-clusterrole.yaml).

### `argocd-application-controller` — does the actual sync writes
| API group | Resources | Verbs | Notes |
|---|---|---|---|
| `*` | `*` | get/list/watch | needed for diff & health |
| core | `namespaces`, `configmaps`, `secrets`, `services`, `serviceaccounts`, `pvc` | C/U/D/P | From upstream |
| core | `pods` | **delete only** | tightened (was C/D/U/P) |
| `apps` | deployments, statefulsets, daemonsets, replicasets | C/U/D/P | From upstream |
| `batch` | jobs, cronjobs | C/U/D/P | From upstream |
| `rbac.authorization.k8s.io` | roles, rolebindings | **none** | intentionally **not granted** — namespaced RBAC from charts is not synced (see Layer 4) |
| `notebooks.mip.ebrains.eu` | notebookprofiles | C/U/D/P | NotebookProfile synced by `madgik/mip`; the hub ClusterRole `mip-jupyterhub` that grants `notebooks` is out-of-band and bound per federation by the notebook RBAC reconciler (Layer 4) |
| `networking.k8s.io` | ingresses, ingressclasses, networkpolicies | full | From upstream |
| `cert-manager.io` | certificates, issuers, **clusterissuers** | C/U/D/P | only project that needs ClusterIssuer is `mip-common` |
| `monitoring.coreos.com` | servicemonitors, prometheusrules | C/U/D/P | From upstream |
| `apiextensions.k8s.io` | customresourcedefinitions | C/U/D/P | only ECK chart needs CRDs at install; `mip-common` and `mip-monitoring` whitelist them |
| `admissionregistration.k8s.io` | mutating/validatingadmissionwebhooks | **none** | intentionally **not granted** — every AppProject blacklists Webhooks; if a future chart needs them, restore here AND whitelist in the AppProject in the same PR |
| `submariner.io`, `operator.openshift.io`, `config.openshift.io`, `projectcalico.org`, `network.openshift.io` | submariners/gateways/clusters/dnses/networks/ippools/etc. | mixed | submariner-only |
| `projectcalico.org` | tiers; `tier.globalnetworkpolicies` named `remote-clusters.*` | C/U/D/P | `mip-security` only: confinement of the Submariner remote CIDRs (`common/security/remote-clusters`); Calico's tiered-policy RBAC, no write on default-tier policies |
| `multicluster.x-k8s.io` | serviceexports | C/U/D/P | hybrid federations export the aggregation server and controller to remote nodes |
| ECK groups (`elasticsearch.k8s.elastic.co`, etc.) | elasticsearches, kibanas, beats, … | C/U/D/P/G/L/W | mip-monitoring-only |

### `argocd-server` — read-mostly, drives the UI
| API group | Resources | Verbs |
|---|---|---|
| core | events, namespaces, configmaps, **secrets**, services, pvc | get/list/watch |
| core | pods, pods/log | G/L/W + delete + patch |
| `argoproj.io` | applications, applicationsets, appprojects, workflows | G/L/W + delete + patch |
| `apps` | deployments, replicasets, statefulsets, daemonsets | G/L/W + delete |
| `batch` | jobs | G/L/W + create + delete |
| `networking.k8s.io` | networkpolicies, ingresses, ingressclasses | G/L/W + delete + patch |
| `cert-manager.io` | clusterissuers | **read-only** (tightened — was C/U/D/P) |

**Layer 1 status:** fully reviewed. All four Argo CD SAs (controller, server,
applicationset-controller, notifications-controller) are in scope:
- `argocd-application-controller` and `argocd-server` ClusterRoles — tightened
  vs upstream `*/*/*` (see tables above).
- `argocd-applicationset-controller` ClusterRole — replaced with empty rules;
  the upstream namespaced Role suffices since we never set
  `application.namespaces`.
- `argocd-notifications-controller` — no ClusterRole upstream; the namespaced
  Role only reads its own `argocd-notifications-{cm,secret}` and writes back
  to Application status. Kept as-is.

The one residual *intentional* over-grant is CRD write on the controller, which
exceeds most AppProject whitelists. Splitting it off would need a second SA;
leaving as-is because Layer 2 still rejects CRDs everywhere except
`mip-common`, `mip-monitoring`, and `submariner` (the three that need them).
Namespaced `roles`/`rolebindings` are **not** granted at all: the SA cannot
write RBAC in any namespace, whatever Layer 2 whitelists.

---

## Layer 2 — AppProject white/blacklists

Source of truth: [`projects/static/`](../projects/static/) and the per-fed template
[`projects/templates/federation/`](../projects/templates/federation/).

| Project | Destinations | Cluster writes allowed | Namespaced writes allowed | RBAC allowed |
|---|---|---|---|---|
| **mip-argo-project-infrastructure** | `argocd-mip-team` | `Namespace` | `Application`, `ApplicationSet`, `AppProject` | none |
| **mip-argo-project-common** | `ingress-nginx`, `mip-common-datacatalog` | `Namespace`, `PV`, `IngressClass`, `GatewayClass`, `ClusterIssuer` | workload kinds + Ingress + Gateway API routes | ❌ blacklisted |
| **mip-argo-project-monitoring** | `elastic-system` | none | workload kinds + Ingress + Gateway API routes + ECK CRs | ❌ blacklisted |
| **mip-argo-project-federations** *(umbrella)* | `argocd-mip-team` | none | `Application` only | ❌ blacklisted |
| **mip-argo-project-federation-`<name>`** *(per-fed, templated)* | `federation-<name>`, `argocd-mip-team` | `Namespace` | full workload set + Ingress + Gateway API routes + `NotebookProfile` | ❌ not whitelisted (hub binding by the notebook RBAC reconciler, Layer 4) |
| **mip-argo-project-security** | `federation-*`, `mip-common-*`, `argocd-mip-team` (nominal, cluster-scoped objects only) | `Namespace`, Calico `Tier`, `GlobalNetworkPolicy` | `NetworkPolicy` | ❌ blacklisted |
| **mip-argo-project-submariner** *(opted-out of lint)* | `submariner-k8s-broker`, `submariner-operator` | `CRD`, submariner.io CRs | full workload set | whitelisted at L2, **no L1 grant** (not synced) |

Every project also carries an explicit `clusterResourceBlacklist`:
`ClusterRole`, `ClusterRoleBinding`, `Mutating/ValidatingWebhookConfiguration`, `CustomResourceDefinition`.
**The submariner project allows `CRD` cluster-wide** (it has to). All others reject.

A pre-commit hook
([`.githooks/pre-commit`](../.githooks/pre-commit))
fails the commit if any static AppProject lacks `Role`+`RoleBinding` in `namespaceResourceBlacklist`,
unless the file has `# rbac-lint: ignore` near the top.

---

## Layer 3 — Argo CD UI / API RBAC

Configured via `argocd-rbac-cm` (not in this repo today — defaults to upstream).
Project policies are declared inside each AppProject under `roles:`:

| Group | Granted on | Verbs |
|---|---|---|
| `argocd-admins` | every project's `<project>-admin` role | applications: get/create/update/delete/sync |
| `argocd-operators` | most projects' `<project>-operator` role | applications: get/sync |
| `argocd-developers` | federation projects' `federation-developer` role | applications: get/sync |

⚠ **Gaps:**
- `argocd-rbac-cm` itself isn't tracked in this repo — global policy (default role, scopes, OIDC group → policy mapping) is implicit and lives wherever Argo was bootstrapped.
- `default` AppProject is correctly deny-all in [`base/argo-projects.yaml`](../base/argo-projects.yaml).

---

## Layer 4 — Workload-internal RBAC (managed out-of-band)

Cluster-scoped RBAC for workloads is **not** synced through Argo CD (Layer 2 forbids it).
Instead it is shipped under [`base/mip-infrastructure/rbac/`](../base/mip-infrastructure/rbac/) and applied once at install time.

| File | Subjects | Scope |
|---|---|---|
| `eck-beats-rbac.yaml` | `eck-filebeat`, `eck-metricbeat` SAs in `elastic-system` | ClusterRole + ClusterRoleBinding |
| `haproxy-public-rbac.yaml` | `haproxy-public` SA in `ingress-nginx` | ClusterRole + ClusterRoleBinding **plus** namespaced Role + RoleBinding (leader-election in `ingress-nginx`) |
| `submariner-rbac.yaml` | submariner gateway/operator/routeagent/lighthouse | mixed cluster + namespaced (submariner-k8s-broker, submariner-operator) |
| `../notebook-operator/rbac.yaml` | `mip-notebook-operator` and `mip-notebook-rbac-manager` SAs in `mip-notebooks-system`; the `jupyterhub` SA of each federation | ClusterRoles `mip-notebook-operator` (pods/PVCs create, no Secrets; the only component that creates notebook pods) and `mip-jupyterhub` (`notebooks`, `secrets: create`), both bound by **RoleBinding** in every federation namespace by the reconciler CronJob (`common/notebook-operator/manifests/reconcile.sh`), never cluster-wide; the reconciler's ClusterRole (`namespaces` read, `rolebindings` write, `bind` on exactly those two ClusterRoles) and the `ValidatingAdmissionPolicy` that confines it; a second policy pins the hub's `secrets: create` to its own `jupyter-*-token` Opaque Secrets owned by a Notebook; the reconciler also copies the CA of the notebook API proxy into each federation (ConfigMap `notebook-api-proxy-ca`, read from the cert-manager request status, never from a Secret; no cluster-wide ConfigMap read) under a third policy that pins its ConfigMap writes to that one PEM key; leader-election Role |
| `submariner-remote-admission.yaml` | per-remote broker accounts `cluster-<id>` in `submariner-k8s-broker` | namespaced Role `submariner-remote-cluster` plus two cluster-scoped `ValidatingAdmissionPolicy` objects and their bindings (ownership of broker objects, subnet pinning) |

**Dynamic federation namespaces.** Nothing under Layer 4 names a federation. The CronJob
`mip-notebook-rbac-manager` (synced by Argo CD from `common/notebook-operator`; account, Role,
ClusterRole and policy out-of-band) binds the two notebook ClusterRoles in every namespace named
`federation-*` that carries `mip.namespace-type=federation`, removes its bindings from any other
namespace and maintains the operator's `WATCH_NAMESPACES` ConfigMap. The admission policy rejects
any other roleRef, subject, binding name or namespace from that account, so a compromise of it
cannot bind anything else anywhere; it may also restart the operator pod. The label is written by
the Argo CD controller (`managedNamespaceMetadata` of the `federation-network-policies`
ApplicationSet), which can only label its AppProject destination namespaces, where it already runs
workloads; the name prefix is checked as well. `kubectl auth can-i create pods --as=system:serviceaccount:<ns>:jupyterhub -n <ns>`
must answer `no` in every federation. Both policies use `failurePolicy: Fail`: a policy that no
longer compiles denies the requests it matches (every RoleBinding write, every Secret create)
for all callers until it is fixed or its binding deleted, which is why the kind smoke test checks
`status.typeChecking` and exercises them before merge.

⚠ **No automated check** that these out-of-band files stay in sync with the Helm charts they were extracted from. Procedure for re-extracting after upstream chart bump is undocumented.

⚠ **Namespaced RBAC is not synced either** (Layer 1 grants no `roles`/`rolebindings`),
so charts that ship their own `Role`/`RoleBinding` (`madgik/mip` JupyterHub,
submariner broker/operator) must have that RBAC applied out-of-band here —
their Layer-2 whitelists no longer imply a Layer-1 grant.
The hub's ClusterRole `mip-jupyterhub` only covers `notebooks` and `secrets: create` (`jupyterhub.spawner: operator`, `jupyterhub.rbac.create: false`): the notebook operator creates the pods, so neither the hub nor this controller holds `pods: create`, and the reconciler, not Argo CD, binds it per federation. **Cluster-scoped** RBAC from any chart is still rejected by Layer 2 and fails the sync loudly, which is the desired behavior.

---

## Quick "where could this go wrong" checklist

| Concern | Layer | Status |
|---|---|---|
| App project tries to manage Roles in a fed namespace | 2 | ✅ blocked, lint enforces |
| Someone hand-applies a ClusterRole using the controller SA | 1 | ✅ SA can't create ClusterRoles or Webhooks; CRDs intentional for the 3 projects that whitelist them |
| External Helm chart upgrade introduces cluster-scoped RBAC | 2 | ✅ sync fails loudly |
| External Helm chart upgrade introduces namespaced RBAC | 1 | ✅ sync fails loudly (SA holds no `roles`/`rolebindings`) |
| Out-of-band install RBAC drifts from upstream chart | 4 | ⚠ no check |
| UI user reads cluster-wide secrets | 1 + 3 | ✅ server cluster-wide secret read removed; only namespaced reads remain |
| New AppProject forgets RBAC blacklist | 2 | ✅ pre-commit blocks |
| New federation forgets notebook RBAC | 4 | ✅ nothing to add: bindings and watch list follow the namespace label |
| Reconciler account compromised | 4 | ✅ admission policies limit it to the two notebook bindings and the CA ConfigMap in `federation-*` namespaces, plus its own state ConfigMap |
| Hub pod reaches the API server | 4 | ⚠ today (`apiServer.hubDirect: true`, pinned to the control-plane addresses); the notebook API proxy is deployed and takes over once the chart points the hub at it; removal of every hub credential: [how-to-implement-the-notebook-properly.md](../how-to-implement-the-notebook-properly.md) |
| Git runs a workload as the operator SA (`mip-argo-project-common` targets `mip-notebooks-system`) | 2 | ⚠ accepted, same trust model as the other out-of-band SAs; the repository is the trust root |
| `default` AppProject misuse | 2 | ✅ deny-all |

## Glossary

- **C/U/D/P** = create / update / delete / patch
- **G/L/W** = get / list / watch
- **Layer-2 scope** is enforced at sync time by Argo CD; the SA *could* still touch resources outside it if invoked directly.

---

Pinned at Argo CD (../argo-setup/patches/kustomization.yaml). To bump:
edit the tag, run `bash scripts/check-upstream-argo-clusterroles.sh --update`,
review the diff, commit snapshot + tag together.

## Open hardening TODOs

### Security
- **SSO + disable local `admin`.** Today every operator shares the admin
  password and bypasses [argocd-rbac-cm](../argo-setup/patches/patch-argocd-rbac-cm.yaml).
  Configure Dex (or direct OIDC) in [argocd-cm](../argo-setup/patches/patch-argocd-cm.yaml),
  populate the client secret via the secrets workflow, set `admin.enabled: "false"`,
  and replace the placeholder group names (`argocd-admins`, `argocd-operators`)
  in the rbac-cm with real OIDC group claims.
- **CI diff check for upstream Argo CD ClusterRoles** ✅ done.
  [`scripts/check-upstream-argo-clusterroles.sh`](../scripts/check-upstream-argo-clusterroles.sh)
  compares against the snapshot in
  [`argo-setup/upstream-snapshot/clusterroles.yaml`](../argo-setup/upstream-snapshot/clusterroles.yaml);
  workflow [`argo-clusterroles-drift.yml`](../.github/workflows/argo-clusterroles-drift.yml)
  runs it on every PR that touches argo-setup and weekly on a cron.
- **Track `argocd-secret` bootstrap** end-to-end (signing key, repo creds,
  OIDC client secret) — currently only [`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh)
  exists; no glue between it and the install flow.

### Operability
- **Renovate (or equivalent) for the upstream Argo tag** in
  [patches/kustomization.yaml](../argo-setup/patches/kustomization.yaml) so the
  `sed`-at-install dance in the README becomes obsolete.
