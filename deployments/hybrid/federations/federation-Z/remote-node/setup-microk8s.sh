#!/usr/bin/env bash
# Installs single-node MicroK8s with the pod and service CIDRs of this remote
# node, installs the Calico API server that Submariner needs to manage IP
# pools, pins Calico's node IP detection and MicroK8s' certificate handling so
# that the Submariner tunnel interface does not disturb them, installs the
# watchdog that restores the gateway's policy routing, limits IPsec to the
# central gateway's LoadBalancer address, and labels the node as the Submariner
# gateway.
#
# Usage:
#   sudo ./setup-microk8s.sh
#   sudo MICROK8S_CHANNEL=1.33/stable IPv4_CLUSTER_CIDR=10.3.0.0/16 \
#        IPv4_SERVICE_CIDR=10.152.185.0/24 ./setup-microk8s.sh
#
# Parameters (environment variables):
#   MICROK8S_CHANNEL   snap channel, default 1.33/stable
#   IPv4_CLUSTER_CIDR  pod CIDR, default 10.3.0.0/16; must not overlap the central cluster
#   IPv4_SERVICE_CIDR  service CIDR, default 10.152.185.0/24
#   CALICO_VERSION     Calico API server manifest version; default: detected from calico-node
#   CALICO_APISERVER   install the Calico API server, default true
#   CALICO_IP_AUTODETECTION  Calico IP_AUTODETECTION_METHOD, default kubernetes-internal-ip
#   LABEL_GATEWAY      label this node submariner.io/gateway=true, default true
#   CENTRAL_GATEWAY_IP central gateway LoadBalancer address, the only IPsec peer; default from central.env
#   WAIT_TIMEOUT       seconds to wait for MicroK8s readiness, default 600
#
# Re-running is safe. When MicroK8s is already installed the script verifies the
# channel and the live CIDRs instead of reinstalling. CIDRs cannot change after
# installation without `snap remove --purge microk8s`.
set -euo pipefail

MICROK8S_CHANNEL="${MICROK8S_CHANNEL:-1.33/stable}"
IPv4_CLUSTER_CIDR="${IPv4_CLUSTER_CIDR:-10.3.0.0/16}"
IPv4_SERVICE_CIDR="${IPv4_SERVICE_CIDR:-10.152.185.0/24}"
CALICO_VERSION="${CALICO_VERSION:-}"
CALICO_APISERVER="${CALICO_APISERVER:-true}"
CALICO_IP_AUTODETECTION="${CALICO_IP_AUTODETECTION:-kubernetes-internal-ip}"
LABEL_GATEWAY="${LABEL_GATEWAY:-true}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENTRAL_GATEWAY_IP="${CENTRAL_GATEWAY_IP:-$(sed -n 's/^CENTRAL_GATEWAY_IP=//p' "${here}/central.env" 2>/dev/null | head -1)}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
LAUNCH_CONFIG=/var/snap/microk8s/common/.microk8s.yaml
CNI_MANIFEST=/var/snap/microk8s/current/args/cni-network/cni.yaml
NO_REISSUE_LOCK=/var/snap/microk8s/current/var/lock/no-cert-reissue

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
k() { microk8s.kubectl "$@"; }

# Waits until a namespaced resource exists (rollout status needs it to exist).
wait_for() {
  local ns="$1" res="$2"
  for _ in $(seq 1 60); do
    k -n "$ns" get "$res" >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "${res} not found in namespace ${ns} after 5 minutes"
}

# A separately installed kubectl snap shadows the MicroK8s alias and lags the
# server version; MicroK8s provides kubectl and helm.
for s in kubectl helm; do
  if snap list "$s" >/dev/null 2>&1; then
    die "the ${s} snap is installed; remove it first (snap remove --purge ${s}), MicroK8s provides ${s}"
  fi
done

