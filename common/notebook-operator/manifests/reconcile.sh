#!/bin/sh
# reconcile.sh: per-federation state of the notebook stack, kept by one account.
#
# Runs as mip-notebook-rbac-manager (CronJob in mip-notebooks-system). The account, its RBAC and
# the ValidatingAdmissionPolicies that confine it are applied out-of-band from
# base/mip-infrastructure/notebook-operator/rbac.yaml. Every run is idempotent: the same objects
# are applied server-side, and what this account manages is removed from namespaces that are no
# longer federations.
#
#   1. Federation namespaces: named federation-*, labelled mip.namespace-type=federation (the
#      label is set by the federation-network-policies ApplicationSet, common/security/netpol.yaml).
#   2. In each: RoleBinding mip-notebook-operator (ClusterRole mip-notebook-operator to the
#      operator account), RoleBinding mip-jupyterhub (ClusterRole mip-jupyterhub to the hub
#      account of that namespace), and ConfigMap notebook-api-proxy-ca (the CA the hub trusts
#      for the notebook API proxy, read from the CertificateRequest status, never from a
#      Secret). All labelled app.kubernetes.io/managed-by=mip-notebook-rbac-manager.
#   3. Prune: managed RoleBindings and CA ConfigMaps in any other namespace (the ConfigMaps by
#      a named get per namespace; the account holds no cluster-wide list on ConfigMaps).
#   4. Operator watch list: ConfigMap mip-notebook-operator-watch, key WATCH_NAMESPACES, read by
#      the operator Deployment at start. It lists exactly the namespaces where the operator
#      binding exists: a watched namespace without it is a 403 that blocks the operator's cache
#      sync. When the list changes the operator pod is deleted and the Deployment recreates it;
#      the key restarted_for records the list the operator was last restarted for, so a failed
#      delete is retried on the next run.
#
# KUBECTL may be overridden, e.g. KUBECTL="kubectl --as=system:serviceaccount:..." in tests.
set -eu

MANAGER=mip-notebook-rbac-manager
OPERATOR_NS=mip-notebooks-system
OPERATOR_SA=mip-notebook-operator
HUB_SA=jupyterhub
STATE_CM=mip-notebook-operator-watch
PROXY=notebook-api-proxy
CA_CM=notebook-api-proxy-ca
MANAGED="app.kubernetes.io/managed-by=${MANAGER}"
KUBECTL=${KUBECTL:-kubectl}

apply() {
  # shellcheck disable=SC2086  # KUBECTL may carry arguments
  $KUBECTL apply --server-side --field-manager="$MANAGER" --force-conflicts -f - >/dev/null
}

bindings() { # $1 namespace
  cat <<MANIFEST
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${OPERATOR_SA}
  namespace: $1
  labels:
    app.kubernetes.io/managed-by: ${MANAGER}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${OPERATOR_SA}
subjects:
  - kind: ServiceAccount
    name: ${OPERATOR_SA}
    namespace: ${OPERATOR_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mip-jupyterhub
  namespace: $1
  labels:
    app.kubernetes.io/managed-by: ${MANAGER}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: mip-jupyterhub
subjects:
  - kind: ServiceAccount
    name: ${HUB_SA}
    namespace: $1
MANIFEST
}

ca_configmap() { # $1 namespace, $2 CA certificate (PEM)
  cat <<MANIFEST
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CA_CM}
  namespace: $1
  labels:
    app.kubernetes.io/managed-by: ${MANAGER}
data:
  ca.crt: |
$(printf '%s\n' "$2" | sed 's/^/    /')
MANIFEST
}

state_cm() { # $1 watch list, $2 list the operator was last restarted for
  cat <<MANIFEST
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${STATE_CM}
  namespace: ${OPERATOR_NS}
  labels:
    app.kubernetes.io/managed-by: ${MANAGER}
data:
  WATCH_NAMESPACES: "$1"
  restarted_for: "$2"
MANIFEST
}

state() { # $1 key of the state ConfigMap
  # shellcheck disable=SC2086
  $KUBECTL -n "$OPERATOR_NS" get configmap "$STATE_CM" -o jsonpath="{.data.$1}" 2>/dev/null || true
}

