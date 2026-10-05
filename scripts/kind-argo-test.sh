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
#   - the notebook RBAC reconciler (base/mip-infrastructure/notebook-operator)
#     binds only in labelled federation-* namespaces, copies the notebook API
#     proxy CA there, and its admission policies refuse anything else
#
# Usage:
#   bash scripts/kind-argo-test.sh           # spin up, test, tear down
#   KEEP=1 bash scripts/kind-argo-test.sh    # leave the cluster running
#   CLUSTER=foo bash scripts/kind-argo-test.sh  # custom kind cluster name
#
# Requires: kind, kubectl, kustomize, docker.
set -euo pipefail

CLUSTER=${CLUSTER:-mip-argo-test}
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEEP=${KEEP:-0}

# Shared cluster/Argo bring-up helpers (need/step/fail, ensure_kind_cluster,
# install_argo_overlay, ...). Also sets NS + GATEWAY_API_VERSION.
# shellcheck source=e2e/lib.sh
source "$REPO_ROOT/scripts/e2e/lib.sh"

need kind; need kubectl; need kustomize; need docker

trap teardown_cluster EXIT

step "Create kind cluster '$CLUSTER'"
ensure_kind_cluster

step "Install Gateway API CRDs (forward-compat SAR)"
install_gateway_api_crds

step "Apply Argo CD overlay"
install_argo_overlay

step "Wait for HA workloads to be Ready"
wait_argo_rollouts

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
apply_static_appprojects

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
ALLOWLISTED_PROBE=allowlisted-probe
kubectl create namespace "$NETPOL_TEST_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NETPOL_TEST_NS" run probe \
  --image="$PROBE_IMAGE" \
  --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$NETPOL_TEST_NS" wait pod/probe --for=condition=Ready --timeout=120s
kubectl -n "$NS" run "$ALLOWLISTED_PROBE" \
  --labels='app.kubernetes.io/name=argocd-server' \
  --image="$PROBE_IMAGE" \
  --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$NS" wait pod/"$ALLOWLISTED_PROBE" --for=condition=Ready --timeout=120s

# Negative: probe pod in another namespace, no matching labels — TCP connect
# to repo-server:8081 must fail.
if kubectl -n "$NETPOL_TEST_NS" exec probe -- \
     nc -z -w 5 "argocd-repo-server.${NS}.svc.cluster.local" 8081 \
     >/dev/null 2>&1; then
  fail "NetworkPolicy did not block cross-namespace ingress to argocd-repo-server:8081"
fi
echo "OK: argocd-repo-server:8081 is blocked from unauthorized pod"

# Positive: a pod carrying the argocd-server label matches the repo-server
# allowlist, so a plain TCP connect to 8081 must succeed.
if ! kubectl -n "$NS" exec "$ALLOWLISTED_PROBE" -- \
       nc -z -w 5 "argocd-repo-server.${NS}.svc.cluster.local" 8081 \
       >/dev/null 2>&1; then
  fail "Allowlisted pod cannot reach argocd-repo-server:8081 (netpol too tight?)"
fi
echo "OK: allowlisted pod can reach argocd-repo-server:8081"

kubectl -n "$NS" delete pod "$ALLOWLISTED_PROBE" --wait=false >/dev/null 2>&1 || true
kubectl delete namespace "$NETPOL_TEST_NS" --wait=false >/dev/null 2>&1 || true

step "Notebook RBAC reconciler: bindings follow labelled federation namespaces"
# base/mip-infrastructure/notebook-operator/rbac.yaml is applied out-of-band in
# production. The reconciler (common/notebook-operator/manifests/reconcile.sh)
# runs here as its ServiceAccount through impersonation, so RBAC and the
# admission policies are exercised exactly as from the CronJob. The notebook
# CRDs come from the pinned mip-jupyter commit (docs/getting-started.md), so
# the SubjectAccessReviews on notebooks below resolve the resource.
NB_RBAC="$REPO_ROOT/base/mip-infrastructure/notebook-operator/rbac.yaml"
NB_SCRIPT="$REPO_ROOT/common/notebook-operator/manifests/reconcile.sh"
NB_CRD_BASE=https://raw.githubusercontent.com/madgik/mip-jupyter/22c2dc4/operator/config/crd/bases
NB_MANAGER=system:serviceaccount:mip-notebooks-system:mip-notebook-rbac-manager
NB_ARGO="system:serviceaccount:$NS:argocd-application-controller"
NB_FED=federation-smoke             # labelled: bindings expected
NB_UNLABELLED=federation-unlabelled # right name, no label: nothing expected
NB_OTHER=notafed                    # label but wrong name: nothing expected
NB_HUB="system:serviceaccount:$NB_FED:jupyterhub"
kubectl apply -f "$NB_CRD_BASE/notebooks.mip.ebrains.eu_notebooks.yaml" >/dev/null
kubectl apply -f "$NB_CRD_BASE/notebooks.mip.ebrains.eu_notebookprofiles.yaml" >/dev/null
kubectl apply --server-side --force-conflicts -f "$NB_RBAC" >/dev/null
for ns in "$NB_FED" "$NB_UNLABELLED" "$NB_OTHER"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
kubectl label namespace "$NB_FED" "$NB_OTHER" mip.namespace-type=federation --overwrite >/dev/null
# A binding as the admin-applied file used to create it (client-side apply, no
# label): the reconciler must adopt it in place.
kubectl -n "$NB_FED" create rolebinding mip-notebook-operator \
  --clusterrole=mip-notebook-operator \
  --serviceaccount=mip-notebooks-system:mip-notebook-operator \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# The API server compiles the policies asynchronously; wait until it has seen
