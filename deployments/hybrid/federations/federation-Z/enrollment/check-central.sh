#!/usr/bin/env bash
# Health checks of the central cluster before a remote node joins (read-only).
#
# Run with a kubectl context that reads the central cluster. Prints one PASS,
# WARN or FAIL line per check and exits non-zero when a check fails.
#
# Checks: gateway node label, gateway DaemonSet and Gateway object, gateway node
# policy routing and the networkd drop-in DaemonSet, leftover uninstall
# DaemonSets, Calico API server and IP pools, Calico tiers, the broker
# registration of the central cluster, PSK placement, the clusterset.local
# forward in the cluster CoreDNS, per-remote admission policies, hybrid
# namespace label, the policy Applications, and subctl (when installed).
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
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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
if [[ -z "$gw_pod" ]]; then
  fail "gateway node policy routing" "no running gateway pod"
else
  rules="$(kc -n "$OPERATOR_NS" exec "$gw_pod" -c submariner-gateway -- sh -c 'ip rule show | grep -c "lookup 150"; ip route show table 150 | grep -c .' 2>/dev/null | tr '\n' ' ')"
  read -r rule_count route_count <<<"$rules"
  if [[ "${rule_count:-0}" -ge 1 && "${route_count:-0}" -ge 1 ]]; then
    pass "gateway node policy routing" "rule lookup 150, ${route_count} routes in table 150"
  else
    fail "gateway node policy routing" "rule or table 150 missing on the gateway node; kubectl -n ${OPERATOR_NS} delete pod -l app=submariner-routeagent --field-selector spec.nodeName=<gateway node>"
  fi
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
  && pass "PSK in the operator namespace" || fail "PSK in the operator namespace" "secret submariner-ipsec-psk missing"
kc -n "$BROKER_NS" get secret submariner-ipsec-psk >/dev/null 2>&1 \
  && fail "PSK absent from the broker namespace" "legacy copy still present; re-sync the broker Application" \
  || pass "PSK absent from the broker namespace"
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
for app in "netpol-${FEDERATION_NS}-hybrid" netpol-remote-clusters "${FEDERATION_NS}-submariner-network-policy" submariner-broker submariner-operator; do
  st="$(kc -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  if [[ "$st" == "Synced/Healthy" ]]; then
    pass "Application ${app}" "$st"
  else
    warn "Application ${app}" "${st:-not found}"
  fi
done

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
