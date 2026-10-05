#!/usr/bin/env bash
# Verifies an enrollment produced by enroll-remote.sh using ONLY the bound token and the CA, the way the
# remote will use them. Nothing is created: every write is a server-side dry run (--dry-run=server), which
# runs RBAC and admission (including the ValidatingAdmissionPolicies) without persisting anything.
#
# Checks (PASS/FAIL per line, exit 1 if any FAIL):
#   reachability  the broker URL answers over HTTPS from this machine (fails fast instead of hanging)
#   identity      the token authenticates as system:serviceaccount:<broker ns>:cluster-<id>
#   own objects   Endpoint, Cluster, EndpointSlice and aggregated ServiceImport with the caller's ID: admitted
#   foreign       the same objects with another cluster's ID: denied by the ownership policy
#   subnets       (when the enrollment ConfigMap pins subnets) an Endpoint outside them: denied
#   least priv.   secrets in the broker namespace, and the Broker resource: forbidden
#
# Parameters (environment variables or key=value arguments):
#   OUT_DIR      directory written by enroll-remote.sh (default .); provides the files below unless overridden
#   TOKEN_FILE   default OUT_DIR/broker-token.txt
#   CA_FILE      default OUT_DIR/broker-ca.crt (falls back to decoding OUT_DIR/broker-ca-base64.txt)
#   BROKER_URL   default: content of OUT_DIR/broker-url.txt
#   CLUSTER_ID   default: content of OUT_DIR/cluster-id.txt
#   SUBNETS      comma-separated CIDRs allowed at enrollment; default: content of OUT_DIR/subnets.txt
#                (written by enroll-remote.sh). The first CIDR is used for the "own" Endpoint; an address
#                outside the list must be denied.
#   PROXY_URL    proxy for reaching the broker from this machine (socks5://..., http://...). Default, in
#                order: the proxy-url of the current kubeconfig context; socks5://127.0.0.1:1080 when a
#                listener is open there (the SSH -D 1080 tunnel of docs/remote-access.md); none otherwise.
#                HTTPS_PROXY in the environment is honoured by kubectl and curl as well.
#   TIMEOUT      per-request timeout, default 20s
#   BROKER_NS    default submariner-k8s-broker
#
# The remote node itself connects directly (its network is allowlisted on the API server); this machine
# often is not, hence the proxy handling above.
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    *=*) export "${arg?}" ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) printf 'ERROR: unknown argument %s (use KEY=value)\n' "$arg" >&2; exit 2 ;;
  esac
done
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found on PATH" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found on PATH" >&2; exit 2; }

OUT_DIR="${OUT_DIR:-.}"
BROKER_NS="${BROKER_NS:-submariner-k8s-broker}"
TOKEN_FILE="${TOKEN_FILE:-${OUT_DIR}/broker-token.txt}"
CA_FILE="${CA_FILE:-${OUT_DIR}/broker-ca.crt}"
CLUSTER_ID="${CLUSTER_ID:-$(tr -d '[:space:]' <"${OUT_DIR}/cluster-id.txt" 2>/dev/null || true)}"
BROKER_URL="${BROKER_URL:-$(tr -d '[:space:]' <"${OUT_DIR}/broker-url.txt" 2>/dev/null || true)}"
SUBNETS="${SUBNETS:-$(tr -d '[:space:]' <"${OUT_DIR}/subnets.txt" 2>/dev/null || true)}"
TIMEOUT="${TIMEOUT:-20s}"
# Read the proxy of the current context before KUBECONFIG is redirected below; fall back to the local
# SOCKS tunnel when one is listening.
PROXY_URL="${PROXY_URL:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.proxy-url}' 2>/dev/null || true)}"
if [[ -z "$PROXY_URL" ]] && command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 1080 >/dev/null 2>&1; then
  PROXY_URL=socks5://127.0.0.1:1080
fi
[[ -s "$TOKEN_FILE" ]] || { echo "ERROR: token file ${TOKEN_FILE} missing" >&2; exit 2; }
[[ -n "$CLUSTER_ID" ]] || { echo "ERROR: CLUSTER_ID unknown (no cluster-id.txt)" >&2; exit 2; }
[[ -n "$BROKER_URL" ]] || { echo "ERROR: BROKER_URL unknown (no broker-url.txt)" >&2; exit 2; }

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ ! -s "$CA_FILE" ]]; then
  [[ -s "${OUT_DIR}/broker-ca-base64.txt" ]] || { echo "ERROR: no CA file" >&2; exit 2; }
  base64 -d <"${OUT_DIR}/broker-ca-base64.txt" >"$tmp/ca.crt"
  CA_FILE="$tmp/ca.crt"
