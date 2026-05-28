#!/usr/bin/env bash
# scripts/check-upstream-argo-clusterroles.sh
#
# Compare the upstream Argo CD ClusterRole rules against a snapshot we
# explicitly reviewed and committed. Fails (exit 1) if upstream has changed
# in any way since the snapshot.
#
# Why this exists:
#   argo-setup/patches/patch-argocd-{application-controller,server,
#   applicationset-controller}-clusterrole.yaml fully *replace* the upstream
#   ClusterRole rules. If upstream adds a new permission in a later release
#   (e.g. for a new resource Argo now needs to manage natively) and we just
#   keep our patch unchanged, the new rule disappears silently and Argo
#   syncs start failing in obscure ways.
#
# How to update the snapshot:
#   1. Bump the upstream tag in argo-setup/patches/kustomization.yaml.
#   2. Run this script.
#   3. Read the diff carefully — does upstream's new rule belong in our
#      tightened ClusterRoles, or is it intentionally dropped?
#   4. If keeping the change, copy the upstream rules into the snapshot:
#        bash scripts/check-upstream-argo-clusterroles.sh --update
#   5. Commit the snapshot update in the same PR as the version bump,
#      with a message explaining what changed and why.
set -euo pipefail

SNAPSHOT="argo-setup/upstream-snapshot/clusterroles.yaml"
ROLES_SNAPSHOT="argo-setup/upstream-snapshot/roles.yaml"
KUSTOMIZATION="argo-setup/patches/kustomization.yaml"
TARGETS=(
  argocd-application-controller
  argocd-server
  argocd-applicationset-controller
)
# Namespaced Roles. We don't replace these (we inherit upstream verbatim) so
# the goal of snapshotting is purely drift detection: if upstream broadens
# any Role we want a forced review.
ROLE_TARGETS=(
  argocd-application-controller
  argocd-applicationset-controller
  argocd-dex-server
  argocd-notifications-controller
  argocd-redis-ha
  argocd-redis-ha-haproxy
  argocd-server
)

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (https://github.com/mikefarah/yq)" >&2
  exit 2
fi

UPSTREAM_URL=$(grep -oE 'https://[^ ]+/manifests/ha/install.yaml' "$KUSTOMIZATION" | head -n1)
if [[ -z "$UPSTREAM_URL" ]]; then
  echo "Could not extract upstream install URL from $KUSTOMIZATION" >&2
  exit 2
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -sSfL "$UPSTREAM_URL" -o "$TMPDIR/upstream.yaml"

# Extract only the ClusterRoles we care about, normalized (sorted keys, sorted
# verbs/resources/apiGroups inside each rule) so trivial reorderings do not
# trip the diff.
extract() {
  local src=$1
  for name in "${TARGETS[@]}"; do
    yq -P 'select(.kind=="ClusterRole" and .metadata.name=="'"$name"'") |
            {"name": .metadata.name,
             "rules": (.rules // [] | map(
                {"apiGroups": (.apiGroups // [] | sort),
                 "resources": (.resources // [] | sort),
                 "resourceNames": (.resourceNames // [] | sort),
                 "verbs": (.verbs // [] | sort),
                 "nonResourceURLs": (.nonResourceURLs // [] | sort)}
             ) | sort_by(.apiGroups, .resources, .verbs))}' "$src"
    echo "---"
  done
}

extract_roles() {
  local src=$1
  for name in "${ROLE_TARGETS[@]}"; do
    yq -P 'select(.kind=="Role" and .metadata.name=="'"$name"'") |
            {"name": .metadata.name,
             "rules": (.rules // [] | map(
                {"apiGroups": (.apiGroups // [] | sort),
                 "resources": (.resources // [] | sort),
                 "resourceNames": (.resourceNames // [] | sort),
                 "verbs": (.verbs // [] | sort)}
             ) | sort_by(.apiGroups, .resources, .verbs))}' "$src"
    echo "---"
  done
}

normalize_for_diff() {
  local src=$1
  local dest=$2
  # Canonicalize YAML formatting while suppressing document separators so the
  # diff is semantic rather than tied to a specific yq pretty-print style.
  yq -P -N '.' "$src" > "$dest"
}

extract "$TMPDIR/upstream.yaml" > "$TMPDIR/upstream-extracted.yaml"
extract_roles "$TMPDIR/upstream.yaml" > "$TMPDIR/upstream-roles.yaml"

normalize_for_diff "$TMPDIR/upstream-extracted.yaml" "$TMPDIR/upstream-extracted.norm.yaml"
normalize_for_diff "$TMPDIR/upstream-roles.yaml" "$TMPDIR/upstream-roles.norm.yaml"

if [[ "${1:-}" == "--update" ]]; then
  mkdir -p "$(dirname "$SNAPSHOT")"
  cp "$TMPDIR/upstream-extracted.yaml" "$SNAPSHOT"
  cp "$TMPDIR/upstream-roles.yaml" "$ROLES_SNAPSHOT"
  echo "Snapshots updated: $SNAPSHOT, $ROLES_SNAPSHOT"
  exit 0
fi

if [[ ! -f "$SNAPSHOT" || ! -f "$ROLES_SNAPSHOT" ]]; then
  echo "Snapshot missing: $SNAPSHOT or $ROLES_SNAPSHOT" >&2
  echo "Run with --update to create the initial snapshots, then commit them." >&2
  exit 1
fi

DRIFT=0
normalize_for_diff "$SNAPSHOT" "$TMPDIR/snapshot.norm.yaml"
normalize_for_diff "$ROLES_SNAPSHOT" "$TMPDIR/roles-snapshot.norm.yaml"

if ! diff -u "$TMPDIR/snapshot.norm.yaml" "$TMPDIR/upstream-extracted.norm.yaml"; then
  DRIFT=1
fi
if ! diff -u "$TMPDIR/roles-snapshot.norm.yaml" "$TMPDIR/upstream-roles.norm.yaml"; then
  DRIFT=1
fi

if [[ "$DRIFT" -eq 0 ]]; then
  echo "OK — upstream Argo CD ClusterRoles + Roles unchanged since last review."
  exit 0
fi

cat >&2 <<'EOF'

------------------------------------------------------------------------------
Upstream Argo CD ClusterRoles have drifted from our last-reviewed snapshot.

Read the diff above carefully. Decide for each upstream change whether it
belongs in our tightened ClusterRoles
(argo-setup/patches/patch-argocd-*-clusterrole.yaml) or whether we keep
ignoring it.

Once decisions are made and the patches updated, refresh the snapshot:
    bash scripts/check-upstream-argo-clusterroles.sh --update

Commit the snapshot update in the same PR as the upstream version bump.
------------------------------------------------------------------------------
EOF
exit 1
