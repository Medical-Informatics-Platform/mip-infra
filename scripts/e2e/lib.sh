#!/usr/bin/env bash
# scripts/e2e/lib.sh
#
# Shared helpers for the kind-based smoke and e2e tests. Sourced by
# scripts/kind-argo-test.sh and scripts/e2e/run-e2e.sh — not executable on
# its own.
#
# Callers must set (before or after sourcing):
#   CLUSTER    kind cluster name
#   REPO_ROOT  absolute path to the repo checkout
# and are responsible for their own `set -euo pipefail` and EXIT trap
# (see teardown_cluster below).

NS=argocd-mip-team
GATEWAY_API_VERSION=v1.3.0

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
step() { printf '\n=== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

create_ha_kind_cluster() {
  kind create cluster --name "$CLUSTER" --wait 120s --config=- <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF
}

# Create the cluster, or reuse an existing one if it already has the
# 1 control-plane + 3 worker topology the HA overlay needs (redis-ha-server /
# redis-ha-haproxy run 3 replicas with hard pod anti-affinity; the
# control-plane is tainted NoSchedule by default).
ensure_kind_cluster() {
  if ! kind get clusters | grep -qx "$CLUSTER"; then
    create_ha_kind_cluster
  else
    echo "(cluster already exists, inspecting topology)"
    kubectl config use-context "kind-$CLUSTER" >/dev/null

    local existing_nodes
    existing_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$existing_nodes" -lt 4 ]]; then
      echo "(cluster has ${existing_nodes} node(s); recreating with 1 control-plane + 3 workers)"
      kind delete cluster --name "$CLUSTER"
      create_ha_kind_cluster
    else
      echo "(cluster already exists with ${existing_nodes} node(s), reusing)"
    fi
  fi
}

# EXIT-trap body shared by the entrypoints. Honors KEEP=1.
# Exits with $1 when given (for traps that do work before calling this,
# which would clobber $?), else with the status at entry.
teardown_cluster() {
  local rc=${1:-$?}
  if [[ "${KEEP:-0}" != "1" ]]; then
    echo "--- Tearing down kind cluster '$CLUSTER'"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  else
    echo "--- KEEP=1: leaving cluster '$CLUSTER' up. Delete with: kind delete cluster --name $CLUSTER"
  fi
  exit "$rc"
}

install_gateway_api_crds() {
  # Pinned standard channel. Required so SubjectAccessReviews for HTTPRoutes
  # resolve the resource — without the CRDs `kubectl auth can-i` returns no.
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
}

install_argo_overlay() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  # AppProject CRD must exist before our static AppProjects apply, so we
  # install the overlay (which includes upstream CRDs) first and only then the
  # projects. --server-side because the applicationsets CRD exceeds the 256KB
  # last-applied-configuration annotation limit.
  kustomize build "$REPO_ROOT/argo-setup/patches" \
    | kubectl apply --server-side --force-conflicts -f -
}

wait_argo_rollouts() {
  # Wait long enough for image pulls on a cold kind node.
  kubectl -n "$NS" rollout status statefulset/argocd-application-controller --timeout=300s
  kubectl -n "$NS" rollout status statefulset/argocd-redis-ha-server      --timeout=300s
  kubectl -n "$NS" rollout status deploy/argocd-server                     --timeout=300s
  kubectl -n "$NS" rollout status deploy/argocd-repo-server                --timeout=300s
  kubectl -n "$NS" rollout status deploy/argocd-redis-ha-haproxy           --timeout=300s
  kubectl -n "$NS" rollout status deploy/argocd-dex-server                 --timeout=300s
  kubectl -n "$NS" rollout status deploy/argocd-applicationset-controller  --timeout=300s
  kubectl -n "$NS" rollout status deploy/argocd-notifications-controller   --timeout=300s
}

apply_static_appprojects() {
  kubectl apply --server-side --force-conflicts -f "$REPO_ROOT/base/argo-projects/argo-projects.yaml"
  local f
  for f in "$REPO_ROOT"/projects/static/*/*.yaml; do
    # Skip kustomize control files; only apply actual k8s manifests.
    case "$(basename "$f")" in
      kustomization.yaml|values.yaml) continue ;;
    esac
    kubectl apply --server-side --force-conflicts -f "$f"
  done
}
