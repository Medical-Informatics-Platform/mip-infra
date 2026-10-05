#!/usr/bin/env bash
# Joins this MicroK8s node to the central Submariner broker with Helm.
#
# Run as the user in the microk8s group (kubectl, helm and subctl on PATH) from
# the directory holding the credential files produced by the enrollment on the
# central cluster (README, step 1):
#   cluster-id.txt        cluster ID chosen at enrollment (name of the broker account cluster-<id>)
#   broker-token.txt      bound service-account token of that account, plain text
#   broker-ca-base64.txt  broker CA certificate, base64 as stored in a secret
#   broker-psk.txt        IPsec pre-shared key, the .data.psk value as stored
#
# Usage:
#   ./join-submariner.sh             # first join or re-join with rotated credentials
#   ./join-submariner.sh --shred     # also shreds the credential files on success
#   ./join-submariner.sh             # without credential files and with an existing
#                                    # release: upgrades the release in place to
#                                    # SUBMARINER_VERSION (helm upgrade --reuse-values)
#
# Parameters (environment variables):
#   SUBMARINER_VERSION     chart version, default 0.24.1; must match the central cluster
#   SUBMARINER_CLUSTER_ID  overrides cluster-id.txt; must equal the enrolled account name suffix
#   CREDENTIALS_DIR        default: current directory
#   VALUES_FILE            default: submariner-values.yaml next to this script
#
# The broker only accepts objects carrying the enrolled cluster ID, so the ID
# cannot be chosen here. It is persisted on the node for deploy-worker.sh and
# for re-runs; record it with the site in the internal mapping.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# renovate: datasource=github-releases depName=submariner-io/releases
SUBMARINER_VERSION="${SUBMARINER_VERSION:-0.24.1}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-$PWD}"
VALUES_FILE="${VALUES_FILE:-${here}/submariner-values.yaml}"
RELEASE=submariner-operator
NS=submariner-operator
REPO_NAME=submariner-latest
REPO_URL=https://submariner-io.github.io/submariner-charts/charts
ID_FILE_SYSTEM=/etc/submariner-remote/cluster-id
ID_FILE_USER="${XDG_CONFIG_HOME:-$HOME/.config}/submariner-remote/cluster-id"
SHRED=false
[[ "${1:-}" == "--shred" ]] && SHRED=true

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in kubectl helm subctl openssl; do
  command -v "$tool" >/dev/null 2>&1 \
    || die "${tool} not found on PATH (run setup-tools.sh and setup-microk8s.sh, then 'newgrp microk8s')"
done
cd "$CREDENTIALS_DIR"
[[ -f "$VALUES_FILE" ]] || die "values file not found: ${VALUES_FILE}"
kubectl get nodes >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

# --- mode: join with credential files, or in-place upgrade of the release ----
# The credential files are shredded after a verified join, so a version change
# later reuses the values stored in the Helm release (token, CA, PSK, ID).
MODE="join"
missing=()
for f in broker-token.txt broker-ca-base64.txt broker-psk.txt; do
  [[ -s "$f" ]] || missing+=("$f")
