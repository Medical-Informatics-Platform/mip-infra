# Getting Started

End-to-end install of the MIP infrastructure on an empty KaaS cluster. Follow the steps in order — the bootstrap is staged on purpose (see [architecture.md](architecture.md#bootstrap-order)).

## Prerequisites

- A Kubernetes cluster with **≥ 3 schedulable worker nodes** (Argo CD HA uses hard anti-affinity for its 3 redis replicas).
- `kubectl` ≥ v1.33 configured for that cluster.
- `kustomize` (standalone or `kubectl kustomize`).
- `argocd` CLI (recommended).
- Network access to the cluster API and to GitHub. If you are off-network, see [remote-access.md](remote-access.md).
- An SSH deploy key for the `mip-infra` repo (Argo CD will use it).

Prepare this repository:

```
# Clone the repository 
git clone https://github.com/Medical-Informatics-Platform/mip-infra.git
cd mip-infra

# Checkout the desired branch (main for production, or your feature branch)
git checkout main
```

## 1. Install Argo CD

The HA overlay lives in [`argo-setup/`](../argo-setup/). It pins a specific
Argo CD release and applies the repo-specific resource, ingress, and config
patches. See [argo-setup/README.md](../argo-setup/README.md) for the overlay
details and the full bootstrap flow.

```bash
ARGOCD_HOST=example.com #YOUR DOMAIN HERE
ARGOCD_NS=argocd-mip-team

cd argo-setup

# BSD-Style
LC_ALL=C find . -type f -not -path '*/.git/*' -exec sed -i '' "s/example.com/$ARGOCD_HOST/g" {} +
# GNU-Style
LC_ALL=C find . -type f -not -path '*/.git/*' -exec sed -i "s/example.com/$ARGOCD_HOST/g" {} +

kubectl create namespace "$ARGOCD_NS"

# Server-side apply is required: the `applicationsets.argoproj.io` CRD
# exceeds the 256 KiB limit for the client-side `last-applied-configuration`
# annotation and a plain `kubectl apply` fails with
#   metadata.annotations: Too long: may not be more than 262144 bytes
kustomize build patches \
  | kubectl apply -n "$ARGOCD_NS" --server-side -f -

kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server
```

Update the placeholder hostname in
[`argo-setup/patches/patch-argocd-ingress.yaml`](../argo-setup/patches/patch-argocd-ingress.yaml)
to your real DNS record before applying in production.

Quick sanity checks:

```bash
kubectl -n "$ARGOCD_NS" get pods
```

## 2. Rotate the bootstrap admin password

Use the Argo CD CLI. From off-cluster you'll need a tunnel + `/etc/hosts`
mapping first — see [remote-access.md](remote-access.md).

```bash
ARGOCD_NS=argocd-mip-team

# Read the bootstrap password
ARGO_TEMP_PW=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Initial 'admin' password: $ARGO_TEMP_PW"

# Log in (use the host you reach Argo CD on; add :8443 if you're using the
# SSH -L tunnel from remote-access.md)
argocd login <argocd-host> --grpc-web --username admin
argocd account update-password

# Optionally Drop the bootstrap secret
# kubectl -n "$ARGOCD_NS" delete secret argocd-initial-admin-secret --ignore-not-found
```

## 2b. Register repositories with Argo CD

Register this repository in Argo CD. If your deployment values live in the
private `mip-deployments` repository, register that too.

```bash
# Public repo used for infrastructure manifests
argocd repo add https://github.com/Medical-Informatics-Platform/mip-infra.git \
  --name mip-infra

# Optional private repo used for per-federation deployment values
# If you don't have a key yet, generate one and add the public key as a read-only deploy key.
# ssh-keygen -t ed25519 -f ./argocd-remote-key -C "argocd deploy key" -N ""
# less argocd-remote-key.pub
# https://github.com/Medical-Informatics-Platform/mip-deployments/settings/keys

argocd repo add git@github.com:Medical-Informatics-Platform/mip-deployments.git \
  --ssh-private-key-path ./argocd-remote-key \
  --name mip-deployments
```

## 3. Apply out-of-band RBAC

Some workloads (HAProxy ingress, Submariner, ECK beats) use cluster-scoped RBAC
that is applied once, outside Argo CD:

```bash
kubectl apply -f base/mip-infrastructure/rbac/haproxy-public-rbac.yaml
kubectl apply -f base/mip-infrastructure/rbac/submariner-rbac.yaml
kubectl apply -f base/mip-infrastructure/rbac/eck-beats-rbac.yaml
```

## 4. Bootstrap the AppProjects

Two-step bootstrap. The order matters: nothing else can sync until
`mip-argo-project-infrastructure` exists.

```bash
# Bootstrap AppProject
kubectl apply -f projects/mip-infrastructure.yaml

# ApplicationSet that creates every other AppProject
kubectl apply -f base/argo-projects.yaml

# Verify — should show all static projects + per-fed projects
kubectl get appprojects -n argocd-mip-team
kubectl get applicationsets -n argocd-mip-team
```

## 5. Deploy the infrastructure ApplicationSet

This discovers every federation under `deployments/local/federations/` and
creates a wrapper Application for each.

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

## 6. Provision required secrets

MIP workloads expect the secrets listed below to exist **before** their Applications sync. If they don't, the workload pods will hang in`ContainerCreating` until you create them.

| Secret                 | Namespace                | Purpose                                   |
| ---------------------- | ------------------------ | ----------------------------------------- |
| `keycloak-credentials` | `mip-common-datacatalog` | EBRAINS Keycloak tenant credentials       |
| `keycloak-credentials` | `federation-<X>`         | Same, repeated per federation namespace   |
| `mip-secret`           | `federation-<X>`         | Per-federation DB admin/user/password set |

The `mip-secret` schema (one per federation):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mip-secret
  namespace: federation-<X>
type: Opaque
data:
  gateway-db.DB_ADMIN_USER:        <unique-per-fed>
  gateway-db.DB_ADMIN_PASSWORD:    <unique-per-fed>
  portalbackend-db.DB_ADMIN_USER:  <unique-per-fed>
  portalbackend-db.DB_ADMIN_PASSWORD: <unique-per-fed>
  portalbackend-db.PORTAL_DB_USER: <unique-per-fed>
  portalbackend-db.PORTAL_DB_PASSWORD: <unique-per-fed>
  # Deprecated — kept for compatibility:
  keycloak-db.POSTGRES_USER:       <deprecated>
  keycloak-db.POSTGRES_PASSWORD:   <deprecated>
  keycloak.KEYCLOAK_USER:          <deprecated>
  keycloak.KEYCLOAK_PASSWORD:      <deprecated>
```

### Generate them safely

[`scripts/gen_secrets.sh`](../scripts/gen_secrets.sh) interactively creates all required secrets for every `federation-*` namespace plus `mip-common-datacatalog`. Values are autogenerated (24-char alphanumeric); nothing is logged.

```bash
# from the repository root
chmod +x scripts/gen_secrets.sh
./scripts/gen_secrets.sh
```

Requires `bash`, `kubectl`, RBAC to create secrets, and a `kubectl` context pointing at the right cluster.

## 7. Verify

```bash
kubectl get appprojects -n argocd-mip-team        # all projects present
argocd app list                                   # workload Apps appearing
argocd app list | grep -E "(mip-argo-project-|argo-project-)"
kubectl get appprojects -n argocd-mip-team -w     # watch dynamic projects appear
```

A healthy cluster shows every Application as `Synced` + `Healthy`.

## Known transient hiccups

- **Apps hang waiting for secrets** → re-check [step 6](#6-provision-required-secrets), then resync.

For other failure modes see [troubleshooting.md](troubleshooting.md).
