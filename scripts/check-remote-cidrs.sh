#!/usr/bin/env bash
# The remote networks of a hybrid federation are written in three places of its
# directory, because an ipBlock, Helm values and the node's values cannot share
# a variable. This check keeps them aligned:
#   1. remote-node/submariner-values*.yaml, one file per node: the source.
#   2. mip-infrastructure/remote-networks.yaml: one entry per node with the same
#      pod and service CIDR; input of the chart common/security/remote-networks.
#   3. mip-infrastructure/submariner-policies/network-policy.yaml: every rule
#      with an ipBlock lists exactly the pod CIDRs of all nodes.
# It also checks that:
#   - no network overlaps another one or a central network;
#   - the policy rendered for each federation passes its pod CIDRs to its own
#     namespace only and ends, in each direction, with a Deny of all its networks;
#   - common/security/remote-clusters names no network and no namespace.
#
# Usage: scripts/check-remote-cidrs.sh   (needs yq v4 and helm; exit 1 on drift)
set -euo pipefail

cd "$(dirname "$0")/.."
for tool in yq helm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 2; }
done

chart=common/security/remote-networks
tier_dir=common/security/remote-clusters
rc=0
fail() { echo "FAIL $*"; rc=1; }
# A list separated by commas, spaces or newlines, as a sorted comma-separated set.
norm() { tr ', ' '\n' | sed '/^$/d' | sort -u | paste -sd, -; }
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
overlap() { # $1 $2 IPv4 CIDRs: true when one contains the other
  local bits=${1#*/} other=${2#*/} mask
  (( other < bits )) && bits=$other
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip2int "${1%/*}") & mask) == ($(ip2int "${2%/*}") & mask) ))
}

# --- 1. declared networks ------------------------------------------------------------------------
# feds:  "<namespace> <federation directory>"; the namespace is the directory name in lower case,
#        as in the ApplicationSets.
# nodes: "<namespace> <pod CIDR> <service CIDR>" for every node values file.
feds=""
nodes=""
for fed in deployments/hybrid/federations/*/; do
  fed=${fed%/}
  ns=$(basename "$fed" | tr '[:upper:]' '[:lower:]')
  feds+="$ns $fed"$'\n'
  for values in "$fed"/remote-node/submariner-values*.yaml; do
    [[ -f "$values" ]] || continue
    pod=$(yq -r '.submariner.clusterCidr // ""' "$values")
    svc=$(yq -r '.submariner.serviceCidr // ""' "$values")
    ok=1
    for cidr in "$pod" "$svc"; do
      if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        fail "$values: submariner.clusterCidr and submariner.serviceCidr must be IPv4 CIDRs (found '${cidr}')"
        ok=0
      fi
    done
    if (( ok )); then nodes+="$ns $pod $svc"$'\n'; fi
  done
done
if [[ -z "$nodes" ]]; then
  echo "no remote-node values files found under deployments/hybrid/federations"
  exit 1
fi

# --- 2. no overlap, among remote networks and with the central cluster -----------------------------
# Central networks: the operator values of this cluster, and the ipBlocks of the remote worker's
# NetworkPolicy, which admits the central pod and service networks only.
remote=$(awk '{print $2; print $3}' <<<"$nodes" | sed '/^$/d')
central=""
if [[ -f common/submariner/operator/values.yaml ]]; then
  central+=$(yq -r '[.submariner.clusterCidr, .submariner.serviceCidr] | .[] | select(. != null and . != "")' \
    common/submariner/operator/values.yaml)$'\n'
fi
for pol in deployments/hybrid/federations/*/remote-node/exaflow-worker/networkpolicy.yaml; do
  [[ -f "$pol" ]] || continue
  central+=$(yq -r '.. | select(tag == "!!map" and has("ipBlock")) | .ipBlock.cidr' "$pol")$'\n'
