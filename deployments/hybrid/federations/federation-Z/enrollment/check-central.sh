#!/usr/bin/env bash
# Health checks of the central cluster before a remote node joins (read-only).
#
# Run with a kubectl context that reads the central cluster. Prints one PASS,
# WARN or FAIL line per check and exits non-zero when a check fails.
#
# Checks: gateway node label, gateway DaemonSet and Gateway object, gateway node
# policy routing against the remote CIDRs, gateway connections, the networkd
# drop-in and route watchdog DaemonSets, leftover uninstall DaemonSets, Calico
# API server and IP pools, Calico tiers, the broker registration of the central
# cluster, PSK and broker credentials, no Secrets in the broker namespace, the
# clusterset.local forward in the cluster CoreDNS, per-remote admission
# policies, hybrid namespace label, the policy Applications, the API server
# egress pins of the network-policy charts (apiServer.cidrs), and subctl (when
# installed).
#
# Parameters (environment variables or key=value arguments):
#   FEDERATION_NS      default federation-z
#   ARGOCD_NS          default argocd-mip-team
#   BROKER_NS          default submariner-k8s-broker
#   OPERATOR_NS        default submariner-operator
#   COREDNS_CONFIGMAP  default rke2-coredns-rke2-coredns (the cluster CoreDNS Corefile)
#   COREDNS_NS         default kube-system
#
# pass/warn/fail below always return 0, so "test && pass || fail" is a plain if/else.
# shellcheck disable=SC2015
set -uo pipefail

for arg in "$@"; do
  case "$arg" in
    *=*) export "${arg?}" ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) printf 'ERROR: unknown argument %s (use KEY=value)\n' "$arg" >&2; exit 2 ;;
  esac
done
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found on PATH" >&2; exit 2; }

FEDERATION_NS="${FEDERATION_NS:-federation-z}"
ARGOCD_NS="${ARGOCD_NS:-argocd-mip-team}"
BROKER_NS="${BROKER_NS:-submariner-k8s-broker}"
OPERATOR_NS="${OPERATOR_NS:-submariner-operator}"
COREDNS_CONFIGMAP="${COREDNS_CONFIGMAP:-rke2-coredns-rke2-coredns}"
COREDNS_NS="${COREDNS_NS:-kube-system}"

