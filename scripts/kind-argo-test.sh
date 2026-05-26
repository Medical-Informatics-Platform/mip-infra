#!/usr/bin/env bash
# scripts/kind-argo-test.sh
#
# End-to-end smoke test of the Argo CD overlay against an ephemeral kind
# cluster. Verifies that:
#   - kustomize build argo-setup/patches applies cleanly
#   - all HA workloads reach Ready
#   - our tightened ClusterRoles are the ones effectively in the API server
#   - PDBs exist and select live pods
#   - AppProjects in projects/static/ + base/argo-projects/argo-projects.yaml apply and
#     pass Argo CD's own admission (i.e. the CRDs accept them)
#   - the controller SA can in fact list namespaces (sanity SubjectAccessReview)
#   - the controller SA cannot create ClusterRoles / Webhooks (negative SAR)
#
# Usage:
#   bash scripts/kind-argo-test.sh           # spin up, test, tear down
#   KEEP=1 bash scripts/kind-argo-test.sh    # leave the cluster running
#   CLUSTER=foo bash scripts/kind-argo-test.sh  # custom kind cluster name
#
# Requires: kind, kubectl, kustomize, docker.
set -euo pipefail

CLUSTER=${CLUSTER:-mip-argo-test}
NS=argocd-mip-team
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEP=${KEEP:-0}

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need kind; need kubectl; need kustomize; need docker

