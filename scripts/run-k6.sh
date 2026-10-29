#!/usr/bin/env bash
# Step load test with k6 (S-4 / S-5).
# Baked into the loadgen image; run it on the load generator EC2 like this:
#
#   docker run --rm --network host --read-only --tmpfs /tmp --cap-drop ALL \
#     --user "$(id -u):$(id -g)" -v "$HOME/results:/work/results" "$LOADGEN_IMAGE" \
#     run-k6.sh --label B1 --url "http://$ALB_DNS:8002/1k" --rates "100 500 1000 2000" --path alb
#
# For each rate it appends p50/p95/p99/error rate/dropped iterations to results/k6.csv.
set -euo pipefail

LABEL="" URL="" RATES="100 500 1000 2000" DURATION="3m" PATH_KIND="alb"
OUT="results/k6.csv"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --rates) RATES="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --path) PATH_KIND="$2"; shift 2 ;;        # alb | direct
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$LABEL" && "$URL" =~ ^http://[A-Za-z0-9.:-]+/ ]] || { echo "--label and a valid --url are required" >&2; exit 1; }
[[ "$PATH_KIND" =~ ^(alb|direct)$ ]] || { echo "--path must be alb or direct" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")" results/raw
[[ -f "$OUT" ]] || echo "pattern,path,rate,metric,value,unit,timestamp" > "$OUT"

for rate in $RATES; do
  [[ "$rate" =~ ^[0-9]+$ ]] || { echo "invalid rate: $rate" >&2; exit 1; }
  summary="results/raw/k6-${LABEL}-${PATH_KIND}-${rate}-$(date +%s).json"
  echo "== [$LABEL/$PATH_KIND] rate=${rate} rps"
  # k6 exits non-zero when a threshold fails; the numbers are still recorded.
  k6 run --quiet \
    -e TARGET_URL="$URL" -e RATE="$rate" -e DURATION="$DURATION" -e LABEL="$LABEL" \
    --summary-export "$summary" "$SCRIPT_DIR/k6-load.js" || true

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -r --arg l "$LABEL" --arg p "$PATH_KIND" --arg r "$rate" --arg ts "$ts" '
    .metrics as $m
    | ($m["http_req_duration{phase:measure}"] // $m.http_req_duration) as $d
    | ($m["http_req_failed{phase:measure}"] // $m.http_req_failed) as $f
    | [ ["p50_ms", $d.med], ["p95_ms", $d["p(95)"]], ["p99_ms", $d["p(99)"]],
        ["error_rate", ($f.value // $f.rate // 0)],
        ["dropped_iterations", ($m.dropped_iterations.count // 0)] ]
    | .[]
    | "\($l),\($p),\($r),\(.[0]),\(.[1]),\(if (.[0]|endswith("_ms")) then "ms" elif .[0]=="error_rate" then "ratio" else "count" end),\($ts)"
  ' "$summary" >> "$OUT"
  tail -n 5 "$OUT"
  sleep 30   # let the targets settle before the next step
done
