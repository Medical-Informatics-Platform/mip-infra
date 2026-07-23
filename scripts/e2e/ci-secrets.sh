#!/usr/bin/env bash
# scripts/e2e/ci-secrets.sh
#
# Non-interactive CI equivalent of scripts/gen_secrets.sh for the ephemeral
# kind e2e cluster. Creates the secrets the federation and datacatalog apps
# reference, with dummy Keycloak credentials (authentication is disabled in
# the CI values) and generated DB passwords. Idempotent: existing secrets are
# left untouched.
#
# Usage: bash scripts/e2e/ci-secrets.sh [federation|datacatalog]
#   (no argument = both)
set -euo pipefail

TARGET=${1:-all}
FED_NS=federation-a
DC_NS=mip-common-datacatalog

gen_password() {
  # Same shape as gen_secrets.sh: 24-char alphanumeric.
  local pw rc
  set +o pipefail
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c24)"
  rc=$?
  set -o pipefail
  if [[ $rc -ne 0 || -z "$pw" ]]; then
    echo "failed to generate password" >&2
    exit 1
  fi
  printf '%s' "$pw"
}

ensure_ns() {
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f -
}

secret_exists() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

if [[ "$TARGET" == "all" || "$TARGET" == "federation" ]]; then
  ensure_ns "$FED_NS"

  if secret_exists "$FED_NS" keycloak-credentials; then
    echo "[skip] $FED_NS/keycloak-credentials exists"
  else
    kubectl -n "$FED_NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-credentials
type: Opaque
stringData:
  client-id: e2e-dummy
  client-secret: $(gen_password)
EOF
    echo "[ok ] $FED_NS/keycloak-credentials"
  fi

  if secret_exists "$FED_NS" mip-secret; then
    echo "[skip] $FED_NS/mip-secret exists"
  else
    kubectl -n "$FED_NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mip-secret
type: Opaque
stringData:
  platform-backend-db.DB_ADMIN_USER: postgres
  platform-backend-db.DB_ADMIN_PASSWORD: $(gen_password)
  platform-backend-db.PLATFORM_DB_USER: portal
  platform-backend-db.PLATFORM_DB_PASSWORD: $(gen_password)
EOF
    echo "[ok ] $FED_NS/mip-secret"
  fi
fi

if [[ "$TARGET" == "all" || "$TARGET" == "datacatalog" ]]; then
  ensure_ns "$DC_NS"

  if secret_exists "$DC_NS" datacatalog-secrets; then
    echo "[skip] $DC_NS/datacatalog-secrets exists"
  else
    kubectl -n "$DC_NS" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: datacatalog-secrets
type: Opaque
stringData:
  keycloak.client-id: e2e-dummy
  keycloak.client-secret: $(gen_password)
  db.user: datacatalog
  db.password: $(gen_password)
EOF
    echo "[ok ] $DC_NS/datacatalog-secrets"
  fi
fi