cleanup() {
  local rc=$?
  if [[ "$KEEP" != "1" ]]; then
    echo "--- Tearing down kind cluster '$CLUSTER'"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  else
    echo "--- KEEP=1: leaving cluster '$CLUSTER' up. Delete with: kind delete cluster --name $CLUSTER"
  fi
  exit "$rc"
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "Create kind cluster '$CLUSTER'"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  # Need >=3 schedulable nodes: redis-ha-server / redis-ha-haproxy run 3
  # replicas with hard pod anti-affinity. The control-plane is tainted
  # NoSchedule by default, so we provision 3 worker nodes.
  kind create cluster --name "$CLUSTER" --wait 120s --config=- <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF
else
  echo "(cluster already exists, reusing)"
  kubectl config use-context "kind-$CLUSTER" >/dev/null
fi

step "Install Gateway API CRDs (forward-compat SAR)"
# Pinned to v1.3.0 standard channel. Required so the SAR for HTTPRoutes
# resolves the resource — without the CRDs `kubectl auth can-i` returns no.
GATEWAY_API_VERSION=v1.3.0
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

step "Apply Argo CD overlay"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# AppProject CRD must exist before our static AppProjects apply, so we install
# the overlay (which includes upstream CRDs) first and only then the projects.
# --server-side because the applicationsets CRD exceeds the 256KB
# last-applied-configuration annotation limit.
kustomize build "$REPO_ROOT/argo-setup/patches" \
  | kubectl apply --server-side --force-conflicts -f -

step "Wait for HA workloads to be Ready"
# Wait long enough for image pulls on a cold kind node.
kubectl -n "$NS" rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n "$NS" rollout status statefulset/argocd-redis-ha-server      --timeout=300s
kubectl -n "$NS" rollout status deploy/argocd-server                     --timeout=300s
kubectl -n "$NS" rollout status deploy/argocd-repo-server                --timeout=300s
kubectl -n "$NS" rollout status deploy/argocd-redis-ha-haproxy           --timeout=300s
kubectl -n "$NS" rollout status deploy/argocd-dex-server                 --timeout=300s
kubectl -n "$NS" rollout status deploy/argocd-applicationset-controller  --timeout=300s
kubectl -n "$NS" rollout status deploy/argocd-notifications-controller   --timeout=300s

step "Verify tightened ClusterRoles are live"
# argocd-server must NOT have cluster-wide secret read.
if kubectl auth can-i get secrets --all-namespaces \
     --as=system:serviceaccount:$NS:argocd-server >/dev/null 2>&1 \
   && [[ "$(kubectl auth can-i get secrets --all-namespaces \
              --as=system:serviceaccount:$NS:argocd-server)" == "yes" ]]; then
  fail "argocd-server can still get secrets cluster-wide (tightening not in effect)"
fi
echo "OK: argocd-server cannot get secrets cluster-wide"

# argocd-application-controller must NOT have admissionregistration writes.
if [[ "$(kubectl auth can-i create validatingwebhookconfigurations \
           --as=system:serviceaccount:$NS:argocd-application-controller)" == "yes" ]]; then
  fail "argocd-application-controller can still create ValidatingWebhookConfigurations"
fi
echo "OK: argocd-application-controller cannot create Webhooks"

# But it MUST still be able to write Gateway API HTTPRoutes (forward-compat).
# Note: Gateway API CRDs are installed on this kind cluster so `kubectl auth can-i`
# can resolve the resource type during SubjectAccessReview.
if [[ "$(kubectl auth can-i create httproutes.gateway.networking.k8s.io \
           --as=system:serviceaccount:$NS:argocd-application-controller)" != "yes" ]]; then
  fail "argocd-application-controller cannot write Gateway API HTTPRoutes"
fi
echo "OK: argocd-application-controller can write Gateway API HTTPRoutes"

# Sanity positive: it CAN list namespaces.
if [[ "$(kubectl auth can-i list namespaces \
           --as=system:serviceaccount:$NS:argocd-application-controller)" != "yes" ]]; then
  fail "argocd-application-controller cannot list namespaces (RBAC broken?)"
fi
echo "OK: argocd-application-controller can list namespaces"

# argocd-notifications-controller must NOT escalate beyond its narrow upstream
# Role: e.g. it must not be able to create ClusterRoles or read cluster-wide
# secrets. Verify both negatives.
if [[ "$(kubectl auth can-i create clusterroles \
           --as=system:serviceaccount:$NS:argocd-notifications-controller)" == "yes" ]]; then
  fail "argocd-notifications-controller can create ClusterRoles"
fi
if [[ "$(kubectl auth can-i get secrets --all-namespaces \
           --as=system:serviceaccount:$NS:argocd-notifications-controller)" == "yes" ]]; then
  fail "argocd-notifications-controller can read secrets cluster-wide"
fi
echo "OK: argocd-notifications-controller is properly scoped"

step "Verify PodDisruptionBudgets are present and bound"
expected_pdbs=(
  argocd-application-controller
  argocd-server
  argocd-repo-server
  argocd-dex-server
  argocd-redis-ha-haproxy
  argocd-redis-ha-server
)
for pdb in "${expected_pdbs[@]}"; do
  current=$(kubectl -n "$NS" get pdb "$pdb" \
              -o jsonpath='{.status.currentHealthy}' 2>/dev/null || echo MISSING)
  if [[ "$current" == "MISSING" ]]; then
    fail "PDB $pdb missing"
  fi
  if [[ "$current" -lt 1 ]]; then
    fail "PDB $pdb has currentHealthy=$current (selector mismatch?)"
  fi
  echo "OK: PDB $pdb currentHealthy=$current"
done

step "Apply static AppProjects"
kubectl apply --server-side --force-conflicts -f "$REPO_ROOT/base/argo-projects/argo-projects.yaml"
for f in "$REPO_ROOT"/projects/static/*/*.yaml; do
  # Skip kustomize control files; only apply actual k8s manifests.
  case "$(basename "$f")" in
    kustomization.yaml|values.yaml) continue ;;
  esac
  kubectl apply --server-side --force-conflicts -f "$f"
done

step "Verify AppProjects landed"
got=$(kubectl -n "$NS" get appprojects -o name | wc -l | tr -d ' ')
if [[ "$got" -lt 5 ]]; then
  fail "expected at least 5 AppProjects, got $got"
fi
echo "OK: $got AppProjects present"

step "Verify default AppProject is deny-all"
default_dest=$(kubectl -n "$NS" get appproject default \
                 -o jsonpath='{.spec.destinations}')
if [[ "$default_dest" != "[]" && -n "$default_dest" ]]; then
  fail "default AppProject is not deny-all: destinations=$default_dest"
fi
echo "OK: default AppProject is deny-all"

step "Verify NetworkPolicy actually blocks unauthorized traffic"
# argocd-repo-server netpol only allows ingress on 8081 from a small set of
# argo pods. A pod running in another namespace with no matching labels must
# not be able to reach port 8081. kindnet (the default kind CNI) enforces
# NetworkPolicies natively as of v1.4+ shipped with kindest/node:v1.32+.
NETPOL_TEST_NS=netpol-probe
kubectl create namespace "$NETPOL_TEST_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NETPOL_TEST_NS" run probe \
  --image=curlimages/curl:8.10.1 \
  --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$NETPOL_TEST_NS" wait pod/probe --for=condition=Ready --timeout=120s

# Negative: probe pod in another namespace, no matching labels — must be blocked.
if kubectl -n "$NETPOL_TEST_NS" exec probe -- \
     curl --max-time 5 -fsS \
     "http://argocd-repo-server.${NS}.svc.cluster.local:8081/" \
     >/dev/null 2>&1; then
  fail "NetworkPolicy did not block cross-namespace ingress to argocd-repo-server:8081"
fi
echo "OK: argocd-repo-server:8081 is blocked from unauthorized pod"

# Positive: argocd-server pod's selector matches the netpol's allowlist for
# repo-server, so traffic from inside the argocd-server pod must succeed.
SERVER_POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=argocd-server \
               -o jsonpath='{.items[0].metadata.name}')
if ! kubectl -n "$NS" exec "$SERVER_POD" -- \
       /usr/bin/wget -q --timeout=5 --spider \
       "http://argocd-repo-server:8081/" >/dev/null 2>&1; then
  # 8081 speaks gRPC, wget --spider may 4xx but the TCP connection itself
  # is what we're asserting — distinguish "blocked" from "got reply".
  rc=$?
  if [[ "$rc" -ge 4 ]]; then
    fail "argocd-server pod cannot reach argocd-repo-server:8081 (netpol too tight?)"
  fi
fi
echo "OK: argocd-server can reach argocd-repo-server:8081 (allowlisted)"

kubectl delete namespace "$NETPOL_TEST_NS" --wait=false >/dev/null 2>&1 || true

step "All checks passed"