done
central=$(sed '/^$/d' <<<"$central" | sort -u)
# shellcheck disable=SC2086  # one CIDR per word
set -- $remote
while (( $# > 1 )); do
  a=$1; shift
  for b in "$@"; do
    if overlap "$a" "$b"; then fail "remote networks overlap: $a and $b (a network belongs to one node of one federation)"; fi
  done
done
for r in $remote; do
  for c in $central; do
    if overlap "$r" "$c"; then fail "remote network $r overlaps the central network $c"; fi
  done
done

# --- 3. per federation -----------------------------------------------------------------------------
while read -r ns fed; do
  [[ -n "$ns" ]] || continue
  nets_file=$fed/mip-infrastructure/remote-networks.yaml
  pol=$fed/mip-infrastructure/submariner-policies/network-policy.yaml
  want_nodes=$(awk -v ns="$ns" '$1 == ns {print $2 "+" $3}' <<<"$nodes" | norm)
  want_pods=$(awk -v ns="$ns" '$1 == ns {print $2}' <<<"$nodes" | norm)
  want_all=$(awk -v ns="$ns" '$1 == ns {print $2; print $3}' <<<"$nodes" | norm)

  # remote-networks.yaml: one entry per node values file
  got_nodes=""
  if [[ -f "$nets_file" ]]; then
    got_nodes=$(yq -r '.remoteNodes[] | (.podCidr // "") + "+" + (.serviceCidr // "")' "$nets_file" | norm)
  fi
  if [[ "$got_nodes" != "$want_nodes" ]]; then
    fail "$nets_file lists [$got_nodes], the node values files of $ns declare [$want_nodes] (podCidr+serviceCidr per node)"
    continue
  fi
  [[ -n "$want_nodes" ]] || continue  # a hybrid federation without remote nodes

  # submariner-policies: every rule with an ipBlock lists exactly the pod CIDRs
  if [[ ! -f "$pol" ]]; then
    fail "$pol is missing"
  else
    checked=0
    # shellcheck disable=SC2016  # $name is a yq variable
    while IFS='|' read -r name cidrs; do
      [[ -n "$cidrs" ]] || continue
      checked=$((checked + 1))
      got=$(norm <<<"$cidrs")
      [[ "$got" == "$want_pods" ]] || fail "$pol: a rule of NetworkPolicy $name lists [$got], the remote pod CIDRs of $ns are [$want_pods]"
    done < <(yq -r '
      select(.kind == "NetworkPolicy") | .metadata.name as $name |
      (
        (.spec.ingress[]? | [.from[]? | select(has("ipBlock")) | .ipBlock.cidr]),
        (.spec.egress[]? | [.to[]? | select(has("ipBlock")) | .ipBlock.cidr])
      ) | [$name, join(",")] | join("|")' "$pol")
    (( checked > 0 )) || fail "$pol: no rule with an ipBlock"
  fi

  # The policy the chart renders from the file. One line per rule: direction, action, remote nets,
  # namespaceSelector of the local side ("-" when absent).
  if ! rendered=$(helm template check "$chart" --set-string "targetNamespace=$ns" -f "$nets_file" 2>&1); then
    fail "$nets_file: the chart $chart does not render: $(grep -m 1 -E '^Error' <<<"$rendered" || tail -n 1 <<<"$rendered")"
    continue
  fi
  name=$(yq -r 'select(.kind == "GlobalNetworkPolicy") | .metadata.name' <<<"$rendered")
  [[ "$name" == "remote-clusters.$ns" ]] || fail "$chart renders the policy '${name}' for $ns, expected remote-clusters.$ns"
  rules=$(yq -r '
    select(.kind == "GlobalNetworkPolicy") | .spec |
    (
      (.ingress[] | ["ingress", .action, ((.source.nets // ["-"]) | join(",")), (.destination.namespaceSelector // "-")]),
      (.egress[] | ["egress", .action, ((.destination.nets // ["-"]) | join(",")), (.source.namespaceSelector // "-")])
    ) | join("|")' <<<"$rendered")
  for dir in ingress egress; do
    lines=$(grep "^$dir|" <<<"$rules" || true)
    n=$(sed '/^$/d' <<<"$lines" | wc -l | tr -d ' ')
    if (( n < 2 )); then
      fail "$chart for $ns: $dir needs at least one Pass rule and the Deny rule"
      continue
    fi
    i=0
    while IFS='|' read -r _ action nets sel; do
      i=$((i + 1))
      got=$(norm <<<"$nets")
      if (( i == n )); then
        [[ "$action" == Deny && "$sel" == "-" && "$got" == "$want_all" ]] \
          || fail "$chart for $ns: the last $dir rule must be the Deny of [$want_all] (found $action [$got] $sel)"
      else
        [[ "$action" == Pass && "$sel" == "kubernetes.io/metadata.name == '$ns'" && "$got" == "$want_pods" ]] \
          || fail "$chart for $ns: $dir rule $i must pass [$want_pods] to the namespace $ns only (found $action [$got] $sel)"
      fi
    done <<<"$lines"
  done
done <<<"$feds"

# --- 4. the shared tier directory names no network and no namespace --------------------------------
if grep -nE '^[[:space:]-]*(nets|notNets|namespaceSelector):' "$tier_dir"/*.yaml; then
  fail "$tier_dir must stay generic: networks and namespaces belong in the federation's remote-networks.yaml"
fi

[[ $rc -eq 0 ]] && echo "OK: remote networks agree across node values, remote-networks.yaml, federation policies and the rendered tier policy"
exit $rc
