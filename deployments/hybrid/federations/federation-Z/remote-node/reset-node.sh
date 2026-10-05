#!/usr/bin/env bash
# Returns a node that carries an earlier MicroK8s or Submariner attempt to a
# clean state, so that the procedure in this directory can run from step 1.
#
# Removes: the microk8s snap and its data, the helm and kubectl snaps when
# present (MicroK8s provides both), subctl,
# the MicroK8s kubeconfig and Helm caches of the invoking user, the persisted
# cluster ID, leftover credential files in the invoking user's home, and the
# Submariner and Calico network state (interfaces, IPsec state, policy routes).
# Remaining kernel state (iptables chains, ipsets) is cleared by a reboot.
#
# Usage:
#   sudo ./reset-node.sh                    # remove everything listed above
#   sudo ./reset-node.sh --keep-cluster-id  # keep the persisted cluster ID
#   sudo ./reset-node.sh --reboot           # reboot when done
#
# After the reset, remove the stale registration of this node on the central
# cluster (README, section "Removing a remote node") before joining again.
set -uo pipefail

KEEP_ID=false
REBOOT=false
for arg in "$@"; do
  case "$arg" in
    --keep-cluster-id) KEEP_ID=true ;;
    --reboot) REBOOT=true ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

log() { printf '==> %s\n' "$*"; }

user="${SUDO_USER:-}"
user_home=""
if [[ -n "$user" && "$user" != root ]]; then
  user_home="$(getent passwd "$user" | cut -d: -f6)"
fi

if snap list microk8s >/dev/null 2>&1; then
  log "Removing MicroK8s ($(snap list microk8s | awk 'NR==2 {print $2, "from", $4}')) and its data"
  snap remove --purge microk8s
else
  log "MicroK8s snap not installed"
fi

for s in helm kubectl; do
  if snap list "$s" >/dev/null 2>&1; then
    log "Removing the ${s} snap (${s} is provided by MicroK8s)"
    snap remove --purge "$s"
  fi
done

for f in /usr/local/bin/subctl /root/.local/bin/subctl ${user_home:+"$user_home/.local/bin/subctl"}; do
  if [[ -f "$f" ]]; then
    log "Removing $f"
    rm -f "$f"
  fi
done

for d in /root/.cache/helm /root/.config/helm /root/.local/share/helm \
         ${user_home:+"$user_home/.cache/helm" "$user_home/.config/helm" "$user_home/.local/share/helm"}; do
  if [[ -d "$d" ]]; then
    log "Removing Helm state in $d"
    rm -rf "$d"
  fi
done

for cfg in /root/.kube/config ${user_home:+"$user_home/.kube/config"}; do
  if [[ -f "$cfg" ]] && grep -q '16443' "$cfg"; then
    log "Removing the MicroK8s kubeconfig $cfg"
    rm -f "$cfg"
  fi
done

if [[ "$KEEP_ID" == false ]]; then
  for f in /etc/submariner-remote/cluster-id ${user_home:+"$user_home/.config/submariner-remote/cluster-id"}; do
    if [[ -f "$f" ]]; then
      log "Removing the persisted cluster ID $f ($(tr -d '[:space:]' <"$f"))"
      rm -f "$f"
    fi
  done
fi

if [[ -n "$user_home" ]]; then
  while IFS= read -r -d '' f; do
    log "Removing leftover credential file $f"
    if command -v shred >/dev/null 2>&1; then shred -u "$f"; else rm -f "$f"; fi
  done < <(find "$user_home" -maxdepth 3 -type f \
             \( -name 'broker-token.txt' -o -name 'broker-ca-base64.txt' -o -name 'broker-psk.txt' \
                -o -name 'local-values.yaml' -o -name 'secrets-values.yaml' -o -name 'broker-info.subm*' \) -print0)
fi

log "Clearing Submariner and Calico network state"
for link in vx-submariner vxlan.calico; do
  if ip link show "$link" >/dev/null 2>&1; then
    ip link del "$link" && echo "    removed interface ${link}"
  fi
done
ip xfrm state flush 2>/dev/null || true
ip xfrm policy flush 2>/dev/null || true
ip route flush table 150 2>/dev/null || true
while read -r prio; do
  ip rule del priority "$prio" 2>/dev/null || true
done < <(ip rule show | awk '/lookup 150/ {sub(":", "", $1); print $1}')

# Remove the node label state file MicroK8s leaves behind and the launch config.
rm -rf /var/snap/microk8s 2>/dev/null || true

cat <<EOF

Reset complete. Remaining kernel state (iptables chains, ipsets) is cleared by a
reboot; continue with preflight.sh and setup-tools.sh afterwards.
On the central cluster, delete the stale broker objects of this node's previous
cluster ID (README, section "Removing a remote node").
EOF

if [[ "$REBOOT" == true ]]; then
  log "Rebooting"
  systemctl reboot
fi
