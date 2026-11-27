#!/usr/bin/env bash
# Enrolls one remote cluster on the Submariner broker of the central cluster.
#
# Run by the central operator with a kubectl context that administers the central cluster.
# Creates (idempotently) in the broker namespace:
#   ServiceAccount cluster-<id>
#   RoleBinding    cluster-<id>-submariner-remote-cluster        -> Role submariner-remote-cluster
#   RoleBinding    cluster-<id>-submariner-remote-cluster-secret-syncer (only with BROKER_SECRET_SYNCER=true)
#   ConfigMap      cluster-<id> (label submariner.io/remote-enrollment=true; data.exports, and data.subnets
#                  when SUBNETS is set): the enrollment record read by the subnet and export policies
# and writes into OUT_DIR (mode 0700, files 0600):
#   cluster-id.txt         the cluster ID (name suffix of the account)
#   broker-token.txt       bound service-account token, plain text (kubectl create token)
#   broker-ca.crt          broker API server CA, PEM
#   broker-ca-base64.txt   the same CA base64-encoded, as stored in a Secret / expected by Helm value broker.ca
#   broker-psk.txt         .data.psk of secret submariner-ipsec-psk (submariner-operator), base64 as stored
#   broker-url.txt         API server URL the remote must use (BROKER_URL or the kubeconfig server)
#   subnets.txt            the SUBNETS value, read by verify-enrollment.sh to test the subnet pinning
#   exports.txt            the EXPORTS value, read by verify-enrollment.sh to test the export pinning
#   token-expiry.txt       expiry of the issued token (UTC)
#
# Parameters (environment variables or key=value arguments):
#   CLUSTER_ID           default rn-<8 hex>; re-use the recorded ID to re-enroll or rotate a node
#   SUBNETS              comma-separated CIDRs the node may announce (pod and service CIDR); empty = no pinning
#   EXPORTS              comma-separated <namespace>/<service> entries the node may publish to the clusterset.
#                        Default: the worker export of this federation, read from
#                        ../remote-node/exaflow-worker/serviceexport.yaml. Empty (EXPORTS=) = the node may
#                        publish nothing. Everything else is refused by the broker.
#   TOKEN_DURATION       default 8760h (the API server may cap it: --service-account-max-token-expiration)
#   OUT_DIR              default ./enroll-<CLUSTER_ID>
#   BROKER_URL           API server URL reachable from the remote site (default: current kubeconfig server)
#   BROKER_NS            default submariner-k8s-broker
#   OPERATOR_NS          default submariner-operator
#   PSK_SECRET           default submariner-ipsec-psk
#   BROKER_SECRET_SYNCER default false; true also binds Role submariner-remote-cluster-secret-syncer
#                        (required if the remote's Submariner resource sets brokerK8sSecret)
#   ROTATE_IDENTITY      default false; true deletes and recreates the ServiceAccount first, which invalidates
#                        every token issued to it so far (a re-run without it only adds a token)
#
# Re-runs keep the account and issue a fresh token. Previously issued tokens stay valid until they expire
# unless ROTATE_IDENTITY=true is used (or revoke-remote.sh deletes the account). A re-run also rewrites the
# enrollment record: pass the SUBNETS and EXPORTS of the first run again; the script warns when they differ.
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    *=*) export "${arg?}" ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) die "unknown argument '${arg}' (use KEY=value)" ;;
  esac
done

for tool in kubectl openssl base64; do
  command -v "$tool" >/dev/null 2>&1 || die "${tool} not found on PATH"
done

BROKER_NS="${BROKER_NS:-submariner-k8s-broker}"
OPERATOR_NS="${OPERATOR_NS:-submariner-operator}"
PSK_SECRET="${PSK_SECRET:-submariner-ipsec-psk}"
ROLE=submariner-remote-cluster
SYNCER_ROLE=submariner-remote-cluster-secret-syncer
TOKEN_DURATION="${TOKEN_DURATION:-8760h}"
SUBNETS="${SUBNETS:-}"
# The export a node of this federation needs is the one its runbook manifests create.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker_export="${here}/../remote-node/exaflow-worker/serviceexport.yaml"
default_exports=""
if [[ -f "$worker_export" ]]; then
  default_exports="$(awk '$1 == "name:" {n = $2} $1 == "namespace:" {ns = $2} END {if (n != "" && ns != "") print ns "/" n}' "$worker_export")"
