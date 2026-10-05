#!/usr/bin/env bash
# Pre-flight checks for a federation-Z remote node.
#
#   ./preflight.sh                 install stage: OS, resources, egress, broker
#                                  reachability, kernel modules, CIDR overlap
#   ./preflight.sh --stage join    join stage: credential files, broker TLS and
#                                  token, MicroK8s settings, gateway label, tool versions
#
# Prints one line per check (PASS, WARN or FAIL) and exits non-zero when any
# check fails. Run as the user who will run join-submariner.sh.
#
# Parameters (environment variables, all optional):
#   BROKER_SERVER         host:port of the broker API; default from submariner-values.yaml
#   CENTRAL_GATEWAY_IP    public IP of the central gateway, used for a route check only
#   CENTRAL_POD_CIDR      default 10.42.0.0/16
#   CENTRAL_SERVICE_CIDR  default 10.43.0.0/16
#   IPv4_CLUSTER_CIDR     default 10.3.0.0/16
#   IPv4_SERVICE_CIDR     default 10.152.185.0/24
#   SUBMARINER_VERSION    default 0.24.1
#   CREDENTIALS_DIR       default: current directory (join stage)
# shellcheck disable=SC2015
set -uo pipefail

STAGE=install
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$STAGE" in
  install|join) ;;
  *) echo "--stage must be install or join" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
values_file="${here}/submariner-values.yaml"
BROKER_SERVER="${BROKER_SERVER:-$(sed -n 's/^  server:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$values_file" 2>/dev/null | head -1)}"
BROKER_HOST="${BROKER_SERVER%%:*}"
CENTRAL_GATEWAY_IP="${CENTRAL_GATEWAY_IP:-}"
CENTRAL_POD_CIDR="${CENTRAL_POD_CIDR:-10.42.0.0/16}"
CENTRAL_SERVICE_CIDR="${CENTRAL_SERVICE_CIDR:-10.43.0.0/16}"
IPv4_CLUSTER_CIDR="${IPv4_CLUSTER_CIDR:-10.3.0.0/16}"
IPv4_SERVICE_CIDR="${IPv4_SERVICE_CIDR:-10.152.185.0/24}"
SUBMARINER_VERSION="${SUBMARINER_VERSION:-0.24.1}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$PWD}"
BROKER_SA_PREFIX=system:serviceaccount:submariner-k8s-broker:cluster-

fails=0
warns=0
pass() { printf 'PASS  %-40s %s\n' "$1" "${2:-}"; }
warn() { printf 'WARN  %-40s %s\n' "$1" "${2:-}"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %-40s %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }
http_code() { curl -sSk --max-time 8 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

[[ -n "$BROKER_SERVER" ]] || { echo "BROKER_SERVER is empty and could not be read from ${values_file}" >&2; exit 2; }
echo "Stage: ${STAGE}    Broker: ${BROKER_SERVER}"
echo

check_broker() {
  local ips code
  ips="$(getent ahostsv4 "$BROKER_HOST" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
  [[ -n "$ips" ]] && pass "broker host resolves" "$ips" || fail "broker host resolves" "$BROKER_HOST"
  code="$(http_code "https://${BROKER_SERVER}/version")"
  case "$code" in
    200|401|403) pass "broker API reachable (TCP)" "HTTP ${code}" ;;
    *) fail "broker API reachable (TCP)" "no answer from ${BROKER_SERVER}" ;;
  esac
}

