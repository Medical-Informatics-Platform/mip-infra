# RBAC and privilege map

Four layers limit what can change on the cluster. Each layer narrows the one above. **Gap** marks a known gap or a grant wider than needed.

| Layer | Controls | Source |
| --- | --- | --- |
| 1. ServiceAccount ClusterRoles | what Argo CD's accounts can do | `argo-setup/patches/patch-argocd-*-clusterrole.yaml` |
| 2. AppProject allow and deny lists | what an Application may sync | `projects/` |
| 3. Argo CD UI and API RBAC | who drives Argo CD | `roles:` of each AppProject, `argocd-rbac-cm` |
| 4. Workload RBAC, applied by hand | what each workload can do | `base/mip-infrastructure/rbac/`, `base/mip-infrastructure/notebook-operator/rbac.yaml` |

A sync can do only what layers 1 and 2 both allow. Defense in depth fails where layer 1 is wider than layer 2.

## Layer 1: ServiceAccount ClusterRoles

Sources: [`patch-argocd-application-controller-clusterrole.yaml`](../argo-setup/patches/patch-argocd-application-controller-clusterrole.yaml), [`patch-argocd-server-clusterrole.yaml`](../argo-setup/patches/patch-argocd-server-clusterrole.yaml).

### `argocd-application-controller` (writes every sync)

| API group | Resources | Verbs | Note |
| --- | --- | --- | --- |
| `*` | `*` | get, list, watch | diff and health |
| core | namespaces, configmaps, secrets, services, serviceaccounts, persistentvolumeclaims | create, update, delete, patch | |
| core | pods | delete | |
| `apps` | deployments, statefulsets, daemonsets, replicasets | create, update, delete, patch | |
| `batch` | jobs, cronjobs | create, update, delete, patch | |
| `rbac.authorization.k8s.io` | roles, rolebindings | none | namespaced RBAC from charts is not synced (layer 4) |
| `admissionregistration.k8s.io` | webhook configurations | none | every project denies webhooks. A chart that needs them gets the grant here and the allowance in its project, in the same pull request. |
| `apiextensions.k8s.io` | customresourcedefinitions | create, update, delete, patch | only the submariner project allows CRDs |
| `networking.k8s.io` | ingresses, ingressclasses, networkpolicies | all | |
| `cert-manager.io` | certificates, issuers, clusterissuers | create, update, delete, patch | ClusterIssuer only in `mip-common` |
| `monitoring.coreos.com` | servicemonitors, prometheusrules | create, update, delete, patch | |
| `notebooks.mip.ebrains.eu` | notebookprofiles | create, update, delete, patch | synced by `madgik/mip`; the hub's right on `notebooks` is layer 4 |
| `submariner.io`, `operator.openshift.io`, `config.openshift.io`, `network.openshift.io`; `projectcalico.org` ippools | Submariner resources | mixed | submariner project only |
| `projectcalico.org` | tiers; `tier.globalnetworkpolicies` named `remote-clusters.*` | create, update, delete, patch | security project only: the Calico tier of the remote networks. No write on policies of the default tier. |
| `multicluster.x-k8s.io` | serviceexports | create, update, delete, patch | hybrid federations export their aggregation server |
| ECK groups | elasticsearches, kibanas, beats, ... | all | monitoring project only |

### `argocd-server` (the UI)

| API group | Resources | Verbs |
| --- | --- | --- |
| core | events, namespaces, configmaps, services, persistentvolumeclaims | get, list, watch |
| core | pods, pods/log | get, list, watch, delete, patch |
| `argoproj.io` | applications, applicationsets, appprojects, workflows | get, list, watch, delete, patch |
| `apps` | deployments, replicasets, statefulsets, daemonsets | get, list, watch, delete |
| `batch` | jobs | get, list, watch, create, delete |
| `networking.k8s.io` | networkpolicies, ingresses, ingressclasses | get, list, watch, delete, patch |
| `cert-manager.io` | clusterissuers | get, list, watch |
| ECK groups | all | get, list, watch |

The server reads no Secrets.

All four Argo CD accounts are reviewed:

- `argocd-application-controller` and `argocd-server`: narrowed from the upstream `*/*/*`.
- `argocd-applicationset-controller`: its ClusterRole has no rules. The namespaced Role is enough, because `application.namespaces` is not set.
- `argocd-notifications-controller`: no ClusterRole. Its Role reads its own ConfigMap and Secret and writes Application status.

**Gap:** the controller may write CRDs, which only the submariner project needs. Layer 2 refuses CRDs in every other project; removing the grant would need a second account.

