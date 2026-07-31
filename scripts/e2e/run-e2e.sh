#!/usr/bin/env bash
# scripts/e2e/run-e2e.sh
#
# Component-scoped e2e test against an ephemeral kind cluster, deploying
# through Argo CD exactly like production. A profile selects which component
# is deployed and verified:
#
#   exareme2     federation-A exareme2 (chart + images at the PR's pins)
#   mip-stack    federation-A exareme2 + mip-stack
#   eck          ECK operator (version from the PR's values) + ES + Kibana
#   haproxy      haproxy-public ingress + MetalLB + cert-manager + echo probe
#   datacatalog  datacatalog frontend/backend/db
#
# The committed Application manifests keep `targetRevision: main` (enforced
# by the check-main-revisions workflow). This script renders them and
# rewrites `main` to HEAD_SHA at runtime so Argo CD syncs the commit under
# test — the branch must therefore be pushed (Argo fetches it from GitHub).
#
# Usage:
#   PROFILE=exareme2 bash scripts/e2e/run-e2e.sh    # or: run-e2e.sh exareme2
#   KEEP=1 ...                                       # leave the cluster up
#   CLUSTER=foo ...                                  # custom kind cluster name
#   HEAD_SHA=<sha> ...                               # override commit to sync
#
# Requires: kind, kubectl, kustomize, docker, git, yq;
#           helm for the exareme2/mip-stack profiles.
set -euo pipefail

PROFILE=${PROFILE:-${1:-}}
case "$PROFILE" in
  exareme2|mip-stack|eck|haproxy|datacatalog) ;;
  *) echo "usage: PROFILE=<exareme2|mip-stack|eck|haproxy|datacatalog> $0" >&2; exit 2 ;;
esac

CLUSTER=${CLUSTER:-mip-e2e}
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
KEEP=${KEEP:-0}

# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/e2e/lib.sh"

# --- pinned tool/manifest versions (Renovate-managed, see renovate.json5) ---
# renovate: datasource=github-releases depName=cert-manager/cert-manager
CERT_MANAGER_VERSION=v1.21.1
# renovate: datasource=github-releases depName=metallb/metallb
METALLB_VERSION=v0.15.2

need kind; need kubectl; need kustomize; need docker; need git; need yq
case "$PROFILE" in exareme2|mip-stack) need helm ;; esac

HEAD_SHA=${HEAD_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD)}
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "HEAD_SHA is not a 40-hex commit: '$HEAD_SHA'"

WORKDIR=$(mktemp -d)
cleanup() {
  local rc=$?
  rm -rf "$WORKDIR"
  # Reuse the shared teardown (honors KEEP); it exits with $rc for us.
  teardown_cluster "$rc"
}
trap cleanup EXIT

# ------------------------------- helpers -------------------------------------