fi
EXPORTS="$(tr -d '[:space:]' <<<"${EXPORTS-$default_exports}")"
BROKER_SECRET_SYNCER="${BROKER_SECRET_SYNCER:-false}"
ROTATE_IDENTITY="${ROTATE_IDENTITY:-false}"
CLUSTER_ID="${CLUSTER_ID:-rn-$(openssl rand -hex 4)}"
OUT_DIR="${OUT_DIR:-./enroll-${CLUSTER_ID}}"
SA="cluster-${CLUSTER_ID}"

# The ID is a DNS-1123 label: it becomes the Cluster object name, the suffix of the account name and of the
# annotation key timestamp.submariner.io/<id>; admiral's EnsureValidName then leaves it unchanged.
[[ "$CLUSTER_ID" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || die "CLUSTER_ID '${CLUSTER_ID}' is not a valid DNS label (lowercase alphanumerics and '-', max 63)"
[[ "$TOKEN_DURATION" =~ ^[0-9]+(h|m|s)$ ]] || die "TOKEN_DURATION '${TOKEN_DURATION}' must look like 8760h"
if [[ -n "$SUBNETS" ]]; then
  IFS=',' read -r -a subnet_list <<<"$SUBNETS"
  for s in "${subnet_list[@]}"; do
    s="$(tr -d '[:space:]' <<<"$s")"
    [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ || "$s" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]] \
      || die "SUBNETS entry '${s}' is not a CIDR"
  done
fi
if [[ -n "$EXPORTS" ]]; then
  IFS=',' read -r -a export_list <<<"$EXPORTS"
  for e in "${export_list[@]}"; do
    [[ "$e" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?/[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
      || die "EXPORTS entry '${e}' is not <namespace>/<service>"
  done
else
  warn "no export recorded: the broker will refuse every service this node publishes, its worker included." \
    "Pass EXPORTS=<namespace>/<service> unless that is intended."
fi

# --- preconditions on the central cluster ----------------------------------------------------------------
kubectl get namespace "$BROKER_NS" >/dev/null 2>&1 || die "namespace ${BROKER_NS} not found in the current context"
kubectl -n "$BROKER_NS" get role "$ROLE" >/dev/null 2>&1 \
  || die "Role ${ROLE} not found in ${BROKER_NS}; apply submariner-remote-admission.yaml first"
if [[ "$BROKER_SECRET_SYNCER" == true ]]; then
  kubectl -n "$BROKER_NS" get role "$SYNCER_ROLE" >/dev/null 2>&1 \
    || die "Role ${SYNCER_ROLE} not found in ${BROKER_NS}; apply submariner-remote-admission.yaml first"
fi
if ! kubectl get validatingadmissionpolicy submariner-remote-cluster-ownership >/dev/null 2>&1; then
  warn "ValidatingAdmissionPolicy submariner-remote-cluster-ownership is not installed; the account would" \
    "be able to touch other clusters' broker objects. Apply submariner-remote-admission.yaml."
fi
if ! kubectl get validatingadmissionpolicy submariner-remote-cluster-exports >/dev/null 2>&1; then
  warn "ValidatingAdmissionPolicy submariner-remote-cluster-exports is not installed; the account would" \
    "be able to publish any service in any namespace. Apply submariner-remote-admission.yaml."
fi
if ! kubectl get validatingadmissionpolicy submariner-remote-cluster-records >/dev/null 2>&1; then
  warn "ValidatingAdmissionPolicy submariner-remote-cluster-records is not installed; service accounts" \
    "could rewrite the enrollment record. Apply submariner-remote-admission.yaml."
fi
kubectl -n "$OPERATOR_NS" get secret "$PSK_SECRET" >/dev/null 2>&1 \
  || die "secret ${PSK_SECRET} not found in ${OPERATOR_NS} (created once by hand, see common/submariner/README.md, Install, step 2)"

# --- identity ---------------------------------------------------------------------------------------------
if [[ "$ROTATE_IDENTITY" == true ]] && kubectl -n "$BROKER_NS" get serviceaccount "$SA" >/dev/null 2>&1; then
  log "Deleting ServiceAccount ${SA} to invalidate all tokens issued so far"
  kubectl -n "$BROKER_NS" delete serviceaccount "$SA"
fi

# A re-run rewrites the record with the values of this run.
if recorded="$(kubectl -n "$BROKER_NS" get configmap "$SA" -o jsonpath='{.data.subnets}{"|"}{.data.exports}' 2>/dev/null)"; then
  recorded="$(tr -d '[:space:]' <<<"$recorded")"
  if [[ "$recorded" != "$(tr -d '[:space:]' <<<"$SUBNETS")|${EXPORTS}" ]]; then
    warn "the record of ${SA} changes: subnets '${recorded%%|*}' -> '$(tr -d '[:space:]' <<<"$SUBNETS")'," \
      "exports '${recorded#*|}' -> '${EXPORTS}'. Pass SUBNETS and EXPORTS as recorded to keep them."
  fi
fi

log "Ensuring ServiceAccount ${SA}, enrollment ConfigMap and RoleBinding(s) in ${BROKER_NS}"
# The ConfigMap is the parameter of the policies submariner-remote-cluster-subnets and
# submariner-remote-cluster-exports. It is written before the RoleBinding: an account that can write to the
# broker without a record would not be restricted by the export policy. Without SUBNETS no subnet is pinned;
# an empty exports entry allows no export.
{
  cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA}
  namespace: ${BROKER_NS}
  labels:
    submariner.io/remote-enrollment: "true"
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${SA}
  namespace: ${BROKER_NS}
  labels:
    submariner.io/remote-enrollment: "true"
  annotations:
    submariner.io/enrolled-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
data:
  exports: "${EXPORTS}"
EOF
  if [[ -n "$SUBNETS" ]]; then
    printf '  subnets: "%s"\n' "$(tr -d '[:space:]' <<<"$SUBNETS")"
  fi
} | kubectl apply -f -

kubectl apply -f - <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SA}-${ROLE}
  namespace: ${BROKER_NS}
  labels:
    submariner.io/remote-enrollment: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE}
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${BROKER_NS}
EOF

if [[ "$BROKER_SECRET_SYNCER" == true ]]; then
  kubectl apply -f - <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SA}-${SYNCER_ROLE}
  namespace: ${BROKER_NS}
  labels:
    submariner.io/remote-enrollment: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${SYNCER_ROLE}
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${BROKER_NS}
EOF
else
  kubectl -n "$BROKER_NS" delete rolebinding "${SA}-${SYNCER_ROLE}" --ignore-not-found >/dev/null
