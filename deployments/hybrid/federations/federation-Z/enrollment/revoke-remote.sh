#!/usr/bin/env bash
# Revokes a remote cluster on the Submariner broker of the central cluster.
#
# Deletes the account cluster-<id> (which invalidates all its bound tokens), its RoleBindings and the
# enrollment ConfigMap, then removes the remote's objects from the broker namespace:
#   clusters.submariner.io          named <id> or with spec.cluster_id == <id>
#   endpoints.submariner.io         with spec.cluster_id == <id> (label submariner-io/clusterID=<id>)
#   endpointslices                  labelled submariner-io/clusterID=<id> or
#                                   multicluster.kubernetes.io/source-cluster=<id>
#   serviceimports (legacy, pre-0.16) labelled with any of the cluster labels = <id>
#   serviceimports (aggregated)     entry <id> removed from status.clusters and the annotation
#                                   timestamp.submariner.io/<id> dropped; the object is deleted when no
#                                   exporting cluster remains
#
# Parameters (environment variables or key=value arguments):
#   CLUSTER_ID   required
#   BROKER_NS    default submariner-k8s-broker
#   DRY_RUN      default false; true only prints what would be deleted or patched (kubectl --dry-run=server)
#
# The remote node itself is cleaned separately (remote-node/README.md, "Removing a remote node").
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    *=*) export "${arg?}" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument '${arg}' (use KEY=value)" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"
BROKER_NS="${BROKER_NS:-submariner-k8s-broker}"
DRY_RUN="${DRY_RUN:-false}"
CLUSTER_ID="${CLUSTER_ID:-}"
[[ -n "$CLUSTER_ID" ]] || die "CLUSTER_ID is required"
[[ "$CLUSTER_ID" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "CLUSTER_ID '${CLUSTER_ID}' is not a valid DNS label"
SA="cluster-${CLUSTER_ID}"

dry=()
[[ "$DRY_RUN" == true ]] && dry=(--dry-run=server)
k() { kubectl -n "$BROKER_NS" "$@"; }

# --- identity ---------------------------------------------------------------------------------------------
log "Removing the account ${SA}, its RoleBindings and the enrollment ConfigMap"
k delete rolebinding "${SA}-submariner-remote-cluster" "${SA}-submariner-remote-cluster-secret-syncer" \
  "${SA}-submariner-k8s-broker-cluster" --ignore-not-found ${dry[@]+"${dry[@]}"}
k delete serviceaccount "$SA" --ignore-not-found ${dry[@]+"${dry[@]}"}
k delete configmap "$SA" --ignore-not-found ${dry[@]+"${dry[@]}"}

# --- gateway objects --------------------------------------------------------------------------------------
log "Removing Cluster and Endpoint objects of ${CLUSTER_ID}"
k delete clusters.submariner.io "$CLUSTER_ID" --ignore-not-found ${dry[@]+"${dry[@]}"}
for kind in clusters.submariner.io endpoints.submariner.io; do
  # By label (set by the broker syncer on every copy) and by spec.cluster_id (authoritative).
  k delete "$kind" -l "submariner-io/clusterID=${CLUSTER_ID}" --ignore-not-found ${dry[@]+"${dry[@]}"}
  names="$(k get "$kind" -o go-template='{{range .items}}{{if eq .spec.cluster_id "'"$CLUSTER_ID"'"}}{{.metadata.name}} {{end}}{{end}}')"
  for n in $names; do
    k delete "$kind" "$n" --ignore-not-found ${dry[@]+"${dry[@]}"}
  done
done

# --- Lighthouse objects -----------------------------------------------------------------------------------
log "Removing EndpointSlices of ${CLUSTER_ID}"
k delete endpointslices -l "submariner-io/clusterID=${CLUSTER_ID}" --ignore-not-found ${dry[@]+"${dry[@]}"}
k delete endpointslices -l "multicluster.kubernetes.io/source-cluster=${CLUSTER_ID}" --ignore-not-found ${dry[@]+"${dry[@]}"}

log "Removing legacy per-cluster ServiceImports of ${CLUSTER_ID}"
for label in submariner-io/clusterID multicluster.kubernetes.io/source-cluster lighthouse.submariner.io/sourceCluster; do
  k delete serviceimports.multicluster.x-k8s.io -l "${label}=${CLUSTER_ID}" --ignore-not-found ${dry[@]+"${dry[@]}"}
done

log "Detaching ${CLUSTER_ID} from aggregated ServiceImports"
# Aggregated imports carry no cluster label; the exporters are listed in status.clusters and each has a
# timestamp.submariner.io/<id> annotation. Remaining exporters recompute spec.ports on their next EndpointSlice
# event; until then ports of the removed cluster may linger (harmless: they resolve to no endpoints).
# shellcheck disable=SC2016  # go-template braces, not shell expansion
aggregated="$(k get serviceimports.multicluster.x-k8s.io -o go-template='{{range .items}}{{$n := .metadata.name}}{{range .status.clusters}}{{if eq .cluster "'"$CLUSTER_ID"'"}}{{$n}} {{end}}{{end}}{{end}}')"
for si in $aggregated; do
  remaining="$(k get serviceimports.multicluster.x-k8s.io "$si" \
    -o go-template='{{range .status.clusters}}{{if ne .cluster "'"$CLUSTER_ID"'"}}{"cluster":"{{.cluster}}"},{{end}}{{end}}')"
  remaining="[${remaining%,}]"
  if [[ "$remaining" == "[]" ]]; then
    log "  ${si}: ${CLUSTER_ID} was the last exporter, deleting"
    k delete serviceimports.multicluster.x-k8s.io "$si" --ignore-not-found ${dry[@]+"${dry[@]}"}
    continue
  fi
  log "  ${si}: removing ${CLUSTER_ID} from status.clusters (remaining ${remaining})"
  k patch serviceimports.multicluster.x-k8s.io "$si" --subresource=status --type=merge \
    -p "{\"status\":{\"clusters\":${remaining}}}" ${dry[@]+"${dry[@]}"}
  k patch serviceimports.multicluster.x-k8s.io "$si" --type=merge \
    -p "{\"metadata\":{\"annotations\":{\"timestamp.submariner.io/${CLUSTER_ID}\":null}}}" ${dry[@]+"${dry[@]}"}
done

# Timestamp annotations left behind on imports whose status no longer lists the cluster (partial cleanups).
# shellcheck disable=SC2016  # go-template braces, not shell expansion
stale="$(k get serviceimports.multicluster.x-k8s.io -o go-template='{{range .items}}{{$n := .metadata.name}}{{range $k, $v := .metadata.annotations}}{{if eq $k "timestamp.submariner.io/'"$CLUSTER_ID"'"}}{{$n}} {{end}}{{end}}{{end}}')"
for si in $stale; do
  log "  ${si}: dropping stale annotation timestamp.submariner.io/${CLUSTER_ID}"
  k patch serviceimports.multicluster.x-k8s.io "$si" --type=merge \
    -p "{\"metadata\":{\"annotations\":{\"timestamp.submariner.io/${CLUSTER_ID}\":null}}}" ${dry[@]+"${dry[@]}"}
done

log "Remaining objects in ${BROKER_NS} that still mention ${CLUSTER_ID} (expected: none)"
k get clusters.submariner.io,endpoints.submariner.io,endpointslices,serviceimports.multicluster.x-k8s.io \
  -o name --show-labels 2>/dev/null | grep -F -- "$CLUSTER_ID" || echo "none"

cat <<EOF

Revoked cluster ID: ${CLUSTER_ID}$( [[ "$DRY_RUN" == true ]] && printf ' (dry run, nothing changed)' )
All tokens of ${SA} are invalid. Update the internal tracking system and, on the central cluster,
run 'subctl show connections' to confirm the peer is gone.
EOF
