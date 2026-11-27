#!/usr/bin/env bash
# Health checks of the central cluster before a remote node joins. Nothing is written: the checks read, and
# the admission checks are server-side dry runs.
#
# Run with a kubectl context that reads the central cluster. Prints one PASS,
# WARN or FAIL line per check and exits non-zero when a check fails.
#
# Checks: gateway node label, gateway DaemonSet and Gateway object, gateway node
# policy routing against the remote CIDRs, gateway connections, the networkd
# drop-in and route watchdog DaemonSets, the route watchdog's admission policy
# and rights, leftover uninstall DaemonSets, Calico
# API server and IP pools, Calico tiers, the broker registration of the central
# cluster, PSK and broker credentials, no Secrets in the broker namespace, the
# clusterset.local forward in the cluster CoreDNS, the Lighthouse export
# records and the published address of every ServiceExport of the federation,
# per-remote admission policies, the enrollment record of every remote account,
# what each remote cluster publishes on the broker against its record, the
# admission policies as the API server applies them to every enrolled account
# (verify-enrollment.sh, impersonating the account), the federation's
# NetworkPolicies, the remote-clusters tier (the federation's policy passes its
# remote networks only to the namespace of FEDERATION_NS and there only to the
# aggregation server, every connected remote network is denied elsewhere, the
# tier ends with a Pass), the policy Applications, the API server egress pins
# of the network-policy charts (apiServer.cidrs), and subctl (when installed).
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
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
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
# Gateway LoadBalancer. The assigned address must equal the one pinned in the Submariner resource
# (common/submariner/operator/kustomization.yaml), the only IPsec peer remote nodes accept. The Service
# must serve UDP 4500 (IPsec NAT-T) and 4490 (NAT discovery).
want_vip="$(kc -n "$OPERATOR_NS" get submariner submariner -o jsonpath='{.spec.loadBalancerServiceAnnotations.metallb\.io/loadBalancerIPs}' 2>/dev/null)"
lb="$(kc -n "$OPERATOR_NS" get svc submariner-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
lb_ports="$(kc -n "$OPERATOR_NS" get svc submariner-gateway -o jsonpath='{range .spec.ports[*]}{.port}/{.protocol}{" "}{end}' 2>/dev/null)"
if [[ -z "$lb" ]]; then
  fail "gateway LoadBalancer address" "none assigned"
elif [[ -z "$want_vip" ]]; then
  warn "gateway LoadBalancer address" "${lb}, not pinned through the Submariner resource (loadBalancerServiceAnnotations)"
elif [[ "$lb" != "$want_vip" ]]; then
  fail "gateway LoadBalancer address" "${lb}, pinned ${want_vip}; remote nodes accept IPsec only from the pinned address"
else
  pass "gateway LoadBalancer address" "${lb} (pinned)"
fi
if [[ " ${lb_ports} " == *" 4500/UDP "* && " ${lb_ports} " == *" 4490/UDP "* ]]; then
  pass "gateway LoadBalancer ports" "$lb_ports"
else
  fail "gateway LoadBalancer ports" "${lb_ports:-none}; UDP 4500 and 4490 are needed"
fi

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
# Route watchdog: ready and off the host network, its admission policy in place, and its account may
# restart the route agent (deletecollection) but not list pods.
wd_sa="system:serviceaccount:${OPERATOR_NS}:submariner-gateway-route-watchdog"
wd="$(kc -n "$OPERATOR_NS" get daemonset submariner-gateway-route-watchdog -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}' 2>/dev/null)"
wd_hostnet="$(kc -n "$OPERATOR_NS" get daemonset submariner-gateway-route-watchdog -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null)"
if [[ -z "$wd" || "${wd%/*}" != "${wd#*/}" || "${wd%/*}" == 0 ]]; then
  fail "route watchdog DaemonSet" "desired/ready ${wd:-not found}; apply submariner-rbac.yaml and sync the submariner-operator Application (common/submariner/operator/gateway-route-watchdog.yaml)"
elif [[ "$wd_hostnet" == true ]]; then
  fail "route watchdog DaemonSet" "runs on the host network (old version); sync the submariner-operator Application"
