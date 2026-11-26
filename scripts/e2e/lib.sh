#!/usr/bin/env bash
# scripts/e2e/lib.sh
#
# Shared helpers for the kind-based smoke and e2e tests. Sourced by
# scripts/kind-argo-test.sh and scripts/e2e/run-e2e.sh — not executable on
# its own.
#
# Callers must set (before or after sourcing):
#   CLUSTER    kind cluster name
#   REPO_ROOT  absolute path to the repo checkout
# and are responsible for their own `set -euo pipefail` and EXIT trap
# (see teardown_cluster below).

NS=argocd-mip-team
GATEWAY_API_VERSION=v1.3.0
# In-cluster probe image shared by the smoke and e2e tests.
PROBE_IMAGE=curlimages/curl:8.10.1
# Registries the kind nodes pull through a mirror (start_registry_mirrors), and
# the pull-through registry each mirror runs.
MIRRORED_REGISTRIES="docker.io quay.io ghcr.io mirror.gcr.io"
MIRROR_IMAGE=mirror.gcr.io/library/registry:3.0.0

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
step() { printf '\n=== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

create_ha_kind_cluster() {
  kind create cluster --name "$CLUSTER" --wait 120s --config=- <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF
}

# Create the cluster, or reuse an existing one if it already has the
# 1 control-plane + 3 worker topology the HA overlay needs (redis-ha-server /
# redis-ha-haproxy run 3 replicas with hard pod anti-affinity; the
# control-plane is tainted NoSchedule by default).
ensure_kind_cluster() {
  if ! kind get clusters | grep -qx "$CLUSTER"; then
    create_ha_kind_cluster
  else
    echo "(cluster already exists, inspecting topology)"
    kubectl config use-context "kind-$CLUSTER" >/dev/null

    local existing_nodes
    existing_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$existing_nodes" -lt 4 ]]; then
      echo "(cluster has ${existing_nodes} node(s); recreating with 1 control-plane + 3 workers)"
      kind delete cluster --name "$CLUSTER"
      create_ha_kind_cluster
    else
      echo "(cluster already exists with ${existing_nodes} node(s), reusing)"
    fi
  fi
}

# Pull-through registry mirrors on the kind network. Each kind node has its own
# image store, so an image used on three nodes is downloaded three times; through
# a mirror it is downloaded once per job. MIRRORED_REGISTRIES are those whose
# images land on several nodes (Argo CD, dex, Redis HA, MetalLB's speaker, the
# probe, exareme2 workers). docker.elastic.co stays direct: its images run on
# one node each, and a mirror would only add a copy on the runner's disk.
# Best effort: a node falls back to the registry itself when its mirror fails.
mirror_name() { echo "kind-mirror-${1//./-}"; }
registry_url() {
  if [[ $1 == docker.io ]]; then echo https://registry-1.docker.io; else echo "https://$1"; fi
}

start_registry_mirrors() {
  docker pull --quiet "$MIRROR_IMAGE" >/dev/null \
    || { echo "(no registry mirrors: the nodes pull directly)"; return 0; }
  local reg name node
  for reg in $MIRRORED_REGISTRIES; do
    name=$(mirror_name "$reg")
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]]; then
      docker rm -f "$name" >/dev/null 2>&1 || true
      if ! docker run -d --name "$name" --network "${KIND_EXPERIMENTAL_DOCKER_NETWORK:-kind}" \
             -e REGISTRY_PROXY_REMOTEURL="$(registry_url "$reg")" "$MIRROR_IMAGE" >/dev/null; then
        echo "(no mirror for $reg: the nodes pull from it directly)"
        continue
      fi
    fi
    for node in $(kind get nodes --name "$CLUSTER"); do
      printf 'server = "%s"\n\n[host."http://%s:5000"]\n  capabilities = ["pull", "resolve"]\n' \
          "$(registry_url "$reg")" "$name" \
        | docker exec -i "$node" sh -c \
            "mkdir -p /etc/containerd/certs.d/$reg && cat >/etc/containerd/certs.d/$reg/hosts.toml" \
        || echo "(node $node pulls $reg directly)"
    done
    echo "OK: the nodes pull $reg through $name"
  done
}