done
if (( ${#missing[@]} > 0 )); then
  if (( ${#missing[@]} == 3 )) && helm -n "$NS" status "$RELEASE" >/dev/null 2>&1; then
    MODE="upgrade"
    log "No credential files in ${CREDENTIALS_DIR}; upgrading the existing release in place"
  else
    die "missing credential file(s) in ${CREDENTIALS_DIR}: ${missing[*]} (all three are needed for a join; none for an in-place upgrade)"
  fi
fi

# --- CIDRs: the values file must describe this cluster -------------------------
# Each node has its own values file (submariner-values*.yaml) because the CIDRs
# are literals there and on the central side; a mismatch would be denied by the
# broker's subnet policy with a less obvious message.
want_pod="$(sed -n 's/^ *clusterCidr:[[:space:]]*\([0-9./]*\).*/\1/p' "$VALUES_FILE" | head -1)"
want_svc="$(sed -n 's/^ *serviceCidr:[[:space:]]*\([0-9./]*\).*/\1/p' "$VALUES_FILE" | head -1)"
live_pod="$(kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr}' 2>/dev/null || true)"
live_svc="$(kubectl get servicecidrs.networking.k8s.io kubernetes -o jsonpath='{.spec.cidrs[0]}' 2>/dev/null || true)"
[[ -z "$live_pod" || "$live_pod" == "$want_pod" ]] \
  || die "${VALUES_FILE} sets clusterCidr ${want_pod} but this cluster uses ${live_pod}; pass the values file written for this node (VALUES_FILE=...)"
[[ -z "$live_svc" || "$live_svc" == "$want_svc" ]] \
  || die "${VALUES_FILE} sets serviceCidr ${want_svc} but this cluster uses ${live_svc}; pass the values file written for this node (VALUES_FILE=...)"
log "CIDRs from ${VALUES_FILE##*/}: pod ${want_pod}, service ${want_svc}"

# --- cluster ID --------------------------------------------------------------
cluster_id="${SUBMARINER_CLUSTER_ID:-}"
if [[ -z "$cluster_id" && -s cluster-id.txt ]]; then
  cluster_id="$(tr -d '[:space:]' <cluster-id.txt)"
  log "Using the enrolled cluster ID from cluster-id.txt"
fi
if [[ -z "$cluster_id" && "$MODE" == upgrade ]]; then
  cluster_id="$(kubectl -n "$NS" get submariner submariner -o jsonpath='{.spec.clusterID}' 2>/dev/null || true)"
  [[ -n "$cluster_id" ]] && log "Using the cluster ID of the installed release"
fi
[[ -n "$cluster_id" ]] || die "no cluster ID: cluster-id.txt is missing from ${CREDENTIALS_DIR} (produced by the enrollment on the central cluster)"
[[ "$cluster_id" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "cluster ID '${cluster_id}' is not a valid DNS label"

for f in "$ID_FILE_SYSTEM" "$ID_FILE_USER"; do
  if [[ -s "$f" ]]; then
    persisted="$(tr -d '[:space:]' <"$f")"
    [[ "$persisted" == "$cluster_id" ]] \
      || die "this node was previously joined as '${persisted}' (${f}); re-enroll under that ID or run the removal procedure first"
    break
  fi
done

existing="$(kubectl -n "$NS" get submariner submariner -o jsonpath='{.spec.clusterID}' 2>/dev/null || true)"
if [[ -n "$existing" && "$existing" != "$cluster_id" ]]; then
  die "this node is already joined as '${existing}'; changing the cluster ID requires the removal procedure first"
fi

if sudo -n install -D -m 0644 /dev/null "$ID_FILE_SYSTEM" 2>/dev/null \
   && printf '%s\n' "$cluster_id" | sudo -n tee "$ID_FILE_SYSTEM" >/dev/null 2>&1; then
  log "Cluster ID persisted in ${ID_FILE_SYSTEM}"
else
  install -D -m 0644 /dev/null "$ID_FILE_USER"
  printf '%s\n' "$cluster_id" >"$ID_FILE_USER"
  log "Cluster ID persisted in ${ID_FILE_USER} (no passwordless sudo for ${ID_FILE_SYSTEM})"
fi

# --- gateway label -----------------------------------------------------------
node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
kubectl label node "$node" submariner.io/gateway=true --overwrite >/dev/null

log "Adding the Submariner chart repository"
helm repo add "$REPO_NAME" "$REPO_URL" --force-update >/dev/null
helm repo update "$REPO_NAME" >/dev/null

if [[ "$MODE" == join ]]; then
  # --- local values: cluster ID and credentials, never committed ---------------
  umask 077
  local_values="${CREDENTIALS_DIR}/local-values.yaml"
  {
    printf 'submariner:\n  clusterId: %s\n' "$cluster_id"
    printf 'broker:\n  token: "%s"\n  ca: "%s"\n' \
      "$(tr -d '[:space:]' <broker-token.txt)" "$(tr -d '[:space:]' <broker-ca-base64.txt)"
    printf 'ipsec:\n  psk: "%s"\n' "$(tr -d '[:space:]' <broker-psk.txt)"
  } >"$local_values"

  # --- Helm install -----------------------------------------------------------
  log "Installing the submariner-operator chart ${SUBMARINER_VERSION} as cluster ${cluster_id}"
  helm upgrade --install "$RELEASE" "${REPO_NAME}/submariner-operator" \
    --version "$SUBMARINER_VERSION" \
    --namespace "$NS" --create-namespace \
    -f "$VALUES_FILE" -f "$local_values" \
    --wait --timeout 5m
else
  # --- Helm upgrade in place ---------------------------------------------------
  # --reuse-values keeps the stored token, CA, PSK and cluster ID; the values
  # file is not passed again because it would blank the credential keys.
  local_values=""
  installed="$(helm -n "$NS" list -f "^${RELEASE}\$" -o json | sed -n 's/.*"chart":"submariner-operator-\([^"]*\)".*/\1/p')"
  log "Upgrading the submariner-operator release from ${installed:-unknown} to ${SUBMARINER_VERSION} (cluster ${cluster_id})"
  helm upgrade "$RELEASE" "${REPO_NAME}/submariner-operator" \
    --version "$SUBMARINER_VERSION" \
    --namespace "$NS" \
    --reuse-values \
    --wait --timeout 5m
  kubectl -n "$NS" rollout status deploy/submariner-operator --timeout=300s
fi

# The chart only creates the operator; the operator then deploys (or, on an
# upgrade, rolls) the gateway, route agent, Lighthouse agent and CoreDNS, and
# the metrics proxy. Done when every pod is ready and runs the target version.
log "Waiting for the Submariner components at ${SUBMARINER_VERSION}"
deadline=$((SECONDS + 600))
while :; do
  pods="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null || true)"
  total="$(printf '%s\n' "$pods" | grep -c . || true)"
  not_ready="$(printf '%s\n' "$pods" | awk '{split($2, r, "/"); if ($3 != "Running" || r[1] != r[2]) print $1}' | paste -sd, -)"
  stale="$(kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | sed '/^$/d' | grep -v -c -E ":v?${SUBMARINER_VERSION}$" || true)"
  if [[ -z "$not_ready" && "$total" -ge 5 && "${stale:-0}" -eq 0 ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    kubectl -n "$NS" get pods
    die "Submariner pods are not all ready at ${SUBMARINER_VERSION} after 10 minutes: ${not_ready:-fewer than 5 pods}; ${stale:-0} container(s) on another version"
  fi
  sleep 10
done
kubectl -n "$NS" get pods

# The Lighthouse agent probes the broker once at start-up. When that probe
# fails because cluster DNS is unavailable (the node's control plane restarting
# during the join, see setup-microk8s.sh), Admiral keeps a REST config without
# the broker CA and every later request fails with an x509 error until the
# process restarts. The operator owns the Deployment and reverts a rollout
# restart within seconds, so the pod itself is recreated.
lighthouse_probe_failed() {
  kubectl -n "$NS" logs deploy/submariner-lighthouse-agent --tail=400 2>/dev/null \
    | grep -q -E 'Error accessing the broker API server|x509: certificate signed by unknown authority'
}
if lighthouse_probe_failed; then
  log "Lighthouse agent probed the broker while DNS was unavailable; recreating its pod"
  kubectl -n "$NS" delete pod -l app=submariner-lighthouse-agent --wait=true >/dev/null
  kubectl -n "$NS" rollout status deploy/submariner-lighthouse-agent --timeout=180s
  sleep 45
  if lighthouse_probe_failed; then
    log "Lighthouse agent still cannot reach the broker; see kubectl -n ${NS} logs deploy/submariner-lighthouse-agent"
  else
    log "Lighthouse agent reaches the broker"
  fi
fi

log "Connection status"
subctl show all || true

if [[ "$MODE" == upgrade ]]; then
  cat <<EOF

Release upgraded to ${SUBMARINER_VERSION} for cluster ID: ${cluster_id}
Check from the central cluster:   subctl show connections; subctl show versions
EOF
  exit 0
fi

cat <<EOF

Joined as cluster ID: ${cluster_id}
Record this ID with the site in the internal mapping.

Check from the central cluster:   subctl show connections
Once the connection is established, remove the credentials:
  shred -u ${CREDENTIALS_DIR}/broker-token.txt ${CREDENTIALS_DIR}/broker-ca-base64.txt ${CREDENTIALS_DIR}/broker-psk.txt ${local_values}
The token expires; re-run the enrollment and this script before the expiry recorded with the ID.
EOF

if [[ "$SHRED" == true ]]; then
  log "Shredding the credential files"
  shred -u broker-token.txt broker-ca-base64.txt broker-psk.txt "$local_values"
fi