# them and reports no type-checking warnings.
for policy in mip-notebook-rbac-manager mip-notebook-rbac-manager-configmaps mip-jupyterhub-secrets; do
  kubectl wait --for=jsonpath='{.status.observedGeneration}'=1 \
    "validatingadmissionpolicy/$policy" --timeout=60s >/dev/null
  warnings=$(kubectl get validatingadmissionpolicy "$policy" \
               -o jsonpath='{.status.typeChecking.expressionWarnings}')
  [[ -z "$warnings" ]] || fail "policy $policy has type-checking warnings: $warnings"
done
sleep 3

KUBECTL="kubectl --as=$NB_MANAGER" sh "$NB_SCRIPT"
for rb in mip-notebook-operator mip-jupyterhub; do
  kubectl -n "$NB_FED" get rolebinding "$rb" >/dev/null 2>&1 \
    || fail "reconciler did not create RoleBinding $rb in $NB_FED"
done
managed_by=$(kubectl -n "$NB_FED" get rolebinding mip-notebook-operator \
               -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')
[[ "$managed_by" == "mip-notebook-rbac-manager" ]] \
  || fail "reconciler did not adopt the admin-created RoleBinding (managed-by='$managed_by')"
for ns in "$NB_UNLABELLED" "$NB_OTHER"; do
  if kubectl -n "$ns" get rolebinding mip-notebook-operator >/dev/null 2>&1; then
    fail "reconciler created a RoleBinding in $ns"
  fi
done
echo "OK: reconciler bound only $NB_FED and adopted the existing binding"
got=$(kubectl -n mip-notebooks-system get configmap mip-notebook-operator-watch \
        -o jsonpath='{.data.WATCH_NAMESPACES}')
[[ "$got" == "$NB_FED" ]] || fail "watch list is '$got', expected $NB_FED"
got=$(kubectl -n mip-notebooks-system get configmap mip-notebook-operator-watch \
        -o jsonpath='{.data.restarted_for}')
[[ "$got" == "$NB_FED" ]] || fail "restart marker is '$got', expected $NB_FED"
echo "OK: watch list = $NB_FED, operator restart recorded"

# The proxy CA. Without an issued certificate the reconciler warns and distributes nothing.
if kubectl -n "$NB_FED" get configmap notebook-api-proxy-ca >/dev/null 2>&1; then
  fail "CA ConfigMap distributed although no certificate is issued"
fi
# cert-manager is not installed here: its CRDs (the release the e2e harness installs) and the
# CertificateRequests cert-manager would leave behind: an old one that is not Ready and the
# current Ready one, with a test CA in its status. The reconciler must pick the Ready one.
NB_CM_VERSION=$(sed -n 's/^CERT_MANAGER_VERSION=//p' "$REPO_ROOT/scripts/e2e/run-e2e.sh")
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${NB_CM_VERSION}/cert-manager.crds.yaml" >/dev/null
NB_TEST_CA=$(printf -- '-----BEGIN CERTIFICATE-----\nnotebook-api-proxy smoke test\n-----END CERTIFICATE-----')
nb_request() { # $1 revision
  cat <<EOF
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: notebook-api-proxy-$1
  labels: {cert-manager.io/certificate-name: notebook-api-proxy}
  annotations: {cert-manager.io/certificate-revision: "$1"}
spec:
  request: $(printf 'smoke' | base64)
  issuerRef: {name: notebook-api-proxy-ca, kind: Issuer}
EOF
}
{ nb_request 1; echo ---; nb_request 2; } | kubectl -n mip-notebooks-system apply -f - >/dev/null
kubectl -n mip-notebooks-system patch certificaterequest notebook-api-proxy-1 --subresource=status \
  --type=merge -p "{\"status\":{\"ca\":\"$(printf 'stale' | base64)\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\",\"reason\":\"Pending\",\"lastTransitionTime\":\"2026-01-01T00:00:00Z\"}]}}" >/dev/null
kubectl -n mip-notebooks-system patch certificaterequest notebook-api-proxy-2 --subresource=status \
  --type=merge -p "{\"status\":{\"ca\":\"$(printf '%s\n' "$NB_TEST_CA" | base64 | tr -d '\n')\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"Issued\",\"lastTransitionTime\":\"2026-01-01T00:00:00Z\"}]}}" >/dev/null
KUBECTL="kubectl --as=$NB_MANAGER" sh "$NB_SCRIPT"
got=$(kubectl -n "$NB_FED" get configmap notebook-api-proxy-ca -o jsonpath='{.data.ca\.crt}')
[[ "$got" == "$NB_TEST_CA"* ]] || fail "CA ConfigMap in $NB_FED holds '$got'"
for ns in "$NB_UNLABELLED" "$NB_OTHER"; do
  if kubectl -n "$ns" get configmap notebook-api-proxy-ca >/dev/null 2>&1; then
    fail "CA ConfigMap created in $ns"
  fi
done
echo "OK: proxy CA from the Ready request distributed to $NB_FED only"

nb_configmap() { # $1 namespace, $2 name, $3 key, $4 with the managed-by label (yes/no)
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $2
  namespace: $1
EOF
  [[ "$4" == no ]] || echo '  labels: {app.kubernetes.io/managed-by: mip-notebook-rbac-manager}'
  echo "data: {$3: x}"
}
nb_configmap "$NB_OTHER" notebook-api-proxy-ca ca.crt yes \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager-configmaps "CA ConfigMap in a namespace not named federation-*" create
nb_configmap "$NB_FED" other-name ca.crt yes \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager-configmaps "ConfigMap with another name" create
nb_configmap "$NB_FED" notebook-api-proxy-ca other-key yes \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager-configmaps "CA ConfigMap with another key" create
nb_configmap "$NB_FED" notebook-api-proxy-ca ca.crt yes \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager-configmaps "CA ConfigMap whose ca.crt is not a PEM certificate" create
kubectl -n "$NB_UNLABELLED" create configmap notebook-api-proxy-ca --from-literal=ca.crt=x >/dev/null
nb_configmap "$NB_UNLABELLED" notebook-api-proxy-ca ca.crt no \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager-configmaps "delete of a CA ConfigMap it does not manage" delete

# The admission policies. Every request below is allowed by RBAC alone and must
# be refused by the named policy (server-side dry run as the account).
nb_binding() { # $1 namespace, $2 name, $3 ClusterRole, $4 subject name, $5 subject namespace
  cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $2
  namespace: $1
  labels: {app.kubernetes.io/managed-by: mip-notebook-rbac-manager}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: $3}
subjects: [{kind: ServiceAccount, name: $4, namespace: $5}]
EOF
}
nb_denied() { # $1 account, $2 policy, $3 description; kubectl verb arguments follow; manifest on stdin
  local who=$1 policy=$2 what=$3 out; shift 3
  if out=$(kubectl --as="$who" "$@" --dry-run=server -f - 2>&1); then
    fail "admission allowed: $what"
  fi
  grep -q "$policy" <<<"$out" || fail "refused by something other than $policy ($what): $out"
  echo "OK: denied: $what"
}
nb_binding "$NB_OTHER" mip-notebook-operator mip-notebook-operator mip-notebook-operator mip-notebooks-system \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "binding in a namespace not named federation-*" create
nb_binding "$NB_UNLABELLED" mip-notebook-operator mip-notebook-operator mip-notebook-operator mip-notebooks-system \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "binding in a federation-* namespace without the label" create
nb_binding "$NB_FED" mip-notebook-operator mip-notebook-operator jupyterhub "$NB_FED" \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "operator binding with the hub as subject" create
nb_binding "$NB_FED" mip-jupyterhub mip-jupyterhub jupyterhub mip-notebooks-system \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "hub binding with a subject from another namespace" create
nb_binding "$NB_FED" other-name mip-jupyterhub jupyterhub "$NB_FED" \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "binding named differently from its ClusterRole" create
nb_binding "$NB_FED" admin admin mip-notebook-operator mip-notebooks-system \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "binding to a ClusterRole outside the allow-list" create
nb_binding "$NB_FED" mip-jupyterhub mip-jupyterhub jupyterhub "$NB_FED" \
  | sed '/managed-by/d' \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "binding without the managed-by label" create
