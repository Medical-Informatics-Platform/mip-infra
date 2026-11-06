#!/usr/bin/env bash
# scripts/measure-argocd-usage.sh
#
# Measure the CPU and memory use of every container in the Argo CD namespace,
# to size its requests and limits (argo-setup/README.md, "Resource sizing").
# Reports each container's peak next to its requests and limits, plus
# restarts and OOM kills.
#
# Usage:
#   bash scripts/measure-argocd-usage.sh [--namespace NS] [--duration SECONDS]
#                                        [--interval SECONDS] [--hard-refresh]
#   bash scripts/measure-argocd-usage.sh --peaks [--namespace NS]
#
#   --hard-refresh  annotates every Application in the namespace with
#                   argocd.argoproj.io/refresh=hard at the start, so the
#                   samples include a full re-render (the repo-server and
#                   controller peak). This writes to the cluster.
#   --peaks         instead of sampling, reads each running container's
#                   cgroup once: memory.peak, the highest memory use since
#                   the container started (child processes such as helm and
#                   kustomize included), and cpu.stat, how often its CPU
#                   limit throttled it. Needs cgroup v2 on Linux 5.19 or
#                   later, and kubectl exec.
#
# Needs kubectl with access to the cluster and metrics-server (kubectl top).
# kubectl top reports the working set every ~15 s, so short spikes between
# samples are missed; run it long enough to cover syncs, or use --peaks.
set -euo pipefail

NS=argocd-mip-team
DURATION=1800
INTERVAL=30
HARD_REFRESH=0
PEAKS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS=$2; shift 2 ;;
    --duration) DURATION=$2; shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    --hard-refresh) HARD_REFRESH=1; shift ;;
    --peaks) PEAKS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$PEAKS" -eq 1 ]]; then
  # One line per running container: pod, container, start time, restarts,
  # and why the previous run ended.
  kubectl get pods --namespace "$NS" --output json \
    | jq -r '.items[] | .metadata.name as $p | (.status.containerStatuses // [])[]
        | select(.state.running)
        | [$p, .name, .state.running.startedAt, .restartCount, (.lastState.terminated.reason // "-")] | @tsv' \
    > "${TMPDIR:-/tmp}/argocd-peaks-containers.$$"
  printf '%-52s %-34s %-21s %9s %14s %s\n' POD CONTAINER STARTED "MEM PEAK" "CPU THROTTLED" "(periods)"
  while IFS=$'\t' read -r pod ctr started restarts reason; do
    # memory.peak in bytes; cpu.stat nr_periods/nr_throttled count CFS periods
    # (100 ms) and how many hit the CPU limit (both 0 without a CPU limit).
    # The single-quoted script expands inside the container, not here.
    # shellcheck disable=SC2016
    read -r peak periods throttled < <(kubectl exec --namespace "$NS" "$pod" --container "$ctr" -- \
      sh -c 'p=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo -); s=/sys/fs/cgroup/cpu.stat;
             echo "$p $(awk "/^nr_periods /{print \$2}" $s 2>/dev/null || echo -) $(awk "/^nr_throttled /{print \$2}" $s 2>/dev/null || echo -)"' \
      < /dev/null 2>/dev/null || echo "- - -")
    if [[ "$peak" =~ ^[0-9]+$ ]]; then peak="$((peak / 1048576))Mi"; else peak="n/a"; fi
    if [[ "$periods" =~ ^[0-9]+$ && "$periods" -gt 0 ]]; then
      thr=$(awk -v t="$throttled" -v p="$periods" 'BEGIN { printf "%.1f%%", 100 * t / p }')
    else
      thr="-"; periods="-"
    fi
    printf '%-52s %-34s %-21s %9s %14s %s\n' "$pod" "$ctr" "$started" "$peak" "$thr" "($periods)"
    if [[ "$restarts" -gt 0 ]]; then
      echo "  ^ restarted $restarts times, last ended $reason: the peak covers only the current run"
    fi
  done < "${TMPDIR:-/tmp}/argocd-peaks-containers.$$"
  rm -f "${TMPDIR:-/tmp}/argocd-peaks-containers.$$"
  exit 0
fi

if ! kubectl top pod --namespace "$NS" >/dev/null 2>&1; then
  echo "kubectl top failed: is metrics-server installed?" >&2
  exit 2
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/argocd-usage.XXXXXX")
SAMPLES="$OUT/samples.txt"
: > "$SAMPLES"

if [[ "$HARD_REFRESH" -eq 1 ]]; then
  kubectl annotate applications.argoproj.io --all --namespace "$NS" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  echo "Requested a hard refresh of every Application in $NS"
fi

# Pod names lose their replica suffix, so replicas pool into one workload:
# Deployment pods end in -<hash>-<id>, StatefulSet pods in -<ordinal>.
workload() {
  sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[0-9]+$//'
}

end=$(( $(date +%s) + DURATION ))
count=0
echo "Sampling $NS every ${INTERVAL}s for ${DURATION}s, into $SAMPLES"
while [[ $(date +%s) -lt $end ]]; do
  # POD CONTAINER CPU(m) MEMORY(Mi)
  kubectl top pod --namespace "$NS" --containers --no-headers 2>/dev/null \
    | awk '{ cpu = $3; mem = $4; sub(/m$/, "", cpu); sub(/Mi$/, "", mem); print $1, $2, cpu, mem }' \
    >> "$SAMPLES" || true
  count=$((count + 1))
  sleep "$INTERVAL"
done
echo "Took $count samples"

# Requests and limits as WORKLOAD CONTAINER REQ_CPU REQ_MEM LIM_CPU LIM_MEM.
kubectl get pods --namespace "$NS" --output json \
  | jq -r '.items[] | .metadata.name as $p | .spec.containers[]
      | [$p, .name, (.resources.requests.cpu // "-"), (.resources.requests.memory // "-"),
         (.resources.limits.cpu // "-"), (.resources.limits.memory // "-")] | @tsv' \
  | while IFS=$'\t' read -r pod ctr rc rm lc lm; do
      echo "$(echo "$pod" | workload) $ctr $rc $rm $lc $lm"
    done | sort -u > "$OUT/specs.txt"

while read -r pod ctr cpu mem; do
  echo "$(echo "$pod" | workload) $ctr $cpu $mem"
done < "$SAMPLES" > "$OUT/by-workload.txt"

echo
printf '%-34s %-34s %8s %8s   %-22s %-22s\n' WORKLOAD CONTAINER "PEAK CPU" "PEAK MEM" "REQUESTS cpu/mem" "LIMITS cpu/mem"
awk '
  NR == FNR { spec[$1 " " $2] = $3 "/" $4 " " $5 "/" $6; next }
  { k = $1 " " $2; if ($3 + 0 > cpu[k]) cpu[k] = $3 + 0; if ($4 + 0 > mem[k]) mem[k] = $4 + 0; seen[k] = 1 }
  END {
    for (k in seen) {
      split(k, a, " "); split(spec[k], s, " ")
      printf "%-34s %-34s %7dm %6dMi   %-22s %-22s\n", a[1], a[2], cpu[k], mem[k], s[1], s[2]
    }
  }' "$OUT/specs.txt" "$OUT/by-workload.txt" | sort

echo
echo "Restarts and last termination reasons:"
kubectl get pods --namespace "$NS" --output json \
  | jq -r '.items[] | .metadata.name as $p
      | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
      | select(.restartCount > 0 or .lastState.terminated)
      | "  \($p)/\(.name): restarts=\(.restartCount) last=\(.lastState.terminated.reason // "-")"' \
  | sort | { grep . || echo "  none"; }
echo
echo "Raw samples: $SAMPLES"