# Image downloads of the job by registry, compressed: what its mirror fetched,
# or, for a registry without one, every node's copy. "On the nodes" is what the
# nodes would have downloaded without the mirrors (a layer shared by two images
# counts twice). kind's node image and the images it preloads (registry.k8s.io,
# docker.io/kindest) are not counted. Printed in the log and, in CI, the job
# summary.
report_downloads() {
  command -v yq >/dev/null 2>&1 || return 0
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || return 0
  local reg node table
  table=$(
    {
      for reg in $MIRRORED_REGISTRIES; do
        docker exec "$(mirror_name "$reg")" du -sk /var/lib/registry 2>/dev/null \
          | awk -v r="$reg" '{ print "mirror", r, $1 * 1024 }'
      done
      for node in $(kind get nodes --name "$CLUSTER"); do
        docker exec "$node" crictl images -o json \
          | yq -p json '.images[] | "node " + (.repoTags[0] // .repoDigests[0] // "unknown") + " " + .size'
      done
    } | awk '
      $1 == "mirror" { fetched[$2] = $3; next }
      $2 ~ /^(registry\.k8s\.io|docker\.io\/kindest)\// { next }
      { split($2, part, "/"); held[part[1]] += $3 }
      END {
        printf "%-18s %13s %15s\n", "registry", "downloaded", "on the nodes"
        for (r in held) {
          d = (r in fetched) ? fetched[r] : held[r]
          printf "%-18s %10.0f MB %12.0f MB\n", r, d / 1e6, held[r] / 1e6 | "sort"
          total += d; nodes += held[r]
        }
        close("sort")
        printf "%-18s %10.0f MB %12.0f MB\n", "total", total / 1e6, nodes / 1e6
      }'
  )
  step "Image downloads of this job"
  echo "$table"
  df -h / | awk 'NR == 2 { print "runner disk: " $3 " used of " $2 " (" $5 ")" }'
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    { printf '### Image downloads: %s\n\n' "${PROFILE:-$CLUSTER}"; sed 's/^/    /' <<<"$table"; } >>"$GITHUB_STEP_SUMMARY"
  fi
}

# EXIT-trap body shared by the entrypoints. Honors KEEP=1.
# Exits with $1 when given (for traps that do work before calling this,
# which would clobber $?), else with the status at entry.
teardown_cluster() {
  local rc=${1:-$?} reg
  report_downloads || true
  if [[ "${KEEP:-0}" != "1" ]]; then
    echo "--- Tearing down kind cluster '$CLUSTER' and its registry mirrors"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    for reg in $MIRRORED_REGISTRIES; do
      docker rm -f "$(mirror_name "$reg")" >/dev/null 2>&1 || true
    done
  else
    echo "--- KEEP=1: leaving cluster '$CLUSTER' and its registry mirrors up. Delete with: kind delete cluster --name $CLUSTER"
  fi
  exit "$rc"
}

install_gateway_api_crds() {
  # Pinned standard channel. Required so SubjectAccessReviews for HTTPRoutes
  # resolve the resource — without the CRDs `kubectl auth can-i` returns no.
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
}

install_argo_overlay() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  # AppProject CRD must exist before our static AppProjects apply, so we
  # install the overlay (which includes upstream CRDs) first and only then the
  # projects. --server-side because the applicationsets CRD exceeds the 256KB
  # last-applied-configuration annotation limit.
  # Redis HA pulls redis and haproxy from public.ecr.aws, which rate-limits
  # (429) anonymous clients such as CI runners. The same digests come from
  # Google's Docker Hub mirror; argo-setup itself keeps public.ecr.aws.
  kustomize build "$REPO_ROOT/argo-setup/patches" \
    | sed 's#public\.ecr\.aws/docker/library/#mirror.gcr.io/library/#g' \
    | kubectl apply --server-side --force-conflicts -f -
}

# wait_rollouts <namespace> <timeout> <workload...>
wait_rollouts() {
  local ns=$1 timeout=$2 obj
  shift 2
  for obj in "$@"; do
    kubectl -n "$ns" rollout status "$obj" --timeout="$timeout"
  done
}

wait_argo_rollouts() {
  # Wait long enough for image pulls on a cold kind node.
  wait_rollouts "$NS" 300s \
    statefulset/argocd-application-controller \
    statefulset/argocd-redis-ha-server \
    deploy/argocd-server \
    deploy/argocd-repo-server \
    deploy/argocd-redis-ha-haproxy \
    deploy/argocd-dex-server \
    deploy/argocd-applicationset-controller \
    deploy/argocd-notifications-controller
}

apply_static_appprojects() {
  kubectl apply --server-side --force-conflicts -f "$REPO_ROOT/base/argo-projects/argo-projects.yaml"
  local f
  for f in "$REPO_ROOT"/projects/static/*/*.yaml; do
    # Skip kustomize control files; only apply actual k8s manifests.
    case "$(basename "$f")" in
      kustomization.yaml|values.yaml) continue ;;
    esac
    kubectl apply --server-side --force-conflicts -f "$f"
  done
}