fi

# A private kubeconfig keeps the token off the command line (visible in process listings otherwise).
{
  cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: broker
    cluster:
      server: ${BROKER_URL}
      certificate-authority: ${CA_FILE}
EOF
  [[ -n "$PROXY_URL" ]] && printf '      proxy-url: %s\n' "$PROXY_URL"
  cat <<EOF
users:
  - name: remote
    user:
      token: $(tr -d '[:space:]' <"$TOKEN_FILE")
contexts:
  - name: remote
    context:
      cluster: broker
      user: remote
      namespace: ${BROKER_NS}
current-context: remote
EOF
} >"$tmp/kubeconfig"
export KUBECONFIG="$tmp/kubeconfig"
unset KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT

fails=0
pass() { printf 'PASS  %-58s %s\n' "$1" "${2:-}"; }
fail() { printf 'FAIL  %-58s %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
first_line() { head -n1 | cut -c1-160; }
kc() { kubectl --request-timeout="$TIMEOUT" "$@"; }

echo "Broker ${BROKER_URL}, namespace ${BROKER_NS}, cluster ID ${CLUSTER_ID}${PROXY_URL:+, proxy ${PROXY_URL}}"

# --- reachability: fail fast with a usable message instead of hanging in discovery ------------------------
curl_proxy=()
[[ -n "$PROXY_URL" ]] && curl_proxy=(--proxy "$PROXY_URL")
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' --cacert "$CA_FILE" ${curl_proxy[@]+"${curl_proxy[@]}"} \
  "${BROKER_URL}/version" 2>"$tmp/curl.err" || echo 000)"
case "$code" in
  200|401|403) pass "broker URL reachable over HTTPS" "HTTP ${code}" ;;
  *)
    fail "broker URL reachable over HTTPS" "$(first_line <"$tmp/curl.err")"
    echo "      The API server is not reachable from this machine with these settings. Use the same path as"
    echo "      your kubectl context: set PROXY_URL=socks5://127.0.0.1:<port> (SSH -D tunnel) or run from an"
    echo "      allowlisted network. The remote node connects directly and does not need this."
    ;;
esac
if (( fails > 0 )); then
  echo
  echo "RESULT: ${fails} check(s) failed"
  exit 1
fi

# expect_ok NAME MANIFEST      -> server dry-run create must succeed
# expect_denied NAME MANIFEST  -> must be refused by a ValidatingAdmissionPolicy
expect_ok() {
  local out policy
  if out="$(kc -n "$BROKER_NS" create --dry-run=server -f - <<<"$2" 2>&1)"; then
    pass "$1" "$(first_line <<<"$out")"
  else
    policy="$(grep -o "ValidatingAdmissionPolicy '[^']*'" <<<"$out" | head -n1)"
    if [[ -n "$policy" ]]; then
      fail "$1" "denied by ${policy}: $(sed -n 's/.*ValidatingAdmissionPolicy[^:]*: *//p' <<<"$out" | first_line)"
    else
      fail "$1" "$(first_line <<<"$out")"
    fi
  fi
}
expect_denied() {
  local out
  if out="$(kc -n "$BROKER_NS" create --dry-run=server -f - <<<"$2" 2>&1)"; then
    fail "$1" "unexpectedly admitted"
  elif grep -q "ValidatingAdmissionPolicy" <<<"$out"; then
    pass "$1" "$(grep -o "ValidatingAdmissionPolicy '[^']*'" <<<"$out" | head -n1)"
  else
    fail "$1" "refused for another reason: $(first_line <<<"$out")"
  fi
}
expect_forbidden() {
  local out
  if out="$(kc -n "$BROKER_NS" "${@:2}" 2>&1)"; then
    fail "$1" "unexpectedly allowed"
  elif grep -qi "forbidden" <<<"$out"; then
    pass "$1" "forbidden"
  else
    fail "$1" "failed for another reason: $(first_line <<<"$out")"
  fi
}

own_subnet="$(tr -d '[:space:]' <<<"${SUBNETS%%,*}")"
[[ -n "$own_subnet" ]] || own_subnet="10.42.0.0/16"  # only used for the Cluster manifest when subnets are unknown
foreign_id="rn-00000000"
[[ "$foreign_id" == "$CLUSTER_ID" ]] && foreign_id="rn-ffffffff"