else
  restarts="$(kc -n "$OPERATOR_NS" logs ds/submariner-gateway-route-watchdog --since=168h 2>/dev/null | grep -c 'restarted the route agent')"
  pass "route watchdog DaemonSet" "desired/ready ${wd}, route agent restarts in the last 7 days: ${restarts:-0}"
fi
if kc get validatingadmissionpolicy submariner-gateway-route-watchdog >/dev/null 2>&1 \
  && kc get validatingadmissionpolicybinding submariner-gateway-route-watchdog >/dev/null 2>&1; then
  pass "route watchdog admission policy" "policy and binding present"
else
  fail "route watchdog admission policy" "missing: the watchdog could delete every pod in ${OPERATOR_NS}; apply base/mip-infrastructure/rbac/submariner-rbac.yaml"
fi
can_list="$(kc auth can-i list pods -n "$OPERATOR_NS" --as="$wd_sa" 2>/dev/null)"
can_purge="$(kc auth can-i deletecollection pods -n "$OPERATOR_NS" --as="$wd_sa" 2>/dev/null)"
if [[ "$can_list" == no && "$can_purge" == yes ]]; then
  pass "route watchdog rights" "deletecollection pods, no list"
elif [[ -z "$can_list" || -z "$can_purge" ]]; then
  warn "route watchdog rights" "not checked: the current context may not impersonate ${wd_sa}"
else
  fail "route watchdog rights" "list pods: ${can_list}, deletecollection pods: ${can_purge}; apply base/mip-infrastructure/rbac/submariner-rbac.yaml"
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

# --- service discovery ------------------------------------------------------------------------------------------
# The Lighthouse agent keeps one ServiceImport per exported service in its namespace, named
# <service>-<namespace>-<cluster ID>. It also uses any other ServiceImport there that carries the cluster ID as
# an export record, and the record it processes last decides the published address. A leftover record can
# therefore publish an address the Service no longer has.
records="$(kc -n "$OPERATOR_NS" get serviceimports.multicluster.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
extra_records=""
for r in $records; do
  [[ "$r" == *"-${local_id}" ]] || extra_records="${extra_records} ${r}"
done
if [[ -z "$local_id" ]]; then
  warn "Lighthouse export records" "cluster ID unknown, not checked"
elif [[ -z "$extra_records" ]]; then
  pass "Lighthouse export records" "$(wc -w <<<"$records" | tr -d ' ') in ${OPERATOR_NS}, all named after ${local_id}"
else
  fail "Lighthouse export records" "unexpected in ${OPERATOR_NS}:${extra_records}; delete them, then delete the agent pod, which otherwise keeps the export withdrawn (kubectl -n ${OPERATOR_NS} delete pod -l app=submariner-lighthouse-agent)"
fi
# Every ServiceExport of the federation must be published (Ready), and a ClusterIP Service must be published
# with the address it has now. Remote nodes resolve the clusterset name to the published address.
exports="$(kc -n "$FEDERATION_NS" get serviceexports.multicluster.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.name}={range .status.conditions[?(@.type=="Ready")]}{.status}{end}{" "}{end}' 2>/dev/null)"
if [[ -z "${exports// /}" ]]; then
  warn "ServiceExports of ${FEDERATION_NS}" "none found (Application ${FEDERATION_NS}-submariner-network-policy)"