fi

# --- credentials ------------------------------------------------------------------------------------------
umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

log "Issuing a bound token for ${SA} (duration ${TOKEN_DURATION})"
token="$(kubectl -n "$BROKER_NS" create token "$SA" --duration="$TOKEN_DURATION")"
[[ "$token" == *.*.* ]] || die "kubectl create token did not return a JWT"
printf '%s\n' "$token" >"${OUT_DIR}/broker-token.txt"

# Decode the exp claim without extra tools: JWT payload is base64url without padding.
payload="$(cut -d. -f2 <<<"$token" | tr '_-' '/+')"
pad=$(( (4 - ${#payload} % 4) % 4 ))
padding="$(printf '%*s' "$pad" '' | tr ' ' '=')"
claims="$(printf '%s%s' "$payload" "$padding" | base64 -d 2>/dev/null || true)"
exp="$(sed -n 's/.*"exp":\([0-9]*\).*/\1/p' <<<"$claims")"
if [[ -n "$exp" ]]; then
  if date -u -d "@$exp" >/dev/null 2>&1; then
    expiry="$(date -u -d "@$exp" +%Y-%m-%dT%H:%MZ)"
  else
    expiry="$(date -u -r "$exp" +%Y-%m-%dT%H:%MZ)"
  fi
  printf '%s\n' "$expiry" >"${OUT_DIR}/token-expiry.txt"
  case "$TOKEN_DURATION" in
    *h) unit=3600 ;;
    *m) unit=60 ;;
    *) unit=1 ;;
  esac
  requested=$(( ${TOKEN_DURATION%[hms]} * unit ))
  now=$(date +%s)
  if (( exp < now + requested - 3600 )); then
    warn "the API server capped the token lifetime: expires ${expiry} (requested ${TOKEN_DURATION});" \
      "check --service-account-max-token-expiration on the central API server"
  fi
else
  warn "could not decode the token expiry"
  expiry="unknown"
fi

log "Collecting the broker CA"
# kube-root-ca.crt is the CA the API server serving certificate chains to (--root-ca-file); fall back to the
# kubeconfig of the current context.
ca_pem="$(kubectl -n "$BROKER_NS" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
if [[ -z "$ca_pem" ]]; then
  ca_pem="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    | base64 -d)"
fi
[[ -n "$ca_pem" ]] || die "could not determine the broker CA"
printf '%s\n' "$ca_pem" >"${OUT_DIR}/broker-ca.crt"
openssl x509 -in "${OUT_DIR}/broker-ca.crt" -noout >/dev/null 2>&1 || die "the collected CA is not a certificate"
base64 <"${OUT_DIR}/broker-ca.crt" | tr -d '\n' >"${OUT_DIR}/broker-ca-base64.txt"
printf '\n' >>"${OUT_DIR}/broker-ca-base64.txt"

log "Collecting the IPsec PSK (${OPERATOR_NS}/${PSK_SECRET}, .data.psk as stored)"
psk_b64="$(kubectl -n "$OPERATOR_NS" get secret "$PSK_SECRET" -o jsonpath='{.data.psk}')"
[[ -n "$psk_b64" ]] || die "secret ${PSK_SECRET} has no .data.psk"
printf '%s\n' "$psk_b64" >"${OUT_DIR}/broker-psk.txt"

broker_url="${BROKER_URL:-$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')}"
printf '%s\n' "$broker_url" >"${OUT_DIR}/broker-url.txt"
printf '%s\n' "$(tr -d '[:space:]' <<<"$SUBNETS")" >"${OUT_DIR}/subnets.txt"
printf '%s\n' "$EXPORTS" >"${OUT_DIR}/exports.txt"
context_proxy="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.proxy-url}' 2>/dev/null || true)"
if [[ -n "$context_proxy" || -n "${HTTPS_PROXY:-}${https_proxy:-}" ]]; then
  warn "this machine reaches the API server through a proxy (${context_proxy:-${HTTPS_PROXY:-${https_proxy:-}}});" \
    "verify-enrollment.sh picks it up from the kubeconfig or PROXY_URL. The remote node connects directly."
fi
printf '%s\n' "$CLUSTER_ID" >"${OUT_DIR}/cluster-id.txt"
chmod 600 "${OUT_DIR}"/*
if [[ -z "${BROKER_URL:-}" ]]; then
  warn "broker-url.txt holds the kubeconfig server URL (${broker_url}); set BROKER_URL if the remote site" \
    "must use a different address. The CA must be valid for that name (check with verify-enrollment.sh)."
fi

cat <<EOF

Enrolled cluster ID : ${CLUSTER_ID}
Account             : system:serviceaccount:${BROKER_NS}:${SA}
Roles               : ${ROLE}$( [[ "$BROKER_SECRET_SYNCER" == true ]] && printf ', %s' "$SYNCER_ROLE" )
Pinned subnets      : ${SUBNETS:-none}
Allowed exports     : ${EXPORTS:-none}
Token expires       : ${expiry}
Broker URL          : ${broker_url}
Files (mode 0600)   : ${OUT_DIR}/{cluster-id.txt,broker-token.txt,broker-ca.crt,broker-ca-base64.txt,broker-psk.txt,broker-url.txt,subnets.txt,exports.txt}

Record the cluster ID and the token expiry with the site in the internal tracking system.
Hand the files to the site over the agreed channel; they are credentials. Verify before shipping:
  ./verify-enrollment.sh OUT_DIR=${OUT_DIR}
Before the expiry, re-run this script with CLUSTER_ID=${CLUSTER_ID} and re-run the join on the node.
EOF
