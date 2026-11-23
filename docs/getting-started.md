# Getting started

Install the MIP infrastructure on an empty cluster. Follow the steps in order: the bootstrap is staged on purpose ([architecture.md](architecture.md#bootstrap-order)).

## Prerequisites

- A Kubernetes cluster with at least 3 schedulable worker nodes. Argo CD HA spreads its 3 Redis replicas with hard anti-affinity.
- `kubectl` 1.33 or later, configured for the cluster.
- `kustomize`, standalone or `kubectl kustomize`.
- The `argocd` CLI (recommended).
- Network access to the cluster API and to GitHub. Off the network, see [remote-access.md](remote-access.md).
- An SSH deploy key for the private `mip-deployments` repository, if you use it.

```bash
git clone https://github.com/Medical-Informatics-Platform/mip-infra.git
cd mip-infra
git checkout main   # or your feature branch
```

## 1. Install Argo CD

Follow [`argo-setup/README.md`, Bootstrap](../argo-setup/README.md#bootstrap): it rewrites the host name, creates the namespace, applies the HA overlay, waits for the rollout and rotates the admin password. From outside the cluster network, `argocd login` needs a tunnel and an `/etc/hosts` entry ([remote-access.md](remote-access.md)).

Continue when `kubectl -n argocd-mip-team rollout status deploy/argocd-server` succeeds and the admin password is rotated.

## 2. Register the repositories

This repository is public; Argo CD reads it over HTTPS. If the deployment values live in the private `mip-deployments` repository, register it too, with its deploy key.

```bash
argocd repo add https://github.com/Medical-Informatics-Platform/mip-infra.git \
  --name mip-infra

# Optional. Create a key and add its public part as a read-only deploy key of mip-deployments:
#   ssh-keygen -t ed25519 -f ./argocd-remote-key -C "argocd deploy key" -N ""
#   https://github.com/Medical-Informatics-Platform/mip-deployments/settings/keys
argocd repo add git@github.com:Medical-Informatics-Platform/mip-deployments.git \
  --ssh-private-key-path ./argocd-remote-key \
  --name mip-deployments
```

## 3. Apply the out-of-band RBAC

Argo CD may not create cluster-scoped RBAC or admission policies ([rbac-layers.md](rbac-layers.md)). Apply them once, by hand:

```bash
kubectl apply -f base/mip-infrastructure/rbac/haproxy-public-rbac.yaml
kubectl apply -f base/mip-infrastructure/rbac/submariner-rbac.yaml
kubectl apply -f base/mip-infrastructure/rbac/submariner-remote-admission.yaml
kubectl apply -f base/mip-infrastructure/rbac/eck-beats-rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/Medical-Informatics-Platform/mip-jupyter/refs/tags/0.1.1/operator/config/crd/bases/notebooks.mip.ebrains.eu_notebooks.yaml
kubectl apply -f https://raw.githubusercontent.com/Medical-Informatics-Platform/mip-jupyter/refs/tags/0.1.1/operator/config/crd/bases/notebooks.mip.ebrains.eu_notebookprofiles.yaml
kubectl apply -f base/mip-infrastructure/notebook-operator/rbac.yaml
```

Notebooks:

- The notebook CRDs come from the `mip-jupyter` tag that matches the operator image tag; that repository rewrites history, so commits are not stable. Change the tag together with the image tag in `common/notebook-operator/manifests/deployment.yaml`.
- `rbac.yaml` holds the operator namespace and accounts, the two notebook ClusterRoles, and the admission policies that confine the reconciler and the hub. It names no federation.
- The reconciler CronJob (synced from `common/notebook-operator`) binds both ClusterRoles in every `federation-*` namespace labelled `mip.namespace-type=federation`, within five minutes. On a fresh cluster the operator pod waits in `CreateContainerConfigError` until that first run.
- The same Application deploys the notebook API proxy; the hubs use it only after the switch in [operations.md](operations.md#switch-the-hub-to-the-notebook-api-proxy).
- Upgrading from a `rbac.yaml` that listed federations: apply the file, wait for one reconciler run (`kubectl -n federation-<x> get rolebinding mip-notebook-operator mip-jupyterhub`), then delete the old objects in every federation: `kubectl -n federation-<x> delete role jupyterhub rolebinding jupyterhub`.

Submariner:

- `submariner-rbac.yaml` creates the namespaces `submariner-operator` and `submariner-k8s-broker` and binds the broker Role to the operator's broker account.
- `submariner-remote-admission.yaml` holds the Role and the admission policies of the remote nodes' broker accounts ([hybrid-federations.md](hybrid-federations.md)).
- Create the IPsec PSK before the first sync of `submariner-operator` ([common/submariner/README.md](../common/submariner/README.md), Install, step 2).

## 4. Bootstrap the AppProjects

Nothing else syncs until the project `mip-argo-project-infrastructure` exists:

```bash
kubectl apply -f projects/mip-infrastructure.yaml          # the bootstrap AppProject
kubectl apply -f base/argo-projects/argo-projects.yaml     # the ApplicationSet that creates every other AppProject
kubectl get appprojects -n argocd-mip-team                 # static projects and one per federation
kubectl get applicationsets -n argocd-mip-team
```

## 5. Deploy the infrastructure ApplicationSet

The ApplicationSet finds the federations (local and hybrid) and the common applications, and creates one Application for each:

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
SAFE_BRANCH_NAME=$(echo "$CURRENT_BRANCH" | sed 's/[^a-zA-Z0-9]/-/g')

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

## 6. Create the secrets

Create these Secrets before their Applications sync; otherwise the pods wait in `ContainerCreating`.

| Secret | Namespace | Content |
| --- | --- | --- |
| `keycloak-credentials` | `mip-common-datacatalog` and every `federation-<x>` | EBRAINS Keycloak tenant credentials |
| `mip-secret` | `federation-<x>` | Database users and passwords of the federation |
| `jupyterhub-crypt` | `federation-<x>` | JupyterHub `crypt-key` |
| `codex-llm` | `mip-athena` | Optional. Key `base-url`: the Jupyter AI (Codex) inference server URL ending in `/v1`, read only by `athena-proxy`. Without it Codex is off. |

`mip-secret`, one per federation, with values unique to the federation:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mip-secret
  namespace: federation-<x>
type: Opaque
stringData:
  platform-backend-db.DB_ADMIN_USER: <value>
  platform-backend-db.DB_ADMIN_PASSWORD: <value>
  platform-backend-db.PLATFORM_DB_USER: <value>
  platform-backend-db.PLATFORM_DB_PASSWORD: <value>
```

[`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) creates them for every `federation-*` namespace and for `mip-common-datacatalog`, and prints no secret. It asks for the Keycloak client credentials (and the optional Codex URL) and generates the other values (24 random characters). It skips existing Secrets; `--force` replaces them. It needs `kubectl` with the right context and the right to create Secrets:

```bash
./scripts/gen_secrets.sh
```

## 7. Check

```bash
kubectl get appprojects -n argocd-mip-team   # all projects present
argocd app list                              # every Application Synced and Healthy
```

An Application that waits for a Secret syncs once you create it (step 6). Other problems: [troubleshooting.md](troubleshooting.md).