# A binding with a managed name that the reconciler did not create may not be deleted by it.
kubectl -n "$NB_UNLABELLED" create rolebinding mip-jupyterhub --clusterrole=mip-jupyterhub \
  --serviceaccount="$NB_UNLABELLED:jupyterhub" >/dev/null
nb_binding "$NB_UNLABELLED" mip-jupyterhub mip-jupyterhub jupyterhub "$NB_UNLABELLED" \
  | nb_denied "$NB_MANAGER" mip-notebook-rbac-manager "delete of a binding it does not manage" delete
# Control: the policy matches only the reconciler account.
nb_binding "$NB_UNLABELLED" mip-notebook-operator mip-notebook-operator mip-notebook-operator mip-notebooks-system \
  | kubectl create --dry-run=server -f - >/dev/null || fail "the policy matched a cluster administrator"
echo "OK: the policy constrains only the reconciler account"

# The hub may create its token Secrets and nothing else.
nb_secret() { # $1 name, $2 type ('' for none), $3 with ownerReference (yes/no)
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $1
  namespace: $NB_FED
EOF
  if [[ "$3" == yes ]]; then
    cat <<EOF
  ownerReferences:
    - {apiVersion: notebooks.mip.ebrains.eu/v1alpha1, kind: Notebook, name: ${1%-token}, uid: 00000000-0000-4000-8000-000000000000}
EOF
  fi
  [[ -z "$2" ]] || echo "type: $2"
  echo 'stringData: {token: x}'
}
nb_secret jupyter-smoke-token '' yes | kubectl --as="$NB_HUB" create --dry-run=server -f - >/dev/null \
  || fail "jupyterhub cannot create its token Secret"
