#!/usr/bin/env bash
# Deploys the exareme2 (exaflow) local worker on this node in namespace
# federation-z and exports its headless Service to the clusterset.
#
# Run as the user in the microk8s group, after join-submariner.sh.
#
# Usage:
#   ./deploy-worker.sh
#   DATASET=synthetic_b ./deploy-worker.sh
#   WORKER_IDENTIFIER=rn-1a2b3c4d ./deploy-worker.sh
#
# Parameters (environment variables):
#   WORKER_IDENTIFIER  identity the worker reports to the controller;
#                      default: the Submariner cluster ID persisted by join-submariner.sh
#   DATASET            dataset this node serves: a CSV in DATA_DIR without the extension,
#                      default synthetic_a; every node of the federation serves a different one
#   DATA_DIR           default: MANIFEST_DIR/data/synthetic_v_0_1 (CDEsMetadata.json and the CSVs)
#   MANIFEST_DIR       default: exaflow-worker next to this script
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${MANIFEST_DIR:-${here}/exaflow-worker}"
DATA_DIR="${DATA_DIR:-${MANIFEST_DIR}/data/synthetic_v_0_1}"
DATASET="${DATASET:-synthetic_a}"
NS=federation-z
EXPORT=exareme2-test-workers-service
WORKER=exaflow-localworker

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

id="${WORKER_IDENTIFIER:-}"
if [[ -z "$id" ]]; then
  for f in /etc/submariner-remote/cluster-id "${XDG_CONFIG_HOME:-$HOME/.config}/submariner-remote/cluster-id"; do
    if [[ -s "$f" ]]; then
      id="$(tr -d '[:space:]' <"$f")"
      break
    fi
  done
fi
[[ -n "$id" ]] || die "no worker identifier: run join-submariner.sh first or set WORKER_IDENTIFIER"
[[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || die "worker identifier '${id}' contains unsupported characters"
[[ -d "$MANIFEST_DIR" ]] || die "manifest directory not found: ${MANIFEST_DIR}"
[[ "$DATASET" =~ ^[A-Za-z0-9_-]+$ ]] || die "DATASET '${DATASET}' contains unsupported characters"
[[ -s "${DATA_DIR}/CDEsMetadata.json" ]] || die "metadata file not found: ${DATA_DIR}/CDEsMetadata.json"
[[ -s "${DATA_DIR}/${DATASET}.csv" ]] || die "dataset file not found: ${DATA_DIR}/${DATASET}.csv"
kubectl get serviceexports.multicluster.x-k8s.io -A >/dev/null 2>&1 \
  || die "the ServiceExport API is not available; join Submariner first"

# The data ConfigMap is built here so that each node serves its own CSV; the
# worker reads /opt/csvs only at start-up, so a changed ConfigMap needs a restart.
log "Applying the namespace and the data ConfigMap (data model $(basename "$DATA_DIR"), dataset ${DATASET})"
kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"
had_worker=false
kubectl -n "$NS" get statefulset "$WORKER" >/dev/null 2>&1 && had_worker=true
cm_result="$(kubectl -n "$NS" create configmap synthetic-data \
  --from-file=CDEsMetadata.json="${DATA_DIR}/CDEsMetadata.json" \
  --from-file="${DATASET}.csv=${DATA_DIR}/${DATASET}.csv" \
  --dry-run=client -o yaml | kubectl apply -f -)"
printf '%s\n' "$cm_result"

log "Applying the worker manifests (identifier ${id})"
kubectl kustomize "$MANIFEST_DIR" | sed "s|__WORKER_IDENTIFIER__|${id}|g" | kubectl apply -f -
if [[ "$had_worker" == true && "$cm_result" == *configured* ]]; then
  log "Data ConfigMap changed; restarting the worker so it reloads the data"
  kubectl -n "$NS" rollout restart "statefulset/${WORKER}"
fi

# The Lighthouse agent distributes the central exports into this namespace as
# soon as it exists; the worker needs the aggregation server name to resolve.
log "Waiting for the central services to be imported into ${NS}"
for _ in $(seq 1 24); do
  imports="$(kubectl -n "$NS" get serviceimports.multicluster.x-k8s.io -o name 2>/dev/null | grep -c . || true)"
  (( imports >= 2 )) && break
  sleep 5
done
kubectl -n "$NS" get serviceimports.multicluster.x-k8s.io 2>/dev/null || true
if (( imports < 2 )); then
  log "WARNING: fewer than two ServiceImports after 2 minutes; check kubectl -n submariner-operator logs deploy/submariner-lighthouse-agent"
fi

log "Waiting for the worker (data model load and health checks take a few minutes)"
kubectl -n "$NS" rollout status "statefulset/${WORKER}" --timeout=900s

log "ServiceExport status"
kubectl -n "$NS" get serviceexport "$EXPORT" \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
echo
kubectl -n "$NS" get pods -o wide

cat <<EOF

The central controller resolves ${EXPORT}.${NS}.svc.clusterset.local to this
worker's pod address. On the central cluster, check that the controller lists
worker ${id}:
  kubectl -n ${NS} logs deploy/exaflow-controller-deployment | grep -i "${id}"
EOF