else
  export_issues=""
  for e in $exports; do
    name="${e%%=*}"
    if [[ "$e" != *"=True" ]]; then
      export_issues="${export_issues} ${name}(not Ready)"
      continue
    fi
    svc_ip="$(kc -n "$FEDERATION_NS" get svc "$name" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    published="$(kc -n "$FEDERATION_NS" get endpointslices -l "multicluster.kubernetes.io/service-name=${name},multicluster.kubernetes.io/source-cluster=${local_id}" -o jsonpath='{range .items[*]}{.endpoints[*].addresses[*]}{" "}{end}' 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
    # Headless Services (clusterIP None) publish pod addresses, which are not compared.
    if [[ -n "$svc_ip" && "$svc_ip" != None && "$published" != "$svc_ip" ]]; then
      export_issues="${export_issues} ${name}(Service ${svc_ip}, published ${published:-nothing})"
    fi
  done
  if [[ -z "$export_issues" ]]; then
    pass "ServiceExports of ${FEDERATION_NS}" "${exports% } published with the Services' addresses"
  else
    fail "ServiceExports of ${FEDERATION_NS}" "${export_issues# }; check the Lighthouse export records above and kubectl -n ${OPERATOR_NS} logs deploy/submariner-lighthouse-agent"
  fi
  # No remote component needs the controller: its API is closed to remote nodes. Argo CD does not prune, so
  # a ServiceExport of the controller stays until deleted by hand.
  if [[ " $exports" == *" exaflow-controller-service="* ]]; then
    warn "ServiceExport exaflow-controller-service" "no longer needed; kubectl -n ${FEDERATION_NS} delete serviceexports.multicluster.x-k8s.io exaflow-controller-service"
  fi
fi

# --- per-remote identities -------------------------------------------------------------------------------------
kc -n "$BROKER_NS" get role submariner-remote-cluster >/dev/null 2>&1 \
  && pass "Role submariner-remote-cluster" || fail "Role submariner-remote-cluster" "apply base/mip-infrastructure/rbac/submariner-remote-admission.yaml"
for p in submariner-remote-cluster-ownership submariner-remote-cluster-subnets submariner-remote-cluster-exports; do
  if kc get validatingadmissionpolicy "$p" >/dev/null 2>&1 && kc get validatingadmissionpolicybinding "$p" >/dev/null 2>&1; then
    pass "admission policy ${p#submariner-remote-cluster-}" "policy and binding present"
  else
    fail "admission policy ${p#submariner-remote-cluster-}" "missing; apply submariner-remote-admission.yaml"
  fi
done
enrolled="$(kc -n "$BROKER_NS" get serviceaccounts -l submariner.io/remote-enrollment=true -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
[[ -n "${enrolled// /}" ]] && pass "enrolled remote accounts" "$enrolled" || warn "enrolled remote accounts" "none (enroll-remote.sh)"
# Enrollment records: ConfigMap cluster-<id>, the parameter of the subnet and export policies. An account
# without a record is not restricted by the export policy while other records exist. A record without an
# exports entry lets the cluster publish nothing.
records="$(kc -n "$BROKER_NS" get configmaps -l submariner.io/remote-enrollment=true -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.data.exports}{"\n"}{end}' 2>/dev/null | tr -d ' \t')"
record_exports() { awk -F= -v n="$1" '$1 == n {print $2}' <<<"$records"; } # $1 ConfigMap name
no_record=""
no_exports=""
record_list=""
for sa in $enrolled; do
  if ! grep -q "^${sa}=" <<<"$records"; then
    no_record="${no_record} ${sa}"
  elif [[ -z "$(record_exports "$sa")" ]]; then
    no_exports="${no_exports} ${sa}"
  else
    record_list="${record_list} ${sa}=[$(record_exports "$sa")]"
  fi
done
if [[ -n "${enrolled// /}" ]]; then
  if [[ -n "$no_record" ]]; then
    fail "enrollment records" "no ConfigMap labelled submariner.io/remote-enrollment=true for:${no_record}; the export and subnet policies do not restrict these accounts. Re-run enroll-remote.sh CLUSTER_ID=<id> with the node's SUBNETS and EXPORTS, or revoke the account"
  elif [[ -n "$no_exports" ]]; then
    warn "enrollment records" "no export recorded for:${no_exports}; the broker refuses every service these clusters publish. kubectl -n ${BROKER_NS} patch configmap <name> --type merge -p '{\"data\":{\"exports\":\"<namespace>/<service>\"}}'"
  else
    pass "enrollment records" "${record_list# }"
  fi
fi
# What each remote cluster publishes on the broker must be within its record: the EndpointSlices and the
# per-cluster ServiceImports labelled with its ID, and the aggregated ServiceImports that list it. The export
# policy refuses any other create or update; this check also finds objects written before the policy existed.
published="$(
  kc -n "$BROKER_NS" get endpointslices.discovery.k8s.io -o jsonpath='{range .items[*]}{.metadata.labels.multicluster\.kubernetes\.io/source-cluster}{" "}{.metadata.labels.lighthouse\.submariner\.io/sourceNamespace}{"/"}{.metadata.labels.multicluster\.kubernetes\.io/service-name}{" EndpointSlice/"}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk 'NF == 3'
  kc -n "$BROKER_NS" get serviceimports.multicluster.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.labels.multicluster\.kubernetes\.io/source-cluster}{" "}{.metadata.labels.lighthouse\.submariner\.io/sourceNamespace}{"/"}{.metadata.labels.multicluster\.kubernetes\.io/service-name}{" ServiceImport/"}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk 'NF == 3'
  kc -n "$BROKER_NS" get serviceimports.multicluster.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.annotations.lighthouse\.submariner\.io/sourceNamespace}{"/"}{.metadata.annotations.multicluster\.kubernetes\.io/service-name}{" ServiceImport/"}{.metadata.name}{" "}{.status.clusters[*].cluster}{"\n"}{end}' 2>/dev/null \
    | awk '$1 != "/" {for (i = 3; i <= NF; i++) print $i, $1, $2}'
)"
outside=""
remote_objects=0
while read -r cluster export object; do
  [[ -n "$cluster" && "$cluster" != "$local_id" ]] || continue
  remote_objects=$((remote_objects + 1))
  if [[ "$export" == /* || "$export" == */ ]]; then
    outside="${outside} ${object} of ${cluster} carries no service name or source namespace;"
  elif [[ ",$(record_exports "cluster-${cluster}")," != *",${export},"* ]]; then
    outside="${outside} ${object} of ${cluster} publishes ${export};"
  fi