# render_and_rewrite <kustomize-dir-or-manifest-file> <out-file> <min-rewrites>
#
# Renders the source and rewrites `targetRevision: main` to HEAD_SHA — but
# only on sources whose repoURL is this repo, so a future Application
# tracking another repo's `main` can never be pointed at a mip-infra commit.
# Then applies the check_zero pattern (cf. mip-dev-cluster's
# prepare-mip-infra-fork.sh): hard-fails if fewer than <min-rewrites> lines
# were rewritten, if any `targetRevision: main` survives (loud stop for the
# hypothetical other-repo case), or if the render references the private
# mip-deployments repo (unreachable from CI).
render_and_rewrite() {
  local src=$1 out=$2 expect=$3
  if [[ -d "$src" ]]; then
    kustomize build "$src" >"$out"
  else
    cp "$src" "$out"
  fi
  HEAD_SHA="$HEAD_SHA" yq -i '
    (.spec.source
      | select((.repoURL // "" | test("Medical-Informatics-Platform/mip-infra"))
               and .targetRevision == "main")
    ).targetRevision |= strenv(HEAD_SHA) |
    (.spec.sources[]?
      | select((.repoURL // "" | test("Medical-Informatics-Platform/mip-infra"))
               and .targetRevision == "main")
    ).targetRevision |= strenv(HEAD_SHA)
  ' "$out"

  local got
  got=$(grep -c "targetRevision: ${HEAD_SHA}" "$out" || true)
  if [[ "$got" -lt "$expect" ]]; then
    fail "expected >= $expect rewritten targetRevision lines in $src, got $got"
  fi
  if grep -nE 'targetRevision:[[:space:]]+main([[:space:]]|$)' "$out"; then
    fail "unrewritten 'targetRevision: main' remains in render of $src"
  fi
  if grep -n 'mip-deployments' "$out"; then
    fail "render of $src references the private mip-deployments repo"
  fi
  echo "OK: rewrote $got targetRevision line(s) to ${HEAD_SHA}"
}

# wait_app <application-name> [timeout-seconds]
#
# Waits until the Argo Application is Synced + Healthy. Fails fast (with
# repo-server logs) when error conditions persist across several polls —
# that is where a bad revision rewrite or an unfetchable SHA surfaces.
wait_app() {
  local app=$1 timeout=${2:-600}
  local deadline=$((SECONDS + timeout)) sync='' health='' conds='' err_polls=0
  while (( SECONDS < deadline )); do
    sync=$(kubectl -n "$NS" get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$(kubectl -n "$NS" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      echo "OK: application $app is Synced/Healthy"
      return 0
    fi
    conds=$(kubectl -n "$NS" get application "$app" \
              -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>/dev/null || true)
    if grep -qE 'ComparisonError|InvalidSpecError' <<<"$conds"; then
      err_polls=$((err_polls + 1))
      # 3 min of consecutive errors: long enough to ride out the cold first
      # clone of a chart repo, short enough to fail fast on a bad SHA.
      if (( err_polls >= 18 )); then
        echo "--- application $app conditions:" >&2
        echo "$conds" >&2
        kubectl -n "$NS" logs deploy/argocd-repo-server --tail=50 >&2 || true
        fail "application $app has persistent error conditions"
      fi
    else
      err_polls=0
    fi
    sleep 10
  done
  fail "timeout after ${timeout}s waiting for application $app (sync=${sync:-?} health=${health:-?})"
}

# ensure_probe <namespace> — long-lived in-cluster curl pod, one per namespace.
# A leftover pod from a previous KEEP=1 run may have Completed its sleep
# (restart=Never can never become Ready again), so recreate unless Running.
ensure_probe() {
  local ns=$1 phase
  phase=$(kubectl -n "$ns" get pod e2e-probe -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ -n "$phase" && "$phase" != "Running" && "$phase" != "Pending" ]]; then
    kubectl -n "$ns" delete pod e2e-probe --wait=true >/dev/null
    phase=""
  fi
  if [[ -z "$phase" ]]; then
    kubectl -n "$ns" run e2e-probe --image="$PROBE_IMAGE" \
      --restart=Never --command -- sleep 3600 >/dev/null
  fi
  kubectl -n "$ns" wait pod/e2e-probe --for=condition=Ready --timeout=120s >/dev/null
}

# probe_curl <namespace> <curl-args...> — curl from inside the cluster;
# -f makes non-2xx a failure.
probe_curl() {
  local ns=$1; shift
  kubectl -n "$ns" exec e2e-probe -- curl -fsS --max-time 15 "$@"
}

# assert_body <namespace> <url> <grep -E pattern> <description> [curl-args...]
#
# Service-level truth: asserts response *content*, not just the status code.
assert_body() {
  local ns=$1 url=$2 pattern=$3 desc=$4 body
  shift 4
  if ! body=$(probe_curl "$ns" "$@" "$url"); then
    fail "$desc: request to $url failed"
  fi
  if ! grep -qE "$pattern" <<<"$body"; then
    echo "--- response body (truncated):" >&2
    head -c 500 <<<"$body" >&2; echo >&2
    fail "$desc: response from $url does not match /$pattern/"
  fi
  echo "OK: $desc"
}

# retry <attempts> <sleep-seconds> <description> <command...>
retry() {
  local attempts=$1 pause=$2 desc=$3 i
  shift 3
  for (( i = 1; i <= attempts; i++ )); do
    if "$@"; then return 0; fi
    (( i < attempts )) && sleep "$pause"
  done
  fail "$desc (gave up after $attempts attempts)"
}

assert_pvcs_bound() {
  local ns=$1 pvc phase
  local pvcs
  pvcs=$(kubectl -n "$ns" get pvc -o name)
  [[ -n "$pvcs" ]] || fail "no PVCs found in $ns"
  for pvc in $pvcs; do
    phase=$(kubectl -n "$ns" get "$pvc" -o jsonpath='{.status.phase}')
    [[ "$phase" == "Bound" ]] || fail "$ns/$pvc is $phase, expected Bound"
    echo "OK: $ns/$pvc Bound"
  done
}

# ------------------------- federation deploy (shared) -------------------------

FED_NS_TARGET=federation-a

deploy_federation_apps() {
  step "Create federation-a AppProject"
  # Not part of projects/static/ — in production it is generated by the
  # mip-argo-projects-of-federations ApplicationSet from this chart (whose
  # defaults are federation-a already).
  helm template "$REPO_ROOT/projects/templates/federation" | kubectl apply -f -

  step "Create CI secrets (federation)"
  bash "$REPO_ROOT/scripts/e2e/ci-secrets.sh" federation

  step "Render federation overlay + rewrite revisions to PR head"
  # 2 = the $values self-reference of each of the two shared-apps Applications.
  render_and_rewrite "$REPO_ROOT/tests/e2e/federation" "$WORKDIR/federation.yaml" 2

  if [[ "$PROFILE" == "exareme2" ]]; then
    step "Apply federation-a-exareme2 Application"
    yq 'select(.metadata.name == "federation-a-exareme2")' "$WORKDIR/federation.yaml" \
      | kubectl apply -f -
  else
    step "Apply federation-a Applications (exareme2 + mip-stack)"
    kubectl apply -f "$WORKDIR/federation.yaml"
  fi
}

check_exareme2() {
  step "Wait for federation-a-exareme2 to be Synced/Healthy"
  # Healthy implies the controller startupProbe (/healthcheck, which itself
  # verifies the worker landscape) and both worker exec-healthchecks pass.
  wait_app federation-a-exareme2 900

  step "Verify exareme2 workloads"
  wait_rollouts "$FED_NS_TARGET" 120s \
    deploy/exaflow-controller-deployment \
    statefulset/exaflow-localworker \
    statefulset/exaflow-globalworker \
    deploy/exaflow-aggregation-server-deployment
  assert_pvcs_bound "$FED_NS_TARGET"

  step "Verify exareme2 service responses"
  ensure_probe "$FED_NS_TARGET"
  # /healthcheck returns 200 only when the controller can reach its workers.
  probe_curl "$FED_NS_TARGET" "http://exaflow-controller-service:5000/healthcheck" >/dev/null \
    || fail "exaflow controller /healthcheck failed"
  echo "OK: exaflow controller /healthcheck (controller sees its workers)"
  assert_body "$FED_NS_TARGET" "http://exaflow-controller-service:5000/algorithms" \
    '"name"' "exaflow /algorithms returns a non-empty algorithm list"
}

check_mip_stack() {
  step "Wait for federation-a-mip-stack to be Synced/Healthy"
  wait_app federation-a-mip-stack 900

  step "Verify mip-stack workloads"
  # The chart defines no probes, so Argo 'Healthy' is weak here — rollout
  # status + direct service checks below carry the signal.
  wait_rollouts "$FED_NS_TARGET" 300s deploy/platform-backend deploy/platform-ui

  step "Verify postgres accepts connections"
  retry 12 10 "postgres not ready" \
    kubectl -n "$FED_NS_TARGET" exec deploy/platform-backend -c platform-backend-db -- \
      pg_isready -p 5432 -U postgres

  step "Verify mip-stack service responses"
  ensure_probe "$FED_NS_TARGET"
  assert_body "$FED_NS_TARGET" "http://platform-ui:80/" \
    '<html|<!DOCTYPE|<!doctype' "platform-ui serves the frontend"
  # Backend endpoint layout varies across versions; accept the first known
  # path that answers 2xx with content. All of them require the backend to
  # be up with its DB connection established.
  local path body ok=0 attempt
  for attempt in $(seq 1 18); do
    for path in /services/algorithms /services/actuator/health /actuator/health; do
      if body=$(probe_curl "$FED_NS_TARGET" "http://platform-backend-service:8080${path}" 2>/dev/null) \
         && [[ -n "$body" ]]; then
        echo "OK: platform-backend answered on ${path}"
        ok=1
        break 2
      fi
    done
    sleep 10
  done
  if [[ "$ok" != "1" ]]; then
    kubectl -n "$FED_NS_TARGET" logs deploy/platform-backend -c platform-backend --tail=100 >&2 || true
    fail "platform-backend did not answer on any known endpoint"
  fi
}

# --------------------------------- profiles -----------------------------------

profile_exareme2() {
  deploy_federation_apps
  check_exareme2
}

profile_mip_stack() {
  deploy_federation_apps
  # mip-stack consumes exaflow-controller-service in the same namespace, so
  # the (already-merged) exareme2 baseline is deployed alongside.
  check_exareme2
  check_mip_stack
}

profile_eck() {
  step "Install ECK operator at the version pinned in the PR's values"
  local op_ver
  op_ver=$(yq '.operator.version' "$REPO_ROOT/common/monitoring/eck/values.yaml")
  [[ "$op_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cannot parse operator.version from eck values: '$op_ver'"
  kubectl apply --server-side -f "https://download.elastic.co/downloads/eck/${op_ver}/crds.yaml"
  kubectl apply --server-side -f "https://download.elastic.co/downloads/eck/${op_ver}/operator.yaml"
  kubectl -n elastic-system rollout status statefulset/elastic-operator --timeout=300s

  step "Apply eck-stack Application (CI overlay: shrunk values)"
  render_and_rewrite "$REPO_ROOT/tests/e2e/eck" "$WORKDIR/eck.yaml" 1
  kubectl apply -f "$WORKDIR/eck.yaml"
  # Argo ships built-in Lua health for Elastic CRDs, so Healthy already
  # means the ES cluster reports green — asserted explicitly below anyway.
  wait_app eck-stack 900

  step "Verify Elasticsearch/Kibana CRD-reported health"
  # yellow is the healthy steady state of a 1-node cluster: replicas of
  # system indices (e.g. Kibana's) can never assign. Red is the failure.
  retry 42 10 "elasticsearch not green/yellow" \
    bash -c "kubectl -n elastic-system get elasticsearch elasticsearch-sample -o jsonpath='{.status.health}' | grep -qE '^(green|yellow)$'"
  echo "OK: elasticsearch CR reports green/yellow"
  retry 42 10 "kibana not green" \
    bash -c "[[ \"\$(kubectl -n elastic-system get kibana kibana-sample -o jsonpath='{.status.health}')\" == green ]]"
  echo "OK: kibana CR reports green"

  step "Verify ES + Kibana APIs from inside the cluster"
  ensure_probe elastic-system
  local es_pw
  es_pw=$(kubectl -n elastic-system get secret elasticsearch-sample-es-elastic-user \
            -o jsonpath='{.data.elastic}' | base64 -d)
  assert_body elastic-system "https://elasticsearch-sample-es-http:9200/_cluster/health" \
    '"status":"(green|yellow)"' "ES /_cluster/health reports green/yellow" -k -u "elastic:${es_pw}"
  # Service truth beyond cluster color: write a document and search it back.
  probe_curl elastic-system -k -u "elastic:${es_pw}" \
    -X POST -H 'Content-Type: application/json' -d '{"probe":"e2e"}' \
    "https://elasticsearch-sample-es-http:9200/e2e-smoke/_doc?refresh=true" >/dev/null \
    || fail "ES rejected a document write"
  assert_body elastic-system \
    "https://elasticsearch-sample-es-http:9200/e2e-smoke/_search?q=probe:e2e" \
    '"value":[1-9]' "ES indexes and finds a written document" -k -u "elastic:${es_pw}"
  assert_body elastic-system "https://kibana-sample-kb-http:5601/api/status" \
    '"level":"available"' "Kibana /api/status reports available" -k -u "elastic:${es_pw}"
}

profile_haproxy() {
  step "Install cert-manager (the synced manifests contain cert-manager CRs)"
  kubectl apply --server-side -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  wait_rollouts cert-manager 300s \
    deploy/cert-manager deploy/cert-manager-cainjector deploy/cert-manager-webhook

  # ACME account registration from an ephemeral CI cluster is best-effort
  # (shared runner egress IPs hit Let's Encrypt account rate limits), but
  # Argo's built-in health marks Ready=False ClusterIssuers Degraded, which
  # would block the Healthy wait below. CI-only: neutralize ClusterIssuer
  # health so ACME can never gate the profile. Their existence is still
  # asserted after the sync.
  step "CI-only: make ClusterIssuer health non-load-bearing"
  kubectl -n "$NS" patch configmap argocd-cm --type merge -p '{
    "data": {
      "resource.customizations.health.cert-manager.io_ClusterIssuer": "hs = {}\nhs.status = \"Healthy\"\nhs.message = \"e2e: ClusterIssuer health ignored (ACME is best-effort in CI)\"\nreturn hs\n"
    }
  }'

  step "Install MetalLB + production pool name with a CI /32"
  kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
  wait_rollouts metallb-system 300s deploy/controller daemonset/speaker
  # The admission webhook needs its cert injected before CRs apply cleanly.
  retry 12 10 "metallb webhook not admitting IPAddressPool" \
    kubectl apply -f "$REPO_ROOT/tests/e2e/kind/metallb-pool.yaml"

  step "Apply out-of-band haproxy RBAC (getting-started step 3)"
  kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$REPO_ROOT/base/mip-infrastructure/rbac/haproxy-public-rbac.yaml"

  step "Apply haproxy-public-ingress Application"
  render_and_rewrite "$REPO_ROOT/common/haproxy-ingress" "$WORKDIR/haproxy.yaml" 1
  kubectl apply -f "$WORKDIR/haproxy.yaml"
  # Healthy requires the LoadBalancer Service to get its IP from MetalLB, so
  # the pool shim is itself asserted by this wait.
  wait_app haproxy-public-ingress 600

  step "Verify controller, VIP and default certificate"
  kubectl -n ingress-nginx rollout status deploy/haproxy-public-controller --timeout=300s
  local lb_ip
  lb_ip=$(kubectl -n ingress-nginx get svc haproxy-public-controller \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [[ "$lb_ip" == "148.187.143.44" ]] \
    || fail "LoadBalancer got '$lb_ip', expected the pinned 148.187.143.44"
  echo "OK: haproxy-public-controller holds the production VIP"
  kubectl -n ingress-nginx wait certificate/haproxy-public-default-tls \
    --for=condition=Ready --timeout=300s
  echo "OK: default certificate issued (self-signed issuer)"
  # ACME issuers must exist (synced); their Ready state is best-effort in CI.
  kubectl get clusterissuer letsencrypt-public letsencrypt-public-staging >/dev/null
  echo "OK: letsencrypt ClusterIssuers exist"

  step "Verify real ingress traffic against the echo backend"
  kubectl apply -f "$REPO_ROOT/common/haproxy-ingress/test-ingress.yaml"
  kubectl -n default rollout status deploy/test-haproxy-public --timeout=180s
  ensure_probe default
  # The production configmap enforces ssl-redirect, so :80 must answer with
  # a redirect — assert that production behavior instead of expecting content.
  retry 12 10 "haproxy :80 did not answer the ssl-redirect" \
    bash -c "kubectl -n default exec e2e-probe -- curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      -H 'Host: test.example.com' http://haproxy-public-controller.ingress-nginx.svc:80/ \
      | grep -qE '^30[1278]$'"
  echo "OK: :80 redirects to https (ssl-redirect)"
  # Content assertion over https (-k: the default certificate is self-signed
  # for *.mip.chuv.cscs.ch); haproxy routes on the Host header.
  retry 12 10 "haproxy did not route test.example.com to the echo backend" \
    bash -c "kubectl -n default exec e2e-probe -- curl -fsSk --max-time 15 \
      -H 'Host: test.example.com' https://haproxy-public-controller.ingress-nginx.svc:443/ \
      | grep -q 'haproxy-public IngressClass Working'"
  echo "OK: Ingress -> backend content assertion passed (via https)"
  # Negative: an unknown Host must not reach the backend over https (on :80
  # it would just get the ssl-redirect). haproxy answers non-2xx -> curl -f fails.
  if probe_curl default -k -H 'Host: unknown.example.com' \
       "https://haproxy-public-controller.ingress-nginx.svc:443/" >/dev/null 2>&1; then
    fail "haproxy served an unknown Host (default backend leak?)"
  fi
  echo "OK: unknown Host is refused"
}

profile_datacatalog() {
  step "Create CI secrets (datacatalog)"
  bash "$REPO_ROOT/scripts/e2e/ci-secrets.sh" datacatalog

  step "Apply datacatalog Application"
  render_and_rewrite "$REPO_ROOT/tests/e2e/datacatalog" "$WORKDIR/datacatalog.yaml" 1
  kubectl apply -f "$WORKDIR/datacatalog.yaml"
  wait_app datacatalog 900

  step "Verify datacatalog workloads"
  local d
  for d in $(kubectl -n mip-common-datacatalog get deploy -o name); do
    kubectl -n mip-common-datacatalog rollout status "$d" --timeout=300s
  done
  assert_pvcs_bound mip-common-datacatalog

  step "Verify datacatalog service responses"
  ensure_probe mip-common-datacatalog
  assert_body mip-common-datacatalog "http://backend:8090/services/actuator/health" \
    '"status"[[:space:]]*:[[:space:]]*"UP"' "datacatalog backend actuator reports UP"
  assert_body mip-common-datacatalog "http://frontend:80/" \
    '<html|<!DOCTYPE|<!doctype' "datacatalog frontend serves the app"
}

# ---------------------------------- main --------------------------------------

step "e2e profile: $PROFILE (revision under test: $HEAD_SHA)"

step "Create kind cluster '$CLUSTER'"
ensure_kind_cluster

step "Apply Argo CD overlay"
install_argo_overlay

step "Wait for Argo CD HA workloads"
wait_argo_rollouts

step "Apply static AppProjects"
apply_static_appprojects

step "Apply kind StorageClass aliases"
kubectl apply -f "$REPO_ROOT/tests/e2e/kind/storageclasses.yaml"

case "$PROFILE" in
  exareme2)    profile_exareme2 ;;
  mip-stack)   profile_mip_stack ;;
  eck)         profile_eck ;;
  haproxy)     profile_haproxy ;;
  datacatalog) profile_datacatalog ;;
esac

step "All $PROFILE checks passed"
