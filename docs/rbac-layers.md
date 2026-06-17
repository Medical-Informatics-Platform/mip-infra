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
| `networking.k8s.io` | ingresses, ingressclasses, networkpolicies | full | From upstream |
| `cert-manager.io` | certificates, issuers, **clusterissuers** | C/U/D/P | only project that needs ClusterIssuer is `mip-common` |
| `monitoring.coreos.com` | servicemonitors, prometheusrules | C/U/D/P | From upstream |
| `apiextensions.k8s.io` | customresourcedefinitions | C/U/D/P | only ECK chart needs CRDs at install; `mip-common` and `mip-monitoring` whitelist them |
| `admissionregistration.k8s.io` | mutating/validatingadmissionwebhooks | **none** | intentionally **not granted** — every AppProject blacklists Webhooks; if a future chart needs them, restore here AND whitelist in the AppProject in the same PR |
| `submariner.io`, `operator.openshift.io`, `config.openshift.io`, `projectcalico.org`, `network.openshift.io` | submariners/gateways/clusters/dnses/networks/ippools/etc. | mixed | submariner-only |
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
| **mip-argo-project-federation-`<name>`** *(per-fed, templated)* | `federation-<name>`, `argocd-mip-team` | `Namespace` | full workload set + Ingress + Gateway API routes | ✅ scoped to that NS |
| **mip-argo-project-security** | `federation-*`, `mip-common-*` | `Namespace` | `NetworkPolicy`, `Application` | ❌ blacklisted |
| **mip-argo-project-submariner** *(opted-out of lint)* | `submariner-k8s-broker`, `submariner-operator` | `CRD`, submariner.io CRs | full workload set | ✅ legitimately required |

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

⚠ **No automated check** that these out-of-band files stay in sync with the Helm charts they were extracted from. Procedure for re-extracting after upstream chart bump is undocumented.

External charts that *do* render their own RBAC (datacatalog, exareme2, mip platform) currently ship none — verified empirically. If that changes, the corresponding AppProject's RBAC blacklist will fail the sync loudly, which is the desired behavior.

---

## Quick "where could this go wrong" checklist

| Concern | Layer | Status |
|---|---|---|
| App project tries to manage Roles in a fed namespace | 2 | ✅ blocked, lint enforces |
| Someone hand-applies a ClusterRole using the controller SA | 1 | ✅ SA can't create ClusterRoles or Webhooks; CRDs intentional for the 3 projects that whitelist them |
| External Helm chart upgrade introduces RBAC | 2 | ✅ sync fails loudly |
| Out-of-band install RBAC drifts from upstream chart | 4 | ⚠ no check |
| UI user reads cluster-wide secrets | 1 + 3 | ✅ server cluster-wide secret read removed; only namespaced reads remain |
| New AppProject forgets RBAC blacklist | 2 | ✅ pre-commit blocks |
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
