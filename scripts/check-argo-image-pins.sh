#!/usr/bin/env bash
# scripts/check-argo-image-pins.sh
#
# Check the image digest pins in argo-setup/patches/kustomization.yaml against
# the upstream Argo CD manifest it uses. Renovate bumps the manifest tag but
# not these pins. Exits 1 on any mismatch.
#
# For every image in the upstream manifest:
#   1. The `images:` block has an entry whose `# <tag>` comment is the tag
#      upstream uses.
#   2. The pinned digest is the one the registry serves for that tag
#      (`docker buildx imagetools inspect`).
# It also fails on `images:` entries that upstream no longer uses.
#
# To fix a failure, see argo-setup/README.md, "Bumping Argo CD".
set -euo pipefail

KUSTOMIZATION="argo-setup/patches/kustomization.yaml"

for tool in yq curl docker; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required" >&2
    exit 2
  fi
done

UPSTREAM_URL=$(grep -oE 'https://[^ ]+/manifests/ha/install.yaml' "$KUSTOMIZATION" | head -n1)
if [[ -z "$UPSTREAM_URL" ]]; then
  echo "Could not extract upstream install URL from $KUSTOMIZATION" >&2
  exit 2
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -sSfL "$UPSTREAM_URL" -o "$TMPDIR/upstream.yaml"

# Upstream images as "<name> <tag>", one per line.
grep -oE 'image: [^[:space:]]+' "$TMPDIR/upstream.yaml" \
  | sed -E 's/^image: //; s/:([^:]+)$/ \1/' \
  | sort -u > "$TMPDIR/upstream-images.txt"

# Pins as "<name> <tag comment> <digest>", one per line.
yq '.images[] | .name + " " + (.name | line_comment) + " " + .digest' \
  "$KUSTOMIZATION" | sort -u > "$TMPDIR/pins.txt"

FAIL=0
while read -r name tag; do
  pin=$(awk -v n="$name" '$1 == n' "$TMPDIR/pins.txt")
  if [[ -z "$pin" ]]; then
    echo "MISSING  $name:$tag has no entry in the images: block" >&2
    FAIL=1
    continue
  fi
  read -r _ pinned_tag pinned_digest <<< "$pin"
  if [[ "$pinned_tag" != "$tag" ]]; then
    echo "TAG      $name is pinned as $pinned_tag, upstream uses $tag" >&2
    FAIL=1
    continue
  fi
  digest=$(docker buildx imagetools inspect "$name:$tag" --format '{{.Manifest.Digest}}')
  if [[ "$pinned_digest" != "$digest" ]]; then
    echo "DIGEST   $name:$tag is pinned to $pinned_digest, the registry serves $digest" >&2
    FAIL=1
    continue
  fi
  echo "OK       $name:$tag@$digest"
done < "$TMPDIR/upstream-images.txt"

while read -r name _; do
  if ! awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$TMPDIR/upstream-images.txt"; then
    echo "STALE    $name is pinned but not used upstream" >&2
    FAIL=1
  fi
done < "$TMPDIR/pins.txt"

if [[ "$FAIL" -ne 0 ]]; then
  echo >&2
  echo "Refresh the image pins in $KUSTOMIZATION (argo-setup/README.md, \"Bumping Argo CD\")." >&2
  exit 1
fi
echo "OK: image pins match $UPSTREAM_URL"
