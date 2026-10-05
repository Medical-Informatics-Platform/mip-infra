#!/usr/bin/env bash
# Every remote CIDR declared for a hybrid federation must appear in the
# federation's submariner-policies (pod CIDR) and in the cluster-wide Calico
# deny (pod and service CIDR). Kubernetes ipBlock and Calico nets are
# literals, so this check is what keeps the three places aligned.
#
# Usage: scripts/check-remote-cidrs.sh   (from the repository root; exit 1 on drift)
set -euo pipefail

cd "$(dirname "$0")/.."
gnp=common/security/remote-clusters/global-deny-remote-cidrs.yaml
rc=0
found=0
for values in deployments/hybrid/federations/*/remote-node/submariner-values*.yaml; do
  [[ -f "$values" ]] || continue
  found=1
  fed=${values%%/remote-node/*}
  pol=$fed/mip-infrastructure/submariner-policies/network-policy.yaml
  for key in clusterCidr serviceCidr; do
    cidr=$(sed -n "s/^ *$key: *\([0-9./]*\).*/\1/p" "$values")
    [[ -n "$cidr" ]] || continue
    grep -qF -- "$cidr" "$gnp" || { echo "FAIL $cidr ($values) missing in $gnp"; rc=1; }
    [[ $key == serviceCidr ]] && continue
    grep -qF -- "$cidr" "$pol" || { echo "FAIL $cidr ($values) missing in $pol"; rc=1; }
  done
done
if [[ $found -eq 0 ]]; then
  echo "no remote-node values files found under deployments/hybrid/federations"
  exit 1
fi
[[ $rc -eq 0 ]] && echo "OK: remote CIDRs are consistent across values, federation policies and the global deny"
exit $rc