stage_install() {
  local arch mem_kb avail_gb ntp code pub route m busy overlap
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]]; then
    pass "operating system" "${PRETTY_NAME:-}"
  else
    warn "operating system" "${PRETTY_NAME:-unknown}; validated on Ubuntu 24.04"
  fi
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  [[ "$arch" == amd64 ]] && pass "architecture" "$arch" || warn "architecture" "$arch; validated on amd64"
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  (( mem_kb >= 3500000 )) && pass "memory" "$((mem_kb / 1024)) MiB" || warn "memory" "$((mem_kb / 1024)) MiB; a 4 GB machine or larger is recommended"
  avail_gb="$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')"
  (( avail_gb >= 20 )) && pass "free disk on /var" "${avail_gb} GiB" || warn "free disk on /var" "${avail_gb} GiB; 20 GiB or more recommended"
  command -v snap >/dev/null 2>&1 && pass "snapd present" "$(snap version 2>/dev/null | awk 'NR==1 {print $2}')" || fail "snapd present" "install snapd"
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  [[ "$ntp" == yes ]] && pass "time synchronised" || warn "time synchronised" "NTPSynchronized=${ntp}; IPsec needs correct clocks"
  if [[ -d /etc/cloud/cloud.cfg.d ]] && ! grep -qs '^preserve_hostname: true' /etc/cloud/cloud.cfg.d/*.cfg; then
    warn "hostname" "$(hostname); cloud-init resets it from the instance name at boot, setup-microk8s.sh pins it"
  else
    pass "hostname" "$(hostname) (must differ from every central node name)"
  fi
  if snap list microk8s >/dev/null 2>&1; then
    warn "MicroK8s not yet installed" "$(snap list microk8s | awk 'NR==2 {print $2, "from", $4}') is present; setup-microk8s.sh verifies it instead of installing"
  else
    pass "MicroK8s not yet installed"
  fi

  check_broker

  for host in api.snapcraft.io quay.io registry-1.docker.io github.com raw.githubusercontent.com submariner-io.github.io api.ipify.org; do
    code="$(http_code "https://${host}/")"
    [[ "$code" != 000 ]] && pass "egress 443 to ${host}" "HTTP ${code}" || fail "egress 443 to ${host}" "unreachable"
  done

  pub="$(curl -4 -sS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$pub" ]] && pass "public IP seen from the internet" "$pub" \
    || warn "public IP seen from the internet" "not determined; annotate the gateway node with its public IP if the tunnel stays in connecting"

  if [[ -n "$CENTRAL_GATEWAY_IP" ]]; then
    route="$(ip route get "$CENTRAL_GATEWAY_IP" 2>/dev/null | head -1)"
    [[ -n "$route" ]] && pass "route to the central gateway" "$route" || fail "route to the central gateway" "$CENTRAL_GATEWAY_IP"
  fi
  warn "UDP 4500 and 4490 to the central gateway" "cannot be probed without a peer; confirmed by 'subctl show connections' after the join"

  for m in esp4 xfrm_user vxlan ip_set nf_tables; do
    modprobe -n "$m" >/dev/null 2>&1 && pass "kernel module ${m}" || fail "kernel module ${m}" "not available"
  done

  busy="$(ss -lunH 2>/dev/null | awk '{print $5}' | sed 's/.*://' | grep -E '^(500|4500|4490|4800)$' | sort -u | paste -sd, -)"
  [[ -z "$busy" ]] && pass "UDP 500/4500/4490/4800 unbound" || fail "UDP 500/4500/4490/4800 unbound" "in use: ${busy}"

  # shellcheck disable=SC2046
  overlap="$(python3 - "$IPv4_CLUSTER_CIDR" "$IPv4_SERVICE_CIDR" "$CENTRAL_POD_CIDR" "$CENTRAL_SERVICE_CIDR" \
      $(ip -4 -o addr show scope global | awk '$2 !~ /^(cali|vxlan|vx-submariner|tunl)/ {print $4}') <<'PY'
import ipaddress
import sys

nets = [ipaddress.ip_network(a, strict=False) for a in sys.argv[1:]]
names = ["remote pod", "remote service", "central pod", "central service"]
names += ["node address"] * (len(nets) - len(names))
problems = []
for i in range(len(nets)):
    for j in range(i + 1, len(nets)):
        if i >= 4 and j >= 4:
            continue
        if nets[i].overlaps(nets[j]):
            problems.append(f"{names[i]} {nets[i]} overlaps {names[j]} {nets[j]}")
print("; ".join(problems))
PY
)"
  [[ -z "$overlap" ]] && pass "CIDRs do not overlap" "${IPv4_CLUSTER_CIDR} ${IPv4_SERVICE_CIDR} vs ${CENTRAL_POD_CIDR} ${CENTRAL_SERVICE_CIDR}" \
    || fail "CIDRs do not overlap" "$overlap"
}

stage_join() {
  local f mode tmp verify payload pad padding claims sub exp cluster_id code node label api method have
  cd "$CREDENTIALS_DIR" || { fail "credentials directory" "$CREDENTIALS_DIR"; return; }
  if [[ -s cluster-id.txt ]]; then
    cluster_id="$(tr -d '[:space:]' <cluster-id.txt)"
    pass "enrolled cluster ID" "$cluster_id"
  else
    cluster_id=""
    fail "enrolled cluster ID" "cluster-id.txt missing; produced by the enrollment on the central cluster"
  fi
  for f in broker-token.txt broker-ca-base64.txt broker-psk.txt; do
    if [[ -s "$f" ]]; then
      mode="$(stat -c %a "$f")"
      [[ "$mode" == 600 || "$mode" == 400 ]] && pass "credential file ${f}" "mode ${mode}" || warn "credential file ${f}" "mode ${mode}; use chmod 600"
    else
      fail "credential file ${f}" "missing or empty in ${CREDENTIALS_DIR}"
    fi
  done
  (( fails > 0 )) && return

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  if base64 -d broker-ca-base64.txt >"$tmp/ca.crt" 2>/dev/null && openssl x509 -in "$tmp/ca.crt" -noout >/dev/null 2>&1; then
    pass "broker CA decodes to a certificate" "$(openssl x509 -in "$tmp/ca.crt" -noout -enddate | sed 's/notAfter=/expires /')"
  else
    fail "broker CA decodes to a certificate" "broker-ca-base64.txt must hold the base64 value of ca.crt, not decoded PEM"
    return
  fi

  check_broker
  verify="$(openssl s_client -connect "$BROKER_SERVER" -CAfile "$tmp/ca.crt" -verify_hostname "$BROKER_HOST" </dev/null 2>/dev/null | grep -m1 'Verify return code')"
  [[ "$verify" == *"code: 0"* ]] && pass "broker TLS verifies with the CA" "$verify" || fail "broker TLS verifies with the CA" "${verify:-no TLS answer}"

  payload="$(cut -d. -f2 broker-token.txt | tr '_-' '/+')"
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  padding="$(printf '%*s' "$pad" '' | tr ' ' '=')"
  claims="$(printf '%s%s' "$payload" "$padding" | base64 -d 2>/dev/null)"
  sub="$(jq -r '.sub // empty' <<<"$claims" 2>/dev/null)"
  exp="$(jq -r '.exp // empty' <<<"$claims" 2>/dev/null)"
  if [[ "$sub" == "${BROKER_SA_PREFIX}${cluster_id}" ]]; then
    pass "token subject matches the cluster ID" "$sub"
  else
    fail "token subject matches the cluster ID" "${sub:-unreadable}; expected ${BROKER_SA_PREFIX}${cluster_id}"
  fi
  if [[ -n "$exp" ]]; then
    if (( exp > $(date +%s) + 7 * 86400 )); then
      pass "token expiry" "$(date -u -d "@$exp" +%Y-%m-%dT%H:%MZ) (record it with the cluster ID)"
    else
      fail "token expiry" "expires $(date -u -d "@$exp" +%Y-%m-%dT%H:%MZ); request a new token"
    fi
  else
    warn "token expiry" "no exp claim; a legacy non-expiring token is in use"
  fi
  printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' <broker-token.txt)" >"$tmp/auth-header"
  code="$(curl -sS --max-time 8 --cacert "$tmp/ca.crt" -o /dev/null -w '%{http_code}' -H "@$tmp/auth-header" \
    "https://${BROKER_SERVER}/apis/submariner.io/v1/namespaces/submariner-k8s-broker/clusters" 2>/dev/null || echo 000)"
  [[ "$code" == 200 ]] && pass "token can list broker clusters" "HTTP ${code}" || fail "token can list broker clusters" "HTTP ${code}"

  if base64 -d broker-psk.txt >/dev/null 2>&1 && (( $(tr -d '[:space:]' <broker-psk.txt | wc -c) >= 64 )); then
    pass "PSK file is base64 text" "$(tr -d '[:space:]' <broker-psk.txt | wc -c) characters"
  else
    fail "PSK file is base64 text" "broker-psk.txt must hold .data.psk exactly as stored in the secret"
  fi

  if kubectl get nodes >/dev/null 2>&1; then
    node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
    pass "kubectl reaches MicroK8s" "node ${node}"
    label="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.submariner\.io/gateway}')"
    [[ "$label" == true ]] && pass "gateway label" "submariner.io/gateway=true" || fail "gateway label" "run: kubectl label node ${node} submariner.io/gateway=true"
    api="$(kubectl get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"
    [[ "$api" == True ]] && pass "Calico API server available" || fail "Calico API server available" "apiservice v3.projectcalico.org is not Available"
    method="$(kubectl -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="calico-node")].env[?(@.name=="IP_AUTODETECTION_METHOD")].value}' 2>/dev/null)"
    if [[ -n "$method" && "$method" != first-found ]]; then
      pass "Calico IP autodetection pinned" "$method"
    else
      fail "Calico IP autodetection pinned" "${method:-unset}; re-run setup-microk8s.sh, otherwise the node IP moves to vx-submariner at join time"
    fi
    if [[ -e /var/snap/microk8s/current/var/lock/no-cert-reissue ]]; then
      pass "MicroK8s certificate re-issue disabled"
    else
      fail "MicroK8s certificate re-issue disabled" "re-run setup-microk8s.sh, otherwise the join restarts the control plane"
    fi
    if [[ ! -d /etc/cloud/cloud.cfg.d ]] || grep -qs '^preserve_hostname: true' /etc/cloud/cloud.cfg.d/*.cfg; then
      pass "hostname pinned" "$(hostname)"
    else
      fail "hostname pinned" "re-run setup-microk8s.sh; a boot under another instance name registers a second node and strands the gateway"
    fi
  else
    fail "kubectl reaches MicroK8s" "run 'newgrp microk8s' or check ~/.kube/config"
  fi
  dropin=/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf
  if ! systemctl -q is-active systemd-networkd.service 2>/dev/null; then
    pass "systemd-networkd keeps foreign routes" "networkd not running"
  elif grep -qs '^ManageForeignRoutes=no' "$dropin" && grep -qs '^ManageForeignRoutingPolicyRules=no' "$dropin"; then
    pass "systemd-networkd keeps foreign routes" "$dropin"
  else
    fail "systemd-networkd keeps foreign routes" "re-run setup-microk8s.sh; a networkd restart (unattended upgrades) deletes the gateway's policy routing and the connection turns to error"
  fi
  have="$(subctl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [[ "$have" == "v${SUBMARINER_VERSION}" ]] && pass "subctl version" "$have" || fail "subctl version" "${have:-missing}; expected v${SUBMARINER_VERSION}"
  command -v helm >/dev/null 2>&1 && pass "helm available" "$(helm version --short 2>/dev/null)" || fail "helm available" "run setup-microk8s.sh (creates the helm alias)"
}

case "$STAGE" in
  install) stage_install ;;
  join) stage_join ;;
esac

echo
printf 'Result: %d failed, %d warnings\n' "$fails" "$warns"
(( fails == 0 ))
