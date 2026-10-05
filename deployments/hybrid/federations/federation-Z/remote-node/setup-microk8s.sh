#!/usr/bin/env bash
# Installs single-node MicroK8s with the pod and service CIDRs of this remote
# node, installs the Calico API server that Submariner needs to manage IP
# pools, pins Calico's node IP detection and MicroK8s' certificate handling so
# that the Submariner tunnel interface does not disturb them, and labels the
# node as the Submariner gateway.
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
# foreign routes. Effective at its next start; nothing is restarted here.
networkd_dropin=/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf
networkd_dropin_want=$'[Network]\nManageForeignRoutes=no\nManageForeignRoutingPolicyRules=no'
if [[ -d /etc/systemd ]] && [[ "$(cat "$networkd_dropin" 2>/dev/null)" != "$networkd_dropin_want" ]]; then
  install -d -m 0755 /etc/systemd/networkd.conf.d
  printf '%s\n' "$networkd_dropin_want" >"$networkd_dropin"
  chmod 0644 "$networkd_dropin"
  log "systemd-networkd keeps foreign routes and rules (${networkd_dropin}); effective at its next start"
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
  Calico:        ${CALICO_VERSION:-not installed}
  Helm:          $(microk8s.helm3 version --short 2>/dev/null || echo unavailable)

Next, as ${SUDO_USER:-your user}:
  newgrp microk8s        # or log out and back in to activate the group
  kubectl get nodes
EOF