done <<<"$published"
if [[ -z "$local_id" ]]; then
  warn "published exports within the records" "cluster ID unknown, not checked"
elif [[ -n "$outside" ]]; then
  fail "published exports within the records" "${outside# } the export policy refuses every update of these objects. If the cluster may publish the service, add it to the exports of its record (ConfigMap cluster-<id> in ${BROKER_NS}); otherwise delete the object"
else
  pass "published exports within the records" "${remote_objects} broker objects of remote clusters"
fi
# The policies as the API server applies them now. verify-enrollment.sh impersonates each enrolled account and
# sends server-side dry runs: objects within the record must be admitted, anything else refused. A failure
# with a correct record means the API server does not see the record (note on parameter ConfigMaps in
# submariner-remote-admission.yaml).
verify="$(dirname "$0")/verify-enrollment.sh"
for sa in $enrolled; do
  grep -q "^${sa}=" <<<"$records" || continue
  out="$(env -u SUBNETS -u EXPORTS -u OUT_DIR -u TOKEN_FILE -u CA_FILE "$verify" CLUSTER_ID="${sa#cluster-}" IMPERSONATE=true BROKER_NS="$BROKER_NS" 2>&1)"
  if grep -q '^RESULT: all checks passed' <<<"$out"; then
    pass "admission checks for ${sa}" "$(grep -c '^PASS' <<<"$out") passed"
  elif grep -q 'cannot impersonate' <<<"$out"; then
    warn "admission checks for ${sa}" "not run: the current context may not impersonate the account"
  else
    reason="$(grep -m1 '^FAIL' <<<"$out" | sed 's/^FAIL *//' | tr -s ' ' | cut -c1-180)"
    [[ -n "$reason" ]] || reason="verify-enrollment.sh ended without a result, last line: $(sed '/^$/d' <<<"$out" | tail -n1 | cut -c1-160)"
    fail "admission checks for ${sa}" "${reason}; details: ./verify-enrollment.sh CLUSTER_ID=${sa#cluster-} IMPERSONATE=true"
  fi
done

# --- federation namespace and policies -------------------------------------------------------------------------
pols="$(kc -n "$FEDERATION_NS" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
for want in federation-default-deny controller-to-remote-workers remote-workers-to-aggregation-server; do
  [[ " $pols " == *" $want "* ]] && pass "NetworkPolicy ${want}" || fail "NetworkPolicy ${want}" "missing in ${FEDERATION_NS}"
done
[[ " $pols " == *" allow-submariner-cidrs "* ]] && warn "NetworkPolicy allow-submariner-cidrs" "obsolete all-ports policy still present; delete it"
# Remote nodes do not reach the controller's HTTP API or the Flower server. Argo CD does not prune, so a
# NetworkPolicy that admits them stays until deleted by hand. The tier check below shows whether it still has
# an effect.
for old in remote-workers-to-controller remote-workers-to-flower-server; do
  [[ " $pols " == *" $old "* ]] && warn "NetworkPolicy ${old}" "obsolete: remote nodes do not reach this component; kubectl -n ${FEDERATION_NS} delete networkpolicy ${old}"
done
# Tier remote-clusters. Each hybrid federation has one policy in it, remote-clusters.<namespace> (chart
# common/security/remote-networks): Pass rules that name the namespace (kubernetes.io/metadata.name) and list
# the federation's remote pod CIDRs, then in each direction a Deny of all its remote networks. The tier ends
# with remote-clusters.pass-other-traffic.
cidr_set() { tr -d '[]"' | tr ', ' '\n' | sed '/^$/d' | sort -u | paste -sd, -; } # list or JSON array -> sorted set
tier_policies="$(kc get globalnetworkpolicies.projectcalico.org -o jsonpath='{range .items[?(@.spec.tier=="remote-clusters")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [[ -z "${tier_policies// /}" ]]; then
  warn "policies of the tier remote-clusters" "none found (Applications netpol-remote-clusters and netpol-${FEDERATION_NS}-remote)"
else
  # One line per rule of every policy of the tier: policy|direction|action|remote nets|namespaceSelector of the local side.
  tier_rules=""
  for p in $tier_policies; do
    r="$(kc get globalnetworkpolicies.projectcalico.org "$p" -o jsonpath='{range .spec.ingress[*]}{"ingress|"}{.action}{"|"}{.source.nets}{"|"}{.destination.namespaceSelector}{"\n"}{end}{range .spec.egress[*]}{"egress|"}{.action}{"|"}{.destination.nets}{"|"}{.source.namespaceSelector}{"\n"}{end}' 2>/dev/null)"
    tier_rules="${tier_rules}$(sed -e '/^$/d' -e "s/^/${p}|/" <<<"$r")"$'\n'
  done
  # Traffic that no federation policy decides must leave the tier with a Pass.
  if [[ " $tier_policies " == *" remote-clusters.pass-other-traffic "* ]]; then
    pass "end-of-tier policy pass-other-traffic"
  elif [[ "$(kc get tiers.projectcalico.org remote-clusters -o jsonpath='{.spec.defaultAction}' 2>/dev/null)" == Pass ]]; then
    warn "end-of-tier policy pass-other-traffic" "not present; only the tier's defaultAction Pass lets other traffic continue (Application netpol-remote-clusters)"
  else
    fail "end-of-tier policy pass-other-traffic" "not present and the tier's defaultAction is not Pass: traffic that matches no rule of the tier is dropped (Application netpol-remote-clusters)"
  fi
  # The federation's policy: Pass rules to this namespace only, with exactly the remote pod CIDRs the federation's
  # own NetworkPolicies allow, then the Deny.
  fed_policy="remote-clusters.${FEDERATION_NS}"
  ns_name="^[[:space:]]*kubernetes\.io/metadata\.name[[:space:]]*==[[:space:]]*[\"']([a-z0-9-]+)[\"'][[:space:]]*$"
  ns_cidrs="$(kc -n "$FEDERATION_NS" get networkpolicy controller-to-remote-workers -o jsonpath='{range .spec.egress[*].to[*]}{.ipBlock.cidr}{" "}{end}' 2>/dev/null | cidr_set)"
  fed_rules="$(awk -F'|' -v p="$fed_policy" '$1 == p' <<<"$tier_rules" | cut -d'|' -f2-)"
  problems=""
  for dir in ingress egress; do
    lines="$(grep "^${dir}|" <<<"$fed_rules")"
    n="$(sed '/^$/d' <<<"$lines" | wc -l | tr -d ' ')"
    if (( n < 2 )); then
      problems="${problems} ${dir}: Pass rules and the final Deny expected, ${n} rule(s) found;"
      continue
    fi
    i=0
    while IFS='|' read -r _ action nets sel; do
      i=$((i + 1))
      if (( i == n )); then
        [[ "$action" == Deny && -n "$nets" && -z "$sel" ]] || problems="${problems} ${dir}: the last rule is not the Deny of the federation's networks;"
      elif [[ "$action" != Pass || -z "$nets" ]] || ! [[ "$sel" =~ $ns_name && "${BASH_REMATCH[1]}" == "$FEDERATION_NS" ]]; then
        problems="${problems} ${dir} rule ${i} is not a Pass of remote networks to ${FEDERATION_NS} (${action}, ${sel:-no namespaceSelector});"
      elif [[ "$(cidr_set <<<"$nets")" != "$ns_cidrs" ]]; then
        problems="${problems} ${dir} rule ${i} passes [$(cidr_set <<<"$nets")];"
      fi
    done <<<"$lines"
  done
  if [[ " $tier_policies " != *" ${fed_policy} "* ]]; then
    fail "tier assigns remote networks to ${FEDERATION_NS}" "policy ${fed_policy} not found: Application netpol-${FEDERATION_NS}-remote, built from the federation's mip-infrastructure/remote-networks.yaml"
  elif [[ -z "$ns_cidrs" ]]; then
    fail "tier assigns remote networks to ${FEDERATION_NS}" "NetworkPolicy controller-to-remote-workers lists no remote CIDR to compare with"
  elif [[ -n "$problems" ]]; then
    fail "tier assigns remote networks to ${FEDERATION_NS}" "${fed_policy}:${problems} the NetworkPolicies of ${FEDERATION_NS} allow [${ns_cidrs}]; remote-networks.yaml and submariner-policies/network-policy.yaml must agree"
  else
    pass "tier assigns remote networks to ${FEDERATION_NS}" "${ns_cidrs} (${fed_policy})"
  fi
  # Remote networks are passed to one component of the federation, the aggregation server. A Pass rule to
  # anything else opens it to the remote nodes without a login; for the controller that means its whole API
  # (list datasets, start computations).
  other_targets="$(kc get globalnetworkpolicies.projectcalico.org "$fed_policy" -o jsonpath='{range .spec.ingress[?(@.action=="Pass")]}{.destination.selector}{" ports "}{.destination.ports}{"\n"}{end}' 2>/dev/null | grep -v "exaflow-aggregation-server" | sed '/^ ports $/d' | paste -sd';' -)"
  if [[ " $tier_policies " != *" ${fed_policy} "* ]]; then
    : # reported above
  elif [[ -z "$other_targets" ]]; then
    pass "remote nodes reach only the aggregation server" "${fed_policy} passes no other component"
  else
    fail "remote nodes reach only the aggregation server" "${fed_policy} also passes remote networks to: ${other_targets}; sync Application netpol-${FEDERATION_NS}-remote (chart common/security/remote-networks)"
  fi
  # The networks of every remote cluster this gateway knows must be in a Deny rule of the tier, in both directions;
  # one that is missing reaches every namespace that has no policies of its own.
  unconfined=""
  for dir in ingress egress; do
    denied="$(awk -F'|' -v d="$dir" '$2 == d && $3 == "Deny" {print $4}' <<<"$tier_rules" | cidr_set)"
    for c in $remote_cidrs; do
      [[ ",${denied}," == *",${c},"* ]] || unconfined="${unconfined} ${c}(${dir})"
    done
  done
  if [[ -z "$remote_cidrs" ]]; then
    warn "tier confines the remote networks" "no remote Endpoint known to this cluster, nothing to compare"
  elif [[ -z "$unconfined" ]]; then
    pass "tier confines the remote networks" "$(wc -w <<<"$remote_cidrs" | tr -d ' ') remote CIDRs denied in both directions"
  else
    fail "tier confines the remote networks" "in no Deny rule of the tier:${unconfined}; add the node's networks to its federation's remote-networks.yaml"
  fi
  # The former shared policy has a lower order: while it exists, it decides first.
  if [[ " $tier_policies " == *" remote-clusters.confine-remote-clusters "* ]]; then
    warn "obsolete policy confine-remote-clusters" "still present; it is evaluated first, so the federation policies have no effect. Once the checks above pass: kubectl delete globalnetworkpolicies.projectcalico.org remote-clusters.confine-remote-clusters"
  fi
fi
for app in "netpol-${FEDERATION_NS}-hybrid" netpol-remote-clusters "netpol-${FEDERATION_NS}-remote" "${FEDERATION_NS}-submariner-network-policy" submariner-operator; do
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