fails=0
warns=0
pass() { printf 'PASS  %-46s %s\n' "$1" "${2:-}"; }
warn() { printf 'WARN  %-46s %s\n' "$1" "${2:-}"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %-46s %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
kc() { kubectl --request-timeout=20s "$@"; }

echo "Central cluster: $(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
echo

# --- gateway ------------------------------------------------------------------------------------------------
gw_nodes="$(kc get nodes -l submariner.io/gateway=true -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [[ -n "${gw_nodes// /}" ]]; then
  pass "gateway node label" "$gw_nodes"
else
  fail "gateway node label" "no node carries submariner.io/gateway=true; the cluster provider's node configuration sets it (re-apply by hand and report if missing)"
fi
ds="$(kc -n "$OPERATOR_NS" get daemonset submariner-gateway -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}' 2>/dev/null)"
if [[ "$ds" =~ ^([1-9][0-9]*)/\1$ ]]; then
  pass "gateway DaemonSet" "desired/ready ${ds}"
else
  fail "gateway DaemonSet" "desired/ready ${ds:-not found}"
fi
gws="$(kc -n "$OPERATOR_NS" get gateways.submariner.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.haStatus}{" "}{end}' 2>/dev/null)"
if [[ "$gws" == *"=active"* ]]; then
  pass "Gateway object" "$gws"
else
  fail "Gateway object" "${gws:-none}"
fi
lb="$(kc -n "$OPERATOR_NS" get svc submariner-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
[[ -n "$lb" ]] && pass "gateway LoadBalancer address" "$lb" || fail "gateway LoadBalancer address" "none assigned"

# The operator creates <component>-uninstall DaemonSets while a Submariner resource is being deleted and
# removes them when the cleanup finishes; one that outlives the deletion runs an inert pod on the gateway
# node forever and misleads every later diagnosis.
leftover="$(kc -n "$OPERATOR_NS" get daemonsets -o name 2>/dev/null | grep -E -- '-uninstall$' | sed 's|.*/||' | paste -sd, -)"
if [[ -z "$leftover" ]]; then
  pass "no leftover uninstall DaemonSets"
else
  fail "no leftover uninstall DaemonSets" "${leftover}: leftover of an interrupted Submariner deletion; kubectl -n ${OPERATOR_NS} delete daemonset ${leftover}"
fi

# The route agent installs the gateway node's host-network policy routing (rule "from all lookup 150" and
# table-150 routes to the remote CIDRs with the CNI address as source) at gateway transition only; a
# systemd-networkd restart deletes it and every connection degrades to "error" with the SAs up. The
# DaemonSet submariner-gateway-node-config keeps networkd away from foreign routes on the gateway node.
gw_pod="$(kc -n "$OPERATOR_NS" get pods -l app=submariner-gateway --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
local_id="$(kc -n "$OPERATOR_NS" get submariners.submariner.io -o jsonpath='{.items[0].spec.clusterID}' 2>/dev/null)"
remote_cidrs="$(kc -n "$OPERATOR_NS" get endpoints.submariner.io -o jsonpath='{range .items[*]}{.spec.cluster_id}{" "}{.spec.subnets}{"\n"}{end}' 2>/dev/null \
  | awk -v me="$local_id" '$1 != me {print $2}' | tr -d '[]"' | tr ',' '\n' | sed '/^$/d' | sort -u)"
if [[ -z "$gw_pod" ]]; then
  fail "gateway node policy routing" "no running gateway pod"
else
  routing="$(kc -n "$OPERATOR_NS" exec "$gw_pod" -c submariner-gateway -- sh -c 'ip rule show | grep -c "lookup 150"; ip route show table 150' 2>/dev/null)"
  rule_count="$(head -1 <<<"$routing")"
  missing=""
  for c in $remote_cidrs; do
    tail -n +2 <<<"$routing" | awk '{print $1}' | grep -qx "$c" || missing="${missing} ${c}"
  done
  if [[ "${rule_count:-0}" -ge 1 && -n "$remote_cidrs" && -z "$missing" ]]; then
    pass "gateway node policy routing" "rule lookup 150, table 150 covers $(wc -w <<<"$remote_cidrs" | tr -d ' ') remote CIDRs"
  else
    fail "gateway node policy routing" "rule count ${rule_count:-0}, missing in table 150:${missing:- none}; kubectl -n ${OPERATOR_NS} delete pod -l app=submariner-routeagent --field-selector spec.nodeName=<gateway node>"
  fi
fi
# Connections of the active gateway, as seen from this cluster. Each side pings from its own address
# and reports only its own result, so the remote side can show a different status.
conns="$(kc -n "$OPERATOR_NS" get gateways.submariner.io -o jsonpath='{range .items[?(@.status.haStatus=="active")]}{range .status.connections[*]}{.endpoint.cluster_id}={.status}{" "}{end}{end}' 2>/dev/null)"
bad="$(tr ' ' '\n' <<<"$conns" | sed '/^$/d' | grep -v '=connected$' | tr '\n' ' ')"
if [[ -n "$conns" && -z "$bad" ]]; then
  pass "gateway connections" "$conns"
else
  fail "gateway connections" "${bad:-no connections}; error: see policy routing above; connecting: tunnel down or the remote holds an old endpoint of this cluster (remote-node README, Troubleshooting)"
fi
wd="$(kc -n "$OPERATOR_NS" get daemonset submariner-gateway-route-watchdog -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}' 2>/dev/null)"
if [[ -n "$wd" && "${wd%/*}" == "${wd#*/}" && "${wd%/*}" != 0 ]]; then
  restarts="$(kc -n "$OPERATOR_NS" logs ds/submariner-gateway-route-watchdog --since=168h 2>/dev/null | grep -c 'restarting the route agent')"
  pass "route watchdog DaemonSet" "desired/ready ${wd}, route agent restarts in the last 7 days: ${restarts:-0}"
else
  fail "route watchdog DaemonSet" "desired/ready ${wd:-not found}; apply submariner-rbac.yaml and sync the submariner-operator Application (common/submariner/operator/gateway-route-watchdog.yaml)"
fi
nc="$(kc -n "$OPERATOR_NS" get daemonset submariner-gateway-node-config -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}' 2>/dev/null)"
if [[ -n "$nc" && "${nc%/*}" == "${nc#*/}" && "${nc%/*}" != 0 ]]; then
  pass "networkd drop-in DaemonSet" "desired/ready ${nc}"
else
  fail "networkd drop-in DaemonSet" "desired/ready ${nc:-not found}; sync the submariner-operator Application (common/submariner/operator/gateway-node-networkd.yaml)"
fi

# --- Calico API ---------------------------------------------------------------------------------------------
avail="$(kc get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
if [[ "$avail" == True ]]; then
  pass "Calico API server" "APIService v3.projectcalico.org Available"
else
  fail "Calico API server" "$(kc get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null || echo 'APIService missing')"
  # The usual cause after a cluster redeploy: the pods run but never become
  # ready because their account may not list ConfigMaps cluster-wide.
  if kc auth can-i list configmaps --as=system:serviceaccount:calico-system:calico-apiserver >/dev/null 2>&1; then
    warn "Calico API server RBAC" "account may list configmaps; look at the pod log for the readiness failure"
  else
    fail "Calico API server RBAC" "system:serviceaccount:calico-system:calico-apiserver cannot list configmaps cluster-wide; the pods stay not ready (cluster installation issue)"
  fi
fi
if kc get ippools.projectcalico.org >/dev/null 2>&1; then
  pass "Calico IP pools readable" "$(kc get ippools.projectcalico.org -o name | wc -l | tr -d ' ') pools"
else
  fail "Calico IP pools readable" "projectcalico.org/v3 does not answer; the route agents cannot program remote CIDRs"
fi
if kc get tiers.projectcalico.org default >/dev/null 2>&1; then
  pass "Calico tiers" "supported (Calico 3.29 or later)"
else
  warn "Calico tiers" "not available; common/security/remote-clusters cannot sync"
fi
ts="$(kc get tigerastatus -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status}{" "}{end}' 2>/dev/null)"
if [[ -n "$ts" ]]; then
  [[ "$ts" == *"=False"* ]] && warn "tigera status" "$ts" || pass "tigera status" "$ts"
fi

# --- operator and broker --------------------------------------------------------------------------------------
errs="$(kc -n "$OPERATOR_NS" logs deploy/submariner-operator --since=15m 2>/dev/null | grep -c ' ERR ' || true)"
[[ "${errs:-0}" -eq 0 ]] && pass "operator log (15 min)" "no errors" || warn "operator log (15 min)" "${errs} error lines; see kubectl -n ${OPERATOR_NS} logs deploy/submariner-operator"
central_id="$(kc -n "$OPERATOR_NS" get submariner submariner -o jsonpath='{.spec.clusterID}' 2>/dev/null)"
[[ -n "$central_id" ]] && pass "Submariner resource" "clusterID ${central_id}" || fail "Submariner resource" "not found in ${OPERATOR_NS}"
clusters="$(kc -n "$BROKER_NS" get clusters.submariner.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [[ -n "$central_id" && " $clusters " == *" $central_id "* ]]; then
  pass "broker lists the central cluster" "$clusters"
else
  fail "broker lists the central cluster" "registered: ${clusters:-none}"
fi
kc -n "$OPERATOR_NS" get secret submariner-ipsec-psk >/dev/null 2>&1 \
  && pass "PSK in the operator namespace" || fail "PSK in the operator namespace" "secret submariner-ipsec-psk missing (common/submariner/README.md, IPsec PSK)"
# Broker credentials: the token Secret Kubernetes fills for the operator's broker account
# (common/submariner/operator/broker-credentials.yaml). Checks that the keys exist; prints no values.
broker_secret="$(kc -n "$OPERATOR_NS" get submariner submariner -o jsonpath='{.spec.brokerK8sSecret}' 2>/dev/null)"
filled="$(kc -n "$OPERATOR_NS" get secret "${broker_secret:-none}" -o go-template='{{.type}} {{if index .data "token"}}token{{end}} {{if index .data "ca.crt"}}ca{{end}}' 2>/dev/null)"
if [[ "$filled" == "kubernetes.io/service-account-token token ca" ]]; then
  pass "broker credentials" "${broker_secret}, filled by the token controller"
else
  fail "broker credentials" "Secret ${broker_secret:-unset} is '${filled:-missing}'; sync the submariner-operator Application (broker-credentials.yaml)"
fi
# No Secret belongs in the broker namespace: every account with a broker secret syncer can read it.
broker_ns_secrets="$(kc -n "$BROKER_NS" get secrets -o name 2>/dev/null | sed 's#^secret/##' | tr '\n' ' ')"
if [[ -z "${broker_ns_secrets// /}" ]]; then
  pass "no Secrets in the broker namespace"
else
  fail "no Secrets in the broker namespace" "${broker_ns_secrets}; delete them (the broker token and the PSK live in ${OPERATOR_NS})"
fi
# The operator writes a clusterset.local forward into the cluster's CoreDNS Corefile. A re-apply of the
# CoreDNS chart (RKE2 upgrade or restart) drops it, and every clusterset name stops resolving until the
# operator reconciles again; it does not watch that ConfigMap.
lh_ip="$(kc -n "$OPERATOR_NS" get svc submariner-lighthouse-coredns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
corefile="$(kc -n "$COREDNS_NS" get configmap "$COREDNS_CONFIGMAP" -o jsonpath='{.data.Corefile}' 2>/dev/null)"
if [[ -z "$corefile" ]]; then
  fail "CoreDNS clusterset forward" "ConfigMap ${COREDNS_NS}/${COREDNS_CONFIGMAP} not found; set COREDNS_CONFIGMAP"
elif [[ -n "$lh_ip" && "$corefile" == *"clusterset.local:53"* && "$corefile" == *"forward . ${lh_ip}"* ]]; then
  pass "CoreDNS clusterset forward" "clusterset.local -> ${lh_ip}"
else
  fail "CoreDNS clusterset forward" "block missing or stale in ${COREDNS_NS}/${COREDNS_CONFIGMAP} (lighthouse-coredns ${lh_ip:-unknown}); kubectl -n ${OPERATOR_NS} rollout restart deploy/submariner-operator"
fi

# --- per-remote identities -------------------------------------------------------------------------------------
kc -n "$BROKER_NS" get role submariner-remote-cluster >/dev/null 2>&1 \
  && pass "Role submariner-remote-cluster" || fail "Role submariner-remote-cluster" "apply base/mip-infrastructure/rbac/submariner-remote-admission.yaml"
for p in submariner-remote-cluster-ownership submariner-remote-cluster-subnets; do
  if kc get validatingadmissionpolicy "$p" >/dev/null 2>&1 && kc get validatingadmissionpolicybinding "$p" >/dev/null 2>&1; then
    pass "admission policy ${p#submariner-remote-cluster-}" "policy and binding present"
  else
    fail "admission policy ${p#submariner-remote-cluster-}" "missing; apply submariner-remote-admission.yaml"
  fi
done
enrolled="$(kc -n "$BROKER_NS" get serviceaccounts -l submariner.io/remote-enrollment=true -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
[[ -n "${enrolled// /}" ]] && pass "enrolled remote accounts" "$enrolled" || warn "enrolled remote accounts" "none (enroll-remote.sh)"

# --- federation namespace and policies -------------------------------------------------------------------------
ftype="$(kc get namespace "$FEDERATION_NS" -o jsonpath='{.metadata.labels.mip\.federation-type}' 2>/dev/null)"
if [[ "$ftype" == hybrid ]]; then
  pass "namespace ${FEDERATION_NS} labelled hybrid"
else
  fail "namespace ${FEDERATION_NS} labelled hybrid" "mip.federation-type=${ftype:-missing}; set by Application netpol-${FEDERATION_NS}-hybrid (managedNamespaceMetadata); the global policy denies remote flows without it"
fi
pols="$(kc -n "$FEDERATION_NS" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
for want in federation-default-deny remote-workers-to-controller controller-to-remote-workers remote-workers-to-aggregation-server; do
  [[ " $pols " == *" $want "* ]] && pass "NetworkPolicy ${want}" || fail "NetworkPolicy ${want}" "missing in ${FEDERATION_NS}"
done
[[ " $pols " == *" allow-submariner-cidrs "* ]] && warn "NetworkPolicy allow-submariner-cidrs" "obsolete all-ports policy still present; delete it"
kc get globalnetworkpolicies.projectcalico.org remote-clusters.confine-remote-clusters >/dev/null 2>&1 \
  && pass "global policy confine-remote-clusters" || warn "global policy confine-remote-clusters" "not present (Application netpol-remote-clusters)"
for app in "netpol-${FEDERATION_NS}-hybrid" netpol-remote-clusters "${FEDERATION_NS}-submariner-network-policy" submariner-operator; do
  st="$(kc -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  if [[ "$st" == "Synced/Healthy" ]]; then
    pass "Application ${app}" "$st"
  else
    warn "Application ${app}" "${st:-not found}"
  fi
done

# --- API server egress pins ------------------------------------------------------------------------------------
# The federation and common network-policy charts limit egress on TCP 6443 to apiServer.cidrs, which must cover
# the kubernetes Service endpoints (the control-plane node addresses after the Service DNAT). An empty list leaves
# the port open to any address; a list that misses an endpoint cuts the notebook hub and operator off the API.
repo_root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
api_cidrs() { # $1 values file: the items of apiServer.cidrs, one per line
  awk '
    /^apiServer:/ { in_api = 1; next }
    in_api && /^[^ ]/ { in_api = 0 }
    in_api && /^  cidrs:/ { in_cidrs = ($0 !~ /\[\]/); next }
    in_api && in_cidrs && /^    - / { sub(/^    - */, ""); sub(/[ #].*$/, ""); print; next }
    in_api && in_cidrs && /^  [^ ]/ { in_cidrs = 0 }
  ' "$1" | sort -u
}
in_cidr() { # $1 IPv4 address, $2 cidr: true when the address lies in the cidr
  local ip=$1 net=${2%/*} bits=32 a b c d mask
  [[ "$2" == */* ]] && bits=${2#*/}
  IFS=. read -r a b c d <<<"$ip"; ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  IFS=. read -r a b c d <<<"$net"; net=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (ip & mask) == (net & mask) ))
}
fed_cidrs="$(api_cidrs "$repo_root/common/security/federation/values.yaml")"
common_cidrs="$(api_cidrs "$repo_root/common/security/common-templates/values.yaml")"
endpoints="$(kc get endpointslices -n default -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' 2>/dev/null | sort -u)"
if [[ "$fed_cidrs" != "$common_cidrs" ]]; then
  fail "apiServer.cidrs" "common/security/federation/values.yaml and common-templates/values.yaml differ"
elif [[ -z "$endpoints" ]]; then
  warn "apiServer.cidrs" "could not read the kubernetes Service endpoints"
elif [[ -z "$fed_cidrs" ]]; then
  warn "apiServer.cidrs" "empty: egress on 6443 is open to any address; set it to cover ${endpoints//$'\n'/ }"
else
  uncovered=""
  for ep in $endpoints; do
    [[ "$ep" == *:* ]] && { uncovered="$uncovered $ep(IPv6, not checked)"; continue; }
    covered=0
    for cidr in $fed_cidrs; do in_cidr "$ep" "$cidr" && { covered=1; break; }; done
    (( covered )) || uncovered="$uncovered $ep"
  done
  if [[ -z "$uncovered" ]]; then
    pass "apiServer.cidrs" "covers the kubernetes endpoints ${endpoints//$'\n'/ }"
  else
    fail "apiServer.cidrs" "not covered:${uncovered}; the notebook hub and operator cannot reach the API server"
  fi
fi

# --- subctl ------------------------------------------------------------------------------------------------
if command -v subctl >/dev/null 2>&1; then
  if subctl show gateways 2>/dev/null | grep -q -i 'active'; then
    pass "subctl show gateways" "active"
  else
    fail "subctl show gateways" "$(subctl show gateways 2>&1 | grep -v '^$' | tail -1)"
  fi
fi

echo
printf 'Result: %d failed, %d warnings\n' "$fails" "$warns"
(( fails == 0 ))