# 1. Federation namespaces, one per line. Active only: nothing can be created in a terminating
#    namespace. A failing list ends the run here, before anything is pruned. Namespace names are
#    DNS labels; the pattern keeps anything else out of the manifests above.
# shellcheck disable=SC2086
labelled=$($KUBECTL get namespaces -l mip.namespace-type=federation \
  --field-selector status.phase=Active \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
federations=$(printf '%s\n' "$labelled" | grep -E '^federation-[a-z0-9-]+$' | sort || true)
skipped=$(printf '%s\n' "$labelled" | grep -vE '^(federation-[a-z0-9-]+)?$' | tr '\n' ' ' || true)
[ -z "$skipped" ] || echo "WARN: labelled but not named federation-*, ignored: ${skipped}" >&2

#    The CA the hubs must trust for the proxy: status.ca of the CertificateRequest that issued
#    the newest Ready revision of Certificate notebook-api-proxy (public material; no Secret is
#    read). Lines: revision, Ready status, CA (base64).
# shellcheck disable=SC2086
proxy_ca=$($KUBECTL -n "$OPERATOR_NS" get certificaterequests.cert-manager.io \
  -l "cert-manager.io/certificate-name=${PROXY}" \
  -o jsonpath='{range .items[*]}{.metadata.annotations.cert-manager\.io/certificate-revision} {.status.conditions[?(@.type=="Ready")].status} {.status.ca}{"\n"}{end}' 2>/dev/null \
  | awk '$2 == "True" && $3 != "" { print $1, $3 }' | sort -n | tail -1 | cut -d' ' -f2 | base64 -d 2>/dev/null || true)
case "$proxy_ca" in
  "-----BEGIN CERTIFICATE-----"*) ;;
  *) proxy_ca=""; echo "WARN: no issued certificate for ${PROXY}; the CA ConfigMap is not distributed" >&2 ;;
esac

# 2. Bindings and the CA ConfigMap. One failure does not stop the others; the run ends non-zero
#    so the Job shows it.
rc=0
bound=""
for ns in $federations; do
  if bindings "$ns" | apply; then
    bound="${bound}${ns}
"
    echo "bound ${ns}"
  else
    echo "WARN: binding ${ns} failed" >&2
    rc=1
  fi
  if [ -n "$proxy_ca" ]; then
    ca_configmap "$ns" "$proxy_ca" | apply || { echo "WARN: ${CA_CM} in ${ns} failed" >&2; rc=1; }
  fi
done

# 3. Prune: managed objects outside the labelled set. The labelled set is used, not the bound
#    one, so a transient failure never removes working objects.
# shellcheck disable=SC2086
$KUBECTL get rolebindings --all-namespaces -l "$MANAGED" \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
| while read -r ns name; do
  [ -n "$ns" ] || continue
  if ! printf '%s\n' "$federations" | grep -qx "$ns"; then
    # shellcheck disable=SC2086
    $KUBECTL -n "$ns" delete rolebinding "$name" --ignore-not-found >/dev/null
    echo "pruned rolebinding ${ns}/${name}"
  fi
done
#    CA ConfigMaps: a named get in every other namespace (no cluster-wide list of ConfigMaps).
# shellcheck disable=SC2086
$KUBECTL get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
| while read -r ns; do
  [ -n "$ns" ] || continue
  printf '%s\n' "$federations" | grep -qx "$ns" && continue
  # shellcheck disable=SC2086
  owner=$($KUBECTL -n "$ns" get configmap "$CA_CM" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  [ "$owner" = "$MANAGER" ] || continue
  # shellcheck disable=SC2086
  $KUBECTL -n "$ns" delete configmap "$CA_CM" --ignore-not-found >/dev/null
  echo "pruned configmap ${ns}/${CA_CM}"
done

# 4. Watch list and operator restart.
wanted=$(printf '%s' "$bound" | sort | tr '\n' ',' | sed 's/,$//')
current=$(state WATCH_NAMESPACES)
restarted=$(state restarted_for)
if [ "$wanted" != "$current" ]; then
  state_cm "$wanted" "$restarted" | apply
  echo "watch list: '${current}' -> '${wanted}'"
fi
if [ "$wanted" != "$restarted" ]; then
  # shellcheck disable=SC2086
  $KUBECTL -n "$OPERATOR_NS" delete pod -l "app.kubernetes.io/name=${OPERATOR_SA}" \
    --ignore-not-found --wait=false >/dev/null
  state_cm "$wanted" "$wanted" | apply
  echo "operator restarted for '${wanted}'"
fi
[ -n "$wanted" ] || echo "WARN: no federation namespace bound; the operator exits on an empty WATCH_NAMESPACES" >&2
exit $rc
