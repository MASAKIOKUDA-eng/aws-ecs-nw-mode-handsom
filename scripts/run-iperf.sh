#!/usr/bin/env bash
# TCP throughput test with iperf3 (S-3).
# Baked into the loadgen image; run it on the load generator EC2 like this:
#
#   docker run --rm --network host --read-only --tmpfs /tmp --cap-drop ALL \
#     --user "$(id -u):$(id -g)" -v "$HOME/results:/work/results" "$LOADGEN_IMAGE" \
#     run-iperf.sh --label C --target 10.0.3.21 --port 49153 --parallel 8 --repeat 5 --az cross
set -euo pipefail

LABEL="" TARGET="" PORT=5201 PARALLEL=1 REPEAT=5 DURATION=20 AZ_REL="unknown"
OUT="results/iperf.csv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --az) AZ_REL="$2"; shift 2 ;;            # same | cross
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$LABEL" && -n "$TARGET" ]] || { echo "--label and --target are required" >&2; exit 1; }
[[ "$TARGET" =~ ^[0-9.]+$ && "$PORT" =~ ^[0-9]+$ && "$PARALLEL" =~ ^[0-9]+$ ]] || { echo "invalid target/port/parallel" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
[[ -f "$OUT" ]] || echo "pattern,metric,run,parallel,value,unit,az_relation,timestamp" > "$OUT"

for run in $(seq 1 "$REPEAT"); do
  json="$(iperf3 -c "$TARGET" -p "$PORT" -t "$DURATION" -P "$PARALLEL" -O 2 -J)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gbps="$(jq -r '.end.sum_received.bits_per_second / 1e9' <<<"$json")"
  retr="$(jq -r '.end.sum_sent.retransmits // 0' <<<"$json")"
  echo "$LABEL,throughput,$run,$PARALLEL,$gbps,Gbps,$AZ_REL,$ts" >> "$OUT"
  echo "$LABEL,retransmits,$run,$PARALLEL,$retr,count,$AZ_REL,$ts" >> "$OUT"
  printf '[%s] run %s: %.2f Gbps (retransmits %s)\n' "$LABEL" "$run" "$gbps" "$retr"
  sleep 5
done
