#!/usr/bin/env bash
# scripts/e2e/changed-profiles.sh
#
# Maps the files changed on a PR branch to e2e profiles. Single source of
# truth for the path->profile mapping; keep three places aligned when a
# component moves or a Renovate manager is added:
#   - this mapping
#   - the `paths:` trigger list in .github/workflows/e2e.yml (must stay a
#     superset of what maps to a profile here)
#   - the managerFilePatterns in renovate.json5 (what Renovate PRs touch)
#
# Usage: scripts/e2e/changed-profiles.sh [base-ref]   (default origin/main)
# Prints `<profile>=true|false` lines for: exareme2 mip-stack eck haproxy
# datacatalog render — append them to $GITHUB_OUTPUT in CI.
#
# (plain variables, not associative arrays: must run on macOS bash 3.2 too)
set -euo pipefail

BASE=${1:-origin/main}

exareme2=false
mip_stack=false
eck=false
haproxy=false
datacatalog=false
render=false

all_kind_profiles() {
  exareme2=true; mip_stack=true; eck=true
  haproxy=true; datacatalog=true; render=true
}

while IFS= read -r f; do
  case "$f" in
    # --- shared e2e harness: everything must still pass ---
    scripts/e2e/*|tests/e2e/kind/*|.github/workflows/e2e.yml)
      all_kind_profiles ;;

    # --- federation apps (Renovate: targetRevision regex manager +
    #     exaflow_images.version manager; `federations-` override PRs) ---
    deployments/shared-apps/exareme2/*)                    exareme2=true ;;
    deployments/shared-apps/mip-stack/*)                   mip_stack=true ;;
    deployments/*/federations/*exareme2*)                  exareme2=true; render=true ;;
    deployments/*/federations/*mip-stack*)                 mip_stack=true; render=true ;;
    # remaining federation files (kustomization, netpols, wrapper app)
    deployments/*/federations/*)                           exareme2=true; mip_stack=true; render=true ;;
    tests/e2e/federation/*)                                exareme2=true; mip_stack=true ;;

    # --- common components ---
    common/monitoring/*|tests/e2e/eck/*)                   eck=true ;;
    common/haproxy-ingress/*)                              haproxy=true ;;
    base/mip-infrastructure/rbac/haproxy-public-rbac.yaml) haproxy=true ;;
    common/datacatalog/*|tests/e2e/datacatalog/*)          datacatalog=true ;;

    # --- render-only (submariner cannot be meaningfully e2e-tested on a
    #     single kind cluster; its bumped chart versions are build-checked) ---
    common/submariner/*)                                   render=true ;;
  esac
done < <(git diff --name-only "$BASE"...HEAD)

# mip-stack deploys exareme2 too; no need to run the smaller profile as well.
if [[ "$mip_stack" == "true" ]]; then
  exareme2=false
fi

echo "exareme2=$exareme2"
echo "mip-stack=$mip_stack"
echo "eck=$eck"
echo "haproxy=$haproxy"
echo "datacatalog=$datacatalog"
echo "render=$render"