`scripts/check-upstream-argo-clusterroles.sh` compares the upstream ClusterRoles with the reviewed snapshot `argo-setup/upstream-snapshot/clusterroles.yaml`. CI runs it on pull requests that touch `argo-setup/`, and weekly. To update Argo CD, follow [argo-setup/README.md](../argo-setup/README.md#bumping-argo-cd).

## Layer 2: AppProject allow and deny lists

Sources: [`projects/static/`](../projects/static/) and the per-federation template [`projects/templates/federation/`](../projects/templates/federation/).

| Project | Destinations | Cluster-scoped kinds allowed | Namespaced kinds allowed | Role, RoleBinding |
| --- | --- | --- | --- | --- |
| `mip-argo-project-infrastructure` | `argocd-mip-team` | `Namespace`, Argo CD kinds | `Application`, `ApplicationSet`, `AppProject` | not allowed |
| `mip-argo-project-common` | `ingress-nginx`, `mip-common-datacatalog`, `mip-notebooks-system`, `mip-athena` | `Namespace`, `PersistentVolume`, `IngressClass`, `GatewayClass`, `ClusterIssuer` | workloads, Ingress, Gateway API routes, certificates | denied |
| `mip-argo-project-monitoring` | `elastic-system` | `Namespace` | workloads, Ingress, Gateway API routes, ECK resources | denied |
| `mip-argo-project-federations` (umbrella) | `argocd-mip-team` | none | `Application` | denied |
| `mip-argo-project-federation-<name>` (one per federation) | `federation-<name>`, `argocd-mip-team` | `Namespace` | workloads, Ingress, Gateway API routes, `NotebookProfile` | not allowed |
| `mip-argo-project-security` | `federation-*`, `mip-common-*`, `mip-athena`, `mip-notebooks-system`, `argocd-mip-team` | `Namespace`, Calico `Tier`, `GlobalNetworkPolicy` | `NetworkPolicy` | denied |
| `mip-argo-project-submariner` | `submariner-operator` | `CustomResourceDefinition`, Submariner resources | workloads, Submariner resources, Role, RoleBinding | allowed here, but layer 1 grants no RBAC write, so a sync fails |

- Every project except `mip-argo-project-submariner` denies `CustomResourceDefinition`.
- No project allows ClusterRoles, ClusterRoleBindings or webhook configurations.
- The pre-commit hook [`.githooks/pre-commit`](../.githooks/pre-commit) fails when a static AppProject does not deny `Role` and `RoleBinding`, unless the file starts with `# rbac-lint: ignore` (the submariner project does).
- Layer 2 applies at sync time. An account could still act outside it when called directly.

## Layer 3: Argo CD UI and API RBAC

Project roles are declared in each AppProject under `roles:`:

| Group | Role | Rights on applications |
| --- | --- | --- |
| `argocd-admins` | `<project>-admin` in every project | get, create, update, delete, sync |
| `argocd-operators` | `<project>-operator` in most projects | get, sync |
| `argocd-developers` | `federation-developer` in federation projects | get, sync |

The `default` AppProject denies everything ([`base/argo-projects/argo-projects.yaml`](../base/argo-projects/argo-projects.yaml)).

**Gap:** the global policy (`argocd-rbac-cm`: default role, scopes, OIDC group mapping) depends on how Argo CD was bootstrapped, and everyone shares the local `admin` account (see Open hardening items).

## Layer 4: Workload RBAC, applied by hand

Argo CD may not sync cluster-scoped RBAC (layer 2) or namespaced RBAC (layer 1). Workloads that need RBAC get it from files applied once at install time ([getting-started.md](getting-started.md), step 3):

| File | Accounts | Content |
| --- | --- | --- |
| `eck-beats-rbac.yaml` | `eck-filebeat`, `eck-metricbeat` in `elastic-system` | ClusterRole and ClusterRoleBinding |
| `haproxy-public-rbac.yaml` | `haproxy-public` in `ingress-nginx` | ClusterRole and ClusterRoleBinding; Role and RoleBinding for leader election |
| `submariner-rbac.yaml` | Submariner gateway, operator, route agent, Lighthouse; the gateway route watchdog | ClusterRoles and namespaced Roles in `submariner-k8s-broker` and `submariner-operator`. The watchdog's Role (`gateways: get`, `pods: deletecollection`) and the admission policy that lets it delete only the route agent pod on its own node. |
| `submariner-remote-admission.yaml` | the remote nodes' broker accounts `cluster-<id>` in `submariner-k8s-broker` | Role `submariner-remote-cluster` and four admission policies: ownership of broker objects, subnet pinning, export pinning, enrollment records written by people only |
| `../notebook-operator/rbac.yaml` | `mip-notebook-operator` and `mip-notebook-rbac-manager` in `mip-notebooks-system`; `jupyterhub` in each federation | See below |

Notebook RBAC:

- The ClusterRole `mip-notebook-operator` may create pods and PVCs, but no Secrets. The operator is the only component that creates notebook pods.
- The ClusterRole `mip-jupyterhub` covers `notebooks` and `secrets: create`. An admission policy limits the hub's Secret creation to its own `jupyter-*-token` Opaque Secrets owned by a Notebook.
- The reconciler CronJob `mip-notebook-rbac-manager` binds both ClusterRoles by RoleBinding, never cluster-wide. It binds them in every namespace named `federation-*` that carries `mip.namespace-type=federation`, removes its bindings elsewhere, and maintains the operator's `WATCH_NAMESPACES` ConfigMap.
- The reconciler also copies the CA of the notebook API proxy into each federation (ConfigMap `notebook-api-proxy-ca`), read from the cert-manager request status. It never reads a Secret and has no cluster-wide ConfigMap read.
- Admission policies confine the reconciler's account. It may write only those two bindings, under their own names, in `federation-*` namespaces, plus the CA ConfigMap with its single PEM key. A stolen token of it can bind nothing else; it can restart the operator pod.
- The Argo CD controller writes the namespace label (`managedNamespaceMetadata` of the `federation-network-policies` ApplicationSet). It can label only its projects' destination namespaces, where it already runs workloads.
- Check in every federation: `kubectl auth can-i create pods --as=system:serviceaccount:<ns>:jupyterhub -n <ns>` must answer `no`.

The admission policies use `failurePolicy: Fail`. A policy that stops compiling refuses every request it matches, for every caller, until it is fixed or its binding is deleted. The kind smoke test therefore checks `status.typeChecking` and exercises the policies before merge.

**Gap:** nothing checks that these files stay in line with the charts they were taken from, and re-extraction after a chart update is not documented.

Charts that ship their own `Role` and `RoleBinding` (the `madgik/mip` JupyterHub, the Submariner operator) need that RBAC in these files: their project may allow it, but layer 1 grants no RBAC write. Cluster-scoped RBAC from any chart fails the sync, as intended.

## Checklist

| Concern | Layer | Status |
| --- | --- | --- |
| A project tries to manage Roles in a federation namespace | 2 | blocked; the pre-commit lint enforces it |
| Someone uses the controller account to create a ClusterRole | 1 | the account cannot create ClusterRoles or webhooks; CRD write is the known gap |
| A chart update adds cluster-scoped RBAC | 2 | the sync fails |
| A chart update adds namespaced RBAC | 1 | the sync fails: no `roles`/`rolebindings` write |
| The files of layer 4 drift from the upstream charts | 4 | **gap**: no check |
| A UI user reads Secrets cluster-wide | 1, 3 | the server reads no Secrets |
| A new AppProject forgets to deny RBAC | 2 | the pre-commit hook blocks it |
| A new federation needs notebook RBAC | 4 | nothing to add: bindings follow the namespace label |
| The reconciler's account is stolen | 4 | admission policies limit it to the two notebook bindings and the CA ConfigMap in `federation-*` namespaces, plus its own state ConfigMap |
| The hub pod reaches the API server | 4 | **gap** while `apiServer.hubDirect: true` (pinned to the control-plane addresses). The notebook API proxy takes over once the chart points the hub at it ([operations.md](operations.md#switch-the-hub-to-the-notebook-api-proxy)). |
| Git runs a workload as the operator's account (`mip-argo-project-common` targets `mip-notebooks-system`) | 2 | accepted: the repository is the trust root, as for the other workload accounts |
| Misuse of the `default` AppProject | 2 | denies everything |

## Open hardening items

- **Single sign-on, and no local `admin`.** Today every operator shares the admin password and bypasses [`argocd-rbac-cm`](../argo-setup/patches/patch-argocd-rbac-cm.yaml). Configure Dex or OIDC in [`argocd-cm`](../argo-setup/patches/patch-argocd-cm.yaml), provide the client secret through the secrets workflow, set `admin.enabled: "false"`, and replace the placeholder groups (`argocd-admins`, `argocd-operators`) with real OIDC group claims.
- **Bootstrap of `argocd-secret`** (signing key, repository credentials, OIDC client secret): only [`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) exists, and nothing ties it to the install.