endpoint() { # endpoint CLUSTER_ID SUBNET
  cat <<EOF
apiVersion: submariner.io/v1
kind: Endpoint
metadata:
  name: ${1}-verify
spec:
  cluster_id: ${1}
  cable_name: verify
  hostname: verify
  subnets:
    - ${2}
  nat_enabled: true
  backend: libreswan
  private_ip: 192.0.2.10
  public_ip: 198.51.100.10
EOF
}
cluster() { # cluster NAME CLUSTER_ID
  cat <<EOF
apiVersion: submariner.io/v1
kind: Cluster
metadata:
  name: ${1}
spec:
  cluster_id: ${2}
  cluster_cidr:
    - ${own_subnet}
  service_cidr:
    - 10.43.0.0/16
  global_cidr: []
EOF
}
endpointslice() { # endpointslice CLUSTER_ID
  cat <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: verify-${1}
  labels:
    endpointslice.kubernetes.io/managed-by: lighthouse-agent.submariner.io
    lighthouse.submariner.io/sourceNamespace: verify
    multicluster.kubernetes.io/service-name: verify
    multicluster.kubernetes.io/source-cluster: ${1}
    submariner-io/clusterID: ${1}
addressType: IPv4
endpoints: []
ports: []
EOF
}
serviceimport() { # serviceimport TIMESTAMP_CLUSTER_ID
  cat <<EOF
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceImport
metadata:
  name: verify-enrollment-verify
  annotations:
    multicluster.kubernetes.io/service-name: verify-enrollment
    lighthouse.submariner.io/sourceNamespace: verify
    timestamp.submariner.io/${1}: "1"
spec:
  type: ClusterSetIP
  ports: []
EOF
}

# --- identity -----------------------------------------------------------------------------------------------
if who="$(kc auth whoami -o jsonpath='{.status.userInfo.username}' 2>"$tmp/whoami.err")"; then
  if [[ "$who" == "system:serviceaccount:${BROKER_NS}:cluster-${CLUSTER_ID}" ]]; then
    pass "token identity" "$who"
  else
    fail "token identity" "${who:-unknown}"
  fi
else
  echo "SKIP  token identity (kubectl auth whoami failed: $(first_line <"$tmp/whoami.err"))"
fi
if out="$(kc get clusters.submariner.io -o name 2>&1)"; then
  pass "token can list broker Clusters" "$(grep -c . <<<"$out" || true) objects"
else
  fail "token can list broker Clusters" "$(first_line <<<"$out")"
fi

# --- admission policies --------------------------------------------------------------------------------------
if [[ -n "$SUBNETS" ]]; then
  expect_ok   "Endpoint with own cluster_id (dry run)"            "$(endpoint "$CLUSTER_ID" "$own_subnet")"
else
  echo "SKIP  Endpoint with own cluster_id: enrolled subnets unknown (no ${OUT_DIR}/subnets.txt; pass SUBNETS=<list>" \
    "or re-run enroll-remote.sh CLUSTER_ID=${CLUSTER_ID} ..., which writes it)"
fi
expect_denied "Endpoint with foreign cluster_id"                  "$(endpoint "$foreign_id" "$own_subnet")"
expect_ok     "Cluster with own cluster_id (dry run)"             "$(cluster "$CLUSTER_ID" "$CLUSTER_ID")"
expect_denied "Cluster with foreign cluster_id"                   "$(cluster "$foreign_id" "$foreign_id")"
expect_denied "Cluster named after another cluster"               "$(cluster "$foreign_id" "$CLUSTER_ID")"
expect_ok     "EndpointSlice labelled with own ID (dry run)"      "$(endpointslice "$CLUSTER_ID")"
expect_denied "EndpointSlice labelled with foreign ID"            "$(endpointslice "$foreign_id")"
expect_ok     "aggregated ServiceImport, own timestamp (dry run)" "$(serviceimport "$CLUSTER_ID")"
expect_denied "aggregated ServiceImport, foreign timestamp"       "$(serviceimport "$foreign_id")"
if [[ -n "$SUBNETS" ]]; then
  expect_denied "Endpoint with a subnet outside the enrolled list" "$(endpoint "$CLUSTER_ID" "203.0.113.0/24")"
else
  echo "SKIP  Endpoint subnet pinning (pass SUBNETS=<enrolled list> to test it)"
fi

# --- least privilege -----------------------------------------------------------------------------------------
expect_forbidden "reading secrets in the broker namespace"        get secrets
expect_forbidden "reading the Broker resource"                    get brokers.submariner.io
expect_forbidden "reading service accounts"                       get serviceaccounts

echo
if (( fails == 0 )); then
  echo "RESULT: all checks passed"
else
  echo "RESULT: ${fails} check(s) failed"
  exit 1
fi
