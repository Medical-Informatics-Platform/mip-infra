#!/usr/bin/env bash
# Installs the command-line tools the remote-node procedure needs on a fresh
# Ubuntu 24.04 host: base packages, snapd, and subctl pinned to the Submariner
# version deployed on the central cluster. kubectl and helm are provided by the
# MicroK8s snap in the next step (setup-microk8s.sh creates the aliases).
#
# Usage:
#   sudo ./setup-tools.sh
#   sudo SUBMARINER_VERSION=0.24.1 ./setup-tools.sh
#
# Re-running is safe: every step checks the current state first.
set -euo pipefail

# renovate: datasource=github-releases depName=submariner-io/releases
SUBMARINER_VERSION="${SUBMARINER_VERSION:-0.24.2}"
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

# subctl is downloaded straight from the release asset and pinned to the
# Submariner version. It must match the chart version deployed on the central
# cluster (common/submariner/{broker,operator}/kustomization.yaml).
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
  url="https://github.com/submariner-io/releases/releases/download/v${SUBMARINER_VERSION}/subctl-v${SUBMARINER_VERSION}-linux-${arch}.tar.xz"
  curl -fsSL --max-time 120 -o "$tmp/subctl.tar.xz" "$url"
  tar -xJf "$tmp/subctl.tar.xz" -C "$tmp"
  # The archive layout has changed between releases; locate the binary by name.
  bin="$(find "$tmp" -type f -name "subctl*linux-${arch}*" | head -1)"
  [[ -n "$bin" ]] || bin="$(find "$tmp" -type f -name 'subctl*' ! -name '*.tar.xz' | head -1)"
  [[ -n "$bin" ]] || { echo "subctl binary not found in ${url}" >&2; exit 1; }
  install -m 0755 "$bin" "$SUBCTL_BIN"
fi

log "Tool versions"
"$SUBCTL_BIN" version
snap version | head -1
echo
echo "kubectl and helm are provided by MicroK8s. Run setup-microk8s.sh next."
