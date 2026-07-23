#!/usr/bin/env bash
# scripts/e2e/dump-diagnostics.sh
#
# Best-effort failure diagnostics for the e2e workflow. Never fails itself.
# Usage: bash scripts/e2e/dump-diagnostics.sh [profile]
set +e

NS=argocd-mip-team
section() { printf '\n::group::%s\n' "$*"; }
endsection() { printf '::endgroup::\n'; }

section "Argo CD Applications (overview + full status)"
kubectl -n "$NS" get applications -o wide
kubectl -n "$NS" get applications -o yaml
endsection

for ns in federation-a elastic-system ingress-nginx mip-common-datacatalog \
          metallb-system cert-manager default; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || continue
  section "namespace $ns: pods / pvc / events"
  kubectl -n "$ns" get pods -o wide
  kubectl -n "$ns" get pvc
  kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -50
  endsection
  section "namespace $ns: describe pods"
  kubectl -n "$ns" describe pods
  endsection
  section "namespace $ns: pod logs (tail 100)"
  for p in $(kubectl -n "$ns" get pods -o name); do
    echo "--- $p"
    kubectl -n "$ns" logs "$p" --all-containers --prefix --tail=100
  done
  endsection
done

section "Argo CD repo-server logs (git fetch / render errors show up here)"
kubectl -n "$NS" logs deploy/argocd-repo-server --tail=200
endsection

section "Argo CD application-controller logs"
kubectl -n "$NS" logs statefulset/argocd-application-controller --tail=200
endsection

section "cluster state: nodes / storageclasses / disk"
kubectl get nodes -o wide
kubectl get storageclasses
df -h
endsection

exit 0