echo "OK: jupyterhub can create jupyter-smoke-token"
nb_secret keycloak-credentials '' yes \
  | nb_denied "$NB_HUB" mip-jupyterhub-secrets "hub Secret with another name" create
nb_secret jupyter-smoke-token kubernetes.io/service-account-token yes \
  | nb_denied "$NB_HUB" mip-jupyterhub-secrets "hub Secret of ServiceAccount token type" create
nb_secret jupyter-smoke-token '' no \
  | nb_denied "$NB_HUB" mip-jupyterhub-secrets "hub Secret without its Notebook owner" create

# Who can do what in the federation afterwards.
[[ "$(kubectl auth can-i create rolebindings -n "$NB_FED" --as="$NB_ARGO")" == "no" ]] \
  || fail "argocd-application-controller can create RoleBindings"
[[ "$(kubectl auth can-i bind clusterroles/mip-notebook-operator -n "$NB_FED" --as="$NB_ARGO")" == "no" ]] \
  || fail "argocd-application-controller can bind the notebook ClusterRole"
echo "OK: argocd-application-controller holds no RBAC write"
[[ "$(kubectl auth can-i create rolebindings -n kube-system --as="$NB_MANAGER")" == "yes" ]] \
  || fail "RBAC of the reconciler changed: the admission policy, not RBAC, is meant to scope it"
[[ "$(kubectl auth can-i create pods -n "$NB_FED" --as="$NB_HUB")" == "no" ]] \
  || fail "jupyterhub can create pods in $NB_FED"
[[ "$(kubectl auth can-i create notebooks.notebooks.mip.ebrains.eu -n "$NB_FED" --as="$NB_HUB")" == "yes" ]] \
  || fail "jupyterhub cannot create Notebooks in $NB_FED"
echo "OK: jupyterhub can create Notebooks but not pods"
[[ "$(kubectl auth can-i create pods -n "$NB_FED" \
        --as=system:serviceaccount:mip-notebooks-system:mip-notebook-operator)" == "yes" ]] \
  || fail "notebook operator cannot create pods in $NB_FED"
[[ "$(kubectl auth can-i create pods -n "$NB_UNLABELLED" \
        --as=system:serviceaccount:mip-notebooks-system:mip-notebook-operator)" == "no" ]] \
  || fail "notebook operator can create pods in $NB_UNLABELLED"
echo "OK: notebook operator creates pods only where bound"

# Prune: the namespace stops being a federation.
kubectl label namespace "$NB_FED" mip.namespace-type- >/dev/null
KUBECTL="kubectl --as=$NB_MANAGER" sh "$NB_SCRIPT"
if kubectl -n "$NB_FED" get rolebinding mip-notebook-operator >/dev/null 2>&1; then
  fail "reconciler did not prune its RoleBindings from $NB_FED"
fi
if kubectl -n "$NB_FED" get configmap notebook-api-proxy-ca >/dev/null 2>&1; then
  fail "reconciler did not prune its CA ConfigMap from $NB_FED"
fi
got=$(kubectl -n mip-notebooks-system get configmap mip-notebook-operator-watch \
        -o jsonpath='{.data.WATCH_NAMESPACES}')
[[ -z "$got" ]] || fail "watch list is '$got' after the last federation left"
echo "OK: reconciler pruned $NB_FED (bindings and CA ConfigMap) and emptied the watch list"
for ns in "$NB_FED" "$NB_UNLABELLED" "$NB_OTHER"; do
  kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
done

step "All checks passed"
