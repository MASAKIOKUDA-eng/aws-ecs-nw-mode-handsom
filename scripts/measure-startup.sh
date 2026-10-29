#!/usr/bin/env bash
# Measure ECS task startup time per network mode (S-1 / S-2).
#
# Starts N tasks with run-task, waits until they are RUNNING, records
#   createdAt -> connectivityAt  (network ready; ENI for awsvpc)
#   createdAt -> pullStartedAt / pullStoppedAt (image pull)
#   createdAt -> startedAt       (containers started)
# then stops the tasks. Repeats R times and appends rows to a CSV.
#
# Example:
#   ./scripts/measure-startup.sh --label B1 --task-def netmode-lab-b-ec2-awsvpc \
#     --capacity-provider netmode-lab-cp-b1 --awsvpc --count 10 --repeat 5
set -euo pipefail
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "bash 4.4+ required (use CloudShell or brew bash)" >&2; exit 1; }

CLUSTER="${PREFIX:-netmode-lab}"
COUNT=5
REPEAT=5
AWSVPC=false
OUT="results/startup.csv"
COOLDOWN=60
LABEL="" TASK_DEF="" CP=""

usage() {
  cat <<'EOF'
Usage: measure-startup.sh --label <A|B1|B2|C|D> --task-def <family[:rev]> --capacity-provider <name|FARGATE>
                          [--awsvpc] [--count N] [--repeat R] [--cluster NAME] [--out FILE] [--cooldown SEC]
  --awsvpc   pass the network configuration (subnet / SG from the network stack outputs)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --task-def) TASK_DEF="$2"; shift 2 ;;
    --capacity-provider) CP="$2"; shift 2 ;;
    --awsvpc) AWSVPC=true; shift ;;
    --count) COUNT="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --cooldown) COOLDOWN="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$LABEL" && -n "$TASK_DEF" && -n "$CP" ]] || usage
[[ "$COUNT" =~ ^[0-9]+$ && "$REPEAT" =~ ^[0-9]+$ ]] || { echo "count/repeat must be integers" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$OUT")"
[[ -f "$OUT" ]] || echo "pattern,metric,run,task_index,value,unit,timestamp" > "$OUT"

net_args=()
if [[ "$AWSVPC" == true ]]; then
  STACK="${PREFIX:-netmode-lab}-network"
  out() { aws cloudformation describe-stacks --stack-name "$STACK" \
            --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
  SUBNET="$(out PrivateSubnetA)"
  SG="$(out TaskSg)"
  net_args=(--network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}")
fi

for run in $(seq 1 "$REPEAT"); do
  echo "== [$LABEL] run $run/$REPEAT: starting $COUNT task(s)"
  arns=()
  remaining=$COUNT
  while (( remaining > 0 )); do
    batch=$(( remaining > 10 ? 10 : remaining ))   # run-task accepts up to 10 per call
    mapfile -t new < <(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEF" \
        --count "$batch" --capacity-provider-strategy "capacityProvider=$CP,weight=1" \
        "${net_args[@]}" --started-by "startup-test-$LABEL" \
        --tags "key=Project,value=${PREFIX:-netmode-lab}" "key=NetMode,value=$LABEL" \
        --query 'tasks[].taskArn' --output text | tr '\t' '\n' | sed '/^$/d')
    arns+=("${new[@]}")
    remaining=$(( remaining - batch ))
  done
  if (( ${#arns[@]} < COUNT )); then
    echo "!! only ${#arns[@]}/$COUNT tasks were accepted. Check 'failures' (e.g. RESOURCE:ENI, RESOURCE:PORTS)." >&2
  fi
  if (( ${#arns[@]} == 0 )); then
    continue
  fi

  # describe-tasks / wait accept up to 100 tasks per call
  if ! aws ecs wait tasks-running --cluster "$CLUSTER" --tasks "${arns[@]}"; then
    echo "!! not all tasks reached RUNNING. Recording what is available." >&2
  fi

  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "${arns[@]}" --output json \
    | python3 -I "$SCRIPT_DIR/lib_startup.py" --label "$LABEL" --run "$run" >> "$OUT"

  for arn in "${arns[@]}"; do
    aws ecs stop-task --cluster "$CLUSTER" --task "$arn" --reason "startup-test done" >/dev/null
  done
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "${arns[@]}" || true
  echo "   cooldown ${COOLDOWN}s"
  sleep "$COOLDOWN"
done

echo "Done. Rows appended to $OUT"