# --- CIDR validation ---------------------------------------------------------
[[ "$CENTRAL_GATEWAY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || die "CENTRAL_GATEWAY_IP '${CENTRAL_GATEWAY_IP}' is not an IPv4 address; set it in ${here}/central.env"
service_api_ip="$(python3 - "$IPv4_CLUSTER_CIDR" "$IPv4_SERVICE_CIDR" <<'PY'
import ipaddress
import sys

pod = ipaddress.ip_network(sys.argv[1], strict=True)
svc = ipaddress.ip_network(sys.argv[2], strict=True)
if pod.overlaps(svc):
    sys.exit("pod and service CIDRs overlap")
print(next(svc.hosts()))
PY
)" || die "invalid CIDRs: IPv4_CLUSTER_CIDR=${IPv4_CLUSTER_CIDR} IPv4_SERVICE_CIDR=${IPv4_SERVICE_CIDR}"
log "Pod CIDR ${IPv4_CLUSTER_CIDR}, service CIDR ${IPv4_SERVICE_CIDR}, API service IP ${service_api_ip}"

# --- install or verify -------------------------------------------------------
if snap list microk8s >/dev/null 2>&1; then
  tracking="$(snap list microk8s | awk 'NR==2 {print $4}')"
  log "MicroK8s already installed (channel ${tracking}); verifying configuration"
  [[ "$tracking" == "$MICROK8S_CHANNEL" ]] \
    || die "installed channel ${tracking} differs from MICROK8S_CHANNEL=${MICROK8S_CHANNEL}; remove with 'snap remove --purge microk8s' to reinstall"
  microk8s status --wait-ready --timeout "$WAIT_TIMEOUT" >/dev/null
  live_api_ip="$(k get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
  [[ "$live_api_ip" == "$service_api_ip" ]] \
    || die "live kubernetes service IP ${live_api_ip} does not match IPv4_SERVICE_CIDR=${IPv4_SERVICE_CIDR}"
  live_pod_cidr="$(k get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr}')"
  [[ "$live_pod_cidr" == "$IPv4_CLUSTER_CIDR" ]] \
    || die "live pod CIDR ${live_pod_cidr} does not match IPv4_CLUSTER_CIDR=${IPv4_CLUSTER_CIDR}"
else
  log "Writing the MicroK8s launch configuration to ${LAUNCH_CONFIG}"
  mkdir -p "$(dirname "$LAUNCH_CONFIG")"
  cat >"$LAUNCH_CONFIG" <<EOF
---
version: 0.2.0
extraCNIEnv:
  IPv4_CLUSTER_CIDR: "${IPv4_CLUSTER_CIDR}"
  IPv4_SERVICE_CIDR: "${IPv4_SERVICE_CIDR}"
extraSANs:
  - ${service_api_ip}
addons:
  - name: dns
EOF
  log "Installing MicroK8s from channel ${MICROK8S_CHANNEL}"
  snap install microk8s --classic --channel="$MICROK8S_CHANNEL"
  log "Waiting for MicroK8s to become ready"
  microk8s status --wait-ready --timeout "$WAIT_TIMEOUT" >/dev/null
fi

log "Waiting for Calico and CoreDNS"
wait_for kube-system ds/calico-node
k -n kube-system rollout status ds/calico-node --timeout=300s
wait_for kube-system deploy/coredns
k -n kube-system rollout status deploy/coredns --timeout=300s

# --- coexistence with the Submariner tunnel interface -------------------------
# At join time the route agent adds a vx-submariner interface with an address
# in 240.0.0.0/8. Calico's default autodetection (first-found) enumerates
# interfaces newest first and would move the node IP to it, and the MicroK8s
# certificate kicker treats the new address as a host IP change: it re-issues
# the API server certificate and restarts the whole control plane, CoreDNS
# included, while the Submariner pods are starting.
method="$(k -n kube-system get ds calico-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="calico-node")].env[?(@.name=="IP_AUTODETECTION_METHOD")].value}')"
if [[ "$method" != "$CALICO_IP_AUTODETECTION" ]]; then
  log "Pinning Calico IP autodetection to ${CALICO_IP_AUTODETECTION} (was ${method:-unset})"
  k -n kube-system set env ds/calico-node IP_AUTODETECTION_METHOD="$CALICO_IP_AUTODETECTION" >/dev/null
  k -n kube-system rollout status ds/calico-node --timeout=300s
fi
# Keep the manifest MicroK8s re-applies after a reset in line with the live setting.
if [[ -f "$CNI_MANIFEST" ]] && grep -q 'name: IP_AUTODETECTION_METHOD' "$CNI_MANIFEST"; then
  sed -i "/name: IP_AUTODETECTION_METHOD/{n;s|value: \".*\"|value: \"${CALICO_IP_AUTODETECTION}\"|}" "$CNI_MANIFEST"
fi
if [[ ! -e "$NO_REISSUE_LOCK" ]]; then
  log "Disabling automatic certificate re-issue on host address changes (${NO_REISSUE_LOCK})"
  touch "$NO_REISSUE_LOCK"
fi

# --- aliases, group membership, kubeconfig -----------------------------------
log "Creating the kubectl and helm aliases"
snap alias microk8s.kubectl kubectl >/dev/null 2>&1 || true
snap alias microk8s.helm3 helm >/dev/null 2>&1 || true

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  log "Adding ${SUDO_USER} to the microk8s group and writing its kubeconfig"
  usermod -a -G microk8s "$SUDO_USER"
  user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  user_group="$(id -gn "$SUDO_USER")"
  install -d -m 0700 -o "$SUDO_USER" -g "$user_group" "$user_home/.kube"
  microk8s config >"$user_home/.kube/config"
  chown "$SUDO_USER:$user_group" "$user_home/.kube/config"
  chmod 0600 "$user_home/.kube/config"
fi

# --- Calico API server -------------------------------------------------------
# Submariner's route agent creates Calico IP pools for the remote CIDRs through
# the projectcalico.org/v3 API, which MicroK8s does not ship.
if [[ "$CALICO_APISERVER" == true ]]; then
  if [[ -z "$CALICO_VERSION" ]]; then
    CALICO_VERSION="$(k -n kube-system get ds calico-node \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="calico-node")].image}' \
      | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"
  fi
  [[ -n "$CALICO_VERSION" ]] || die "could not detect the Calico version; set CALICO_VERSION"
  manifest="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/apiserver.yaml"
  log "Installing the Calico API server ${CALICO_VERSION}"
  curl -fsSI --max-time 20 "$manifest" >/dev/null || die "manifest not found: ${manifest}"
  k apply -f "$manifest"

  if ! k -n calico-apiserver get secret calico-apiserver-certs >/dev/null 2>&1; then
    log "Generating the Calico API server certificate (valid 365 days)"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
      -keyout "$tmp/apiserver.key" -out "$tmp/apiserver.crt" \
      -subj "/CN=calico-api.calico-apiserver.svc" \
      -addext "subjectAltName = DNS:calico-api.calico-apiserver.svc" >/dev/null 2>&1
    k -n calico-apiserver create secret generic calico-apiserver-certs \
      --from-file=apiserver.key="$tmp/apiserver.key" \
      --from-file=apiserver.crt="$tmp/apiserver.crt"
  fi

  want_ca="$(k -n calico-apiserver get secret calico-apiserver-certs -o jsonpath='{.data.apiserver\.crt}')"
  have_ca="$(k get apiservice v3.projectcalico.org -o jsonpath='{.spec.caBundle}')"
  if [[ "$want_ca" != "$have_ca" ]]; then
    log "Patching the APIService CA bundle"
    k patch apiservice v3.projectcalico.org --type=merge -p "{\"spec\":{\"caBundle\":\"${want_ca}\"}}"
  fi

  log "Waiting for the Calico API server"
  k -n calico-apiserver rollout status deploy/calico-apiserver --timeout=300s
  available=""
  for _ in $(seq 1 60); do
    available="$(k get apiservice v3.projectcalico.org \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ "$available" == True ]] && k get ippools.projectcalico.org >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  [[ "$available" == True ]] || die "APIService v3.projectcalico.org is not Available"
fi

# --- hostname stability --------------------------------------------------------
# The MicroK8s node name, the Submariner Gateway object and the Endpoint's
# hostname all derive from the host name. Cloud images let cloud-init reset it
# from the instance name at every boot, so a renamed or restored instance
# registers as a second node with the same address while the gateway pod and
# the worker stay bound to the dead node object. Pin the current name.
if [[ -d /etc/cloud/cloud.cfg.d ]] && ! grep -qs '^preserve_hostname: true' /etc/cloud/cloud.cfg.d/*.cfg; then
  printf 'preserve_hostname: true\n' >/etc/cloud/cloud.cfg.d/99-microk8s-preserve-hostname.cfg
  log "cloud-init hostname updates disabled (99-microk8s-preserve-hostname.cfg); node name stays $(hostname)"
fi

# --- systemd-networkd and foreign routes ---------------------------------------
# The Submariner route agent installs policy routing on the gateway node (rule
# "from all lookup 150" and table-150 routes to the remote CIDRs with the Calico
# address as source) so that host-originated packets, the gateway's own health
# check included, match the IPsec policies. systemd-networkd deletes routes and
# rules it does not own every time it starts, and unattended upgrades restart it
# through needrestart (openssl update, 2026-09-30); the route agent does not put
# them back and the connection degrades to "error". Keep networkd away from
# foreign routes and rules. Effective at its next start; nothing is restarted
# here. This does not cover every loss: see the route watchdog below.
networkd_dropin=/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf
networkd_dropin_want=$'[Network]\nManageForeignRoutes=no\nManageForeignRoutingPolicyRules=no'
if [[ -d /etc/systemd ]] && [[ "$(cat "$networkd_dropin" 2>/dev/null)" != "$networkd_dropin_want" ]]; then
  install -d -m 0755 /etc/systemd/networkd.conf.d
  printf '%s\n' "$networkd_dropin_want" >"$networkd_dropin"
  chmod 0644 "$networkd_dropin"
  log "systemd-networkd keeps foreign routes and rules (${networkd_dropin}); effective at its next start"
fi

# --- route watchdog ------------------------------------------------------------
# With a DHCP uplink, systemd-networkd removes the interface address and adds it
# again when it restarts, for example after an unattended upgrade. The kernel
# drops every route through an interface that loses its last address, table 150
# included, and nothing puts those routes back. The drop-in above does not
# prevent this. No KeepConfiguration value avoids it on Ubuntu 24.04 (systemd
# 255.4); dhcp-on-stop, dhcp and yes do not.
#
# Same logic as the route watchdog of the central cluster. Every
# minute it compares table 150 with the subnets of the remote Endpoints. After
# two failed checks in a row it deletes the route agent pod, and the new pod
# re-installs the rule and the routes; at most one restart per 15 minutes. It
# does nothing while the API does not answer or this node is not the active
# gateway. Log: journalctl -u submariner-route-watchdog
#
# It runs without root and without capabilities: reading the routing tables
# needs none, and its API access is the MicroK8s admin kubeconfig, which the
# MicroK8s group may read. It opens no port.
watchdog_bin=/usr/local/sbin/submariner-route-watchdog
watchdog_unit=/etc/systemd/system/submariner-route-watchdog.service
watchdog_kubeconfig=/var/snap/microk8s/current/credentials/client.config
watchdog_group="$(stat -c %G "$watchdog_kubeconfig")"
watchdog_bin_want="$(cat <<'WATCHDOG'
#!/usr/bin/env bash
# Written by setup-microk8s.sh. Restarts the Submariner route agent when the policy routing of
# this gateway node is incomplete: the rule "from all lookup 150" and one table-150 route per
# subnet of the remote Endpoints. Log: journalctl -u submariner-route-watchdog
set -u
kubectl=(/snap/microk8s/current/kubectl --kubeconfig /var/snap/microk8s/current/credentials/client.config --request-timeout=15s)
ns=submariner-operator
interval=60
needed=2
cooldown=900
bad=0
last=0
node="$(hostname | tr '[:upper:]' '[:lower:]')"
jp_subnets='{range .items[*]}{.spec.cluster_id}{" "}{.spec.subnets}{"\n"}{end}'
trap 'exit 0' TERM INT
echo "watching the policy routing of ${node}"
while :; do
  # The Gateway object is named after its node. Only the active gateway needs table 150.
  ha="$("${kubectl[@]}" -n "$ns" get gateways.submariner.io "$node" -o jsonpath='{.status.haStatus}' 2>/dev/null)"
  me="$("${kubectl[@]}" -n "$ns" get submariners.submariner.io -o jsonpath='{.items[0].spec.clusterID}' 2>/dev/null)"
  want="$("${kubectl[@]}" -n "$ns" get endpoints.submariner.io -o jsonpath="$jp_subnets" 2>/dev/null \
    | awk -v me="$me" '$1 != me {print $2}' | tr -d '[]"' | tr ',' '\n' | sed '/^$/d' | sort -u)"
  # Never restart on an API error or a passive gateway.
  if [ "$ha" != active ] || [ -z "$me" ] || [ -z "$want" ]; then
    bad=0
  else
    have="$(ip route show table 150 2>/dev/null | awk '{print $1}')"
    missing=""
    for c in $want; do
      printf '%s\n' "$have" | grep -qx "$c" || missing="${missing} ${c}"
    done
    rule=0
    ip rule show | grep -q 'lookup 150' && rule=1
    if [ "$rule" = 1 ] && [ -z "$missing" ]; then
      [ "$bad" -gt 0 ] && echo "policy routing complete again"
      bad=0
    else
      bad=$((bad + 1))
      table="$(ip route show table 150 2>/dev/null | tr '\n' ';')"
      echo "policy routing incomplete (${bad}/${needed}): rule=${rule} missing:${missing:- none}; table 150: ${table}"
      now="$(date +%s)"
      if [ "$bad" -ge "$needed" ] && [ $((now - last)) -ge "$cooldown" ]; then
        echo "restarting the route agent on ${node}"
        "${kubectl[@]}" -n "$ns" delete pod -l app=submariner-routeagent \
          --field-selector "spec.nodeName=${node}" --wait=false && last="$now"
        bad=0
      fi
    fi
  fi
  sleep "$interval" &
  wait $!
done
WATCHDOG
)"
watchdog_unit_want="[Unit]
Description=Restart the Submariner route agent when the gateway policy routing is incomplete (written by setup-microk8s.sh)
After=snap.microk8s.daemon-kubelite.service

[Service]
ExecStart=${watchdog_bin}
Restart=always
RestartSec=30
DynamicUser=yes
SupplementaryGroups=${watchdog_group}
Environment=HOME=/tmp
ProtectHome=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
CapabilityBoundingSet=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
MemoryMax=192M

[Install]
WantedBy=multi-user.target"
watchdog_changed=false
if [[ "$(cat "$watchdog_bin" 2>/dev/null)" != "$watchdog_bin_want" ]]; then
  printf '%s\n' "$watchdog_bin_want" >"$watchdog_bin"
  watchdog_changed=true
fi
chmod 0755 "$watchdog_bin"
if [[ "$(cat "$watchdog_unit" 2>/dev/null)" != "$watchdog_unit_want" ]]; then
  printf '%s\n' "$watchdog_unit_want" >"$watchdog_unit"
  chmod 0644 "$watchdog_unit"
  systemctl daemon-reload
  watchdog_changed=true
fi
systemctl -q enable submariner-route-watchdog.service
if [[ "$watchdog_changed" == true ]] || ! systemctl -q is-active submariner-route-watchdog.service; then
  systemctl restart submariner-route-watchdog.service
  log "Route watchdog running (unit submariner-route-watchdog): restarts the route agent when table 150 loses its routes"
fi

# --- IPsec with the central gateway only -------------------------------------
# Submariner connects every gateway to every other one. A remote node exchanges
# IPsec only with the central gateway: other remote nodes belong to other sites,
# and a node with a public address can establish a tunnel to a node behind NAT.
# The table drops IKE (UDP 500), NAT-T (UDP 4500) and NAT discovery (UDP 4490)
# to and from any other address, and all of them over IPv6. This includes the
# central gateway node's own address, which changes when the provider moves the
# gateway, so NAT discovery settles on the LoadBalancer address. A dedicated
# unit loads the table at boot. Ubuntu's nftables service is not used: its
# configuration flushes all other rule sets (Calico, Submariner). The hardening
# playbook adds the same restriction in UFW.
hub_dir=/etc/submariner-hub
hub_nft="${hub_dir}/firewall.nft"
hub_unit=/etc/systemd/system/submariner-hub-firewall.service
hub_nft_want="#!/usr/sbin/nft -f
# Written by setup-microk8s.sh: Submariner IPsec only with ${CENTRAL_GATEWAY_IP}.
table inet submariner_hub
delete table inet submariner_hub
table inet submariner_hub {
	chain input {
		type filter hook input priority filter - 10; policy accept;
		udp dport { 500, 4490, 4500 } ip saddr != ${CENTRAL_GATEWAY_IP} counter drop
		meta nfproto ipv6 udp dport { 500, 4490, 4500 } counter drop
	}
	chain output {
		type filter hook output priority filter - 10; policy accept;
		udp dport { 500, 4490, 4500 } ip daddr != ${CENTRAL_GATEWAY_IP} counter drop
		meta nfproto ipv6 udp dport { 500, 4490, 4500 } counter drop
	}
}"
hub_unit_want="[Unit]
Description=Submariner IPsec only with the central gateway (written by setup-microk8s.sh)
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${hub_nft}
ExecReload=/usr/sbin/nft -f ${hub_nft}
ExecStop=/usr/sbin/nft delete table inet submariner_hub

[Install]
WantedBy=sysinit.target"
command -v nft >/dev/null 2>&1 || die "nft not found; run setup-tools.sh (package nftables)"
hub_changed=false
install -d -m 0755 "$hub_dir"
if [[ "$(cat "$hub_nft" 2>/dev/null)" != "$hub_nft_want" ]]; then
  printf '%s\n' "$hub_nft_want" >"$hub_nft"
  chmod 0644 "$hub_nft"
  hub_changed=true
fi
nft -c -f "$hub_nft" || die "nft rejected ${hub_nft}"
if [[ "$(cat "$hub_unit" 2>/dev/null)" != "$hub_unit_want" ]]; then
  printf '%s\n' "$hub_unit_want" >"$hub_unit"
  chmod 0644 "$hub_unit"
  systemctl daemon-reload
  hub_changed=true
fi
systemctl -q enable submariner-hub-firewall.service
if [[ "$hub_changed" == true ]] || ! systemctl -q is-active submariner-hub-firewall.service; then
  systemctl restart submariner-hub-firewall.service
  log "IPsec limited to the central gateway ${CENTRAL_GATEWAY_IP} (table inet submariner_hub, unit submariner-hub-firewall)"
  # A joined node keeps the address its gateway discovered, possibly the central gateway node's
  # own address, now refused. A new gateway pod runs NAT discovery again and settles on the
  # LoadBalancer address; the tunnel is down for about a minute.
  if k -n submariner-operator get pods -l app=submariner-gateway -o name 2>/dev/null | grep -q .; then
    log "Recreating the Submariner gateway pod so that it reconnects through ${CENTRAL_GATEWAY_IP}"
    k -n submariner-operator delete pod -l app=submariner-gateway --wait=false >/dev/null
  fi
fi

# --- gateway label -----------------------------------------------------------
node_name="$(k get nodes -o jsonpath='{.items[0].metadata.name}')"
if [[ "$LABEL_GATEWAY" == true ]]; then
  log "Labelling node ${node_name} as the Submariner gateway"
  k label node "$node_name" submariner.io/gateway=true --overwrite >/dev/null
fi

# --- summary -----------------------------------------------------------------
cat <<EOF

MicroK8s is ready.
  Kubernetes:    $(k version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo unknown)
  Node:          ${node_name}
  Pod CIDR:      ${IPv4_CLUSTER_CIDR}
  Service CIDR:  ${IPv4_SERVICE_CIDR}
  IPsec peer:    ${CENTRAL_GATEWAY_IP} only
  Route watchdog: $(systemctl is-active submariner-route-watchdog.service 2>/dev/null || echo inactive)
  Calico:        ${CALICO_VERSION:-not installed}
  Helm:          $(microk8s.helm3 version --short 2>/dev/null || echo unavailable)

Next, as ${SUDO_USER:-your user}:
  newgrp microk8s        # or log out and back in to activate the group
  kubectl get nodes
EOF
