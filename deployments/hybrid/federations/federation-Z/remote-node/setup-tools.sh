#!/usr/bin/env bash
# Installs the command-line tools the remote-node procedure needs on a fresh
# Ubuntu 24.04 host: base packages, snapd, and subctl pinned to the Submariner
# version deployed on the central cluster. kubectl and helm are provided by the
# MicroK8s snap in the next step (setup-microk8s.sh creates the aliases).
#
# Usage:
#   sudo ./setup-tools.sh
#   sudo SUBMARINER_VERSION=0.25.0 ./setup-tools.sh
#
# Re-running is safe: every step checks the current state first.
set -euo pipefail

# renovate: datasource=github-releases depName=submariner-io/releases
SUBMARINER_VERSION="${SUBMARINER_VERSION:-0.25.0}"
SUBCTL_BIN="${SUBCTL_BIN:-/usr/local/bin/subctl}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

log() { printf '==> %s\n' "$*"; }

arch="$(dpkg --print-architecture)"

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl jq openssl python3 xz-utils netcat-openbsd

if ! command -v snap >/dev/null 2>&1; then
  log "Installing snapd"
  apt-get install -y snapd
fi

# subctl comes from the release asset, pinned to the Submariner version and
# checked against the release's SHA-256 list. Its version must match the
# central chart (common/submariner/operator/kustomization.yaml).
installed=""
if [[ -x "$SUBCTL_BIN" ]]; then
  installed="$("$SUBCTL_BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
if [[ "$installed" == "v${SUBMARINER_VERSION}" ]]; then
  log "subctl ${installed} already installed"
else
  log "Installing subctl v${SUBMARINER_VERSION} (${arch})"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/submariner-io/releases/releases/download/v${SUBMARINER_VERSION}"
  name="subctl-v${SUBMARINER_VERSION}-linux-${arch}.tar.xz"
  url="${base}/${name}"
  curl -fsSL --max-time 120 -o "$tmp/$name" "$url"
  curl -fsSL --max-time 60 -o "$tmp/subctl-checksums.txt" "${base}/subctl-checksums.txt"
  (cd "$tmp" && grep -E "^[0-9a-f]{64}  ${name}\$" subctl-checksums.txt | sha256sum -c --quiet -) \
    || { echo "SHA-256 of ${name} does not match ${base}/subctl-checksums.txt" >&2; exit 1; }
  mkdir "$tmp/extract"
  tar -xJf "$tmp/$name" -C "$tmp/extract"
  # Archive layout: subctl-vX/subctl-vX-linux-<arch> up to 0.24, subctl-vX/subctl from 0.25.
  bin="$(find "$tmp/extract" -type f -name "subctl*linux-${arch}*" | head -1)"
  [[ -n "$bin" ]] || bin="$(find "$tmp/extract" -type f -name subctl | head -1)"
  [[ -n "$bin" ]] || { echo "subctl binary not found in ${url}" >&2; exit 1; }
  # Run it once before replacing the installed binary.
  "$bin" version >/dev/null 2>&1 || { echo "the subctl binary from ${url} does not run on this host" >&2; exit 1; }
  install -m 0755 "$bin" "$SUBCTL_BIN"
fi

log "Tool versions"
"$SUBCTL_BIN" version
snap version | head -1
echo
echo "kubectl and helm are provided by MicroK8s. Run setup-microk8s.sh next."
