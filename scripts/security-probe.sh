#!/usr/bin/env bash
# Security isolation probe per network mode (additional viewpoint X-1).
#
# Runs a short-lived probe task in each mode and records, from inside the container:
#   - can it get an IMDSv2 token from the instance metadata service?
#   - can it reach the ECS agent introspection API on the host loopback (127.0.0.1:51678)?
#   - can it reach sshd on the host loopback (127.0.0.1:22)?
#   - which network interfaces does it see?
# The probe only reads; it never uses the credentials or data it might reach.
#
# Usage: ./scripts/security-probe.sh <netbench-image-uri>
set -euo pipefail
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "bash 4.4+ required (use CloudShell or brew bash)" >&2; exit 1; }

IMAGE="${1:?usage: security-probe.sh <netbench-image-uri>}"
P="${PREFIX:-netmode-lab}"
REGION="${AWS_REGION:?set AWS_REGION}"
OUT="results/security-probe.csv"

out() { aws cloudformation describe-stacks --stack-name "$1" \
          --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
EXEC_ROLE="$(out "$P-platform" TaskExecutionRoleArn)"
TASK_ROLE="$(out "$P-platform" TaskRoleArn)"
LOG_GROUP="$(out "$P-platform" AppLogGroupName)"
SUBNET="$(out "$P-network" PrivateSubnetA)"
SG="$(out "$P-network" TaskSg)"

# shellcheck disable=SC2016  # expanded inside the container, not here
PROBE='
code() { c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "$@" 2>/dev/null || true); [ "$c" = "000" ] || [ -z "$c" ] && echo blocked || echo "reachable(HTTP $c)"; }
echo "PROBE imds_v2_token=$(code -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)"
echo "PROBE ecs_agent_introspection=$(code http://127.0.0.1:51678/v1/metadata)"
if nc -z -w 2 127.0.0.1 22 2>/dev/null; then echo "PROBE host_sshd_loopback=reachable"; else echo "PROBE host_sshd_loopback=blocked"; fi
echo "PROBE interfaces=$(ip -o -4 addr show | awk "{print \$2\":\"\$4}" | tr "\n" " ")"
'

register() {  # $1 = mode label, $2 = network mode, $3 = compatibility
  local family="$P-probe-$1"
  local cpu_mem='"cpu":"256","memory":"512",'
  aws ecs register-task-definition --cli-input-json "$(cat <<EOF
{
  "family": "$family",
  "networkMode": "$2",
  "requiresCompatibilities": ["$3"],
  $cpu_mem
  "executionRoleArn": "$EXEC_ROLE",
  "taskRoleArn": "$TASK_ROLE",
  "containerDefinitions": [{
    "name": "probe",
    "image": "$IMAGE",
    "essential": true,
    "readonlyRootFilesystem": true,
    "linuxParameters": {"initProcessEnabled": true, "capabilities": {"drop": ["ALL"]}},
    "entryPoint": ["sh", "-c"],
    "command": [$(jq -Rs . <<<"$PROBE")],
    "logConfiguration": {"logDriver": "awslogs", "options": {
      "awslogs-group": "$LOG_GROUP", "awslogs-region": "$REGION", "awslogs-stream-prefix": "probe"}}
  }],
  "tags": [{"key": "Project", "value": "$P"}]
}
EOF
)" --query 'taskDefinition.taskDefinitionArn' --output text
}

run_probe() {  # $1 label, $2 taskdef arn, $3 capacity provider, $4 awsvpc(true/false)
  local net=()
  [[ "$4" == true ]] && net=(--network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}")
  local arn
  arn="$(aws ecs run-task --cluster "$P" --task-definition "$2" \
        --capacity-provider-strategy "capacityProvider=$3,weight=1" "${net[@]}" \
        --started-by "security-probe" --query 'tasks[0].taskArn' --output text)"
  aws ecs wait tasks-stopped --cluster "$P" --tasks "$arn"
  local id="${arn##*/}"
  sleep 5   # give the log stream a moment
  aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "probe/probe/$id" \
    --query 'events[].message' --output text | tr '\t' '\n' | grep '^PROBE ' \
    | sed -e "s/^PROBE //" | while IFS='=' read -r k v; do
        echo "$1,$k,\"$v\",$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
        printf '  [%s] %-28s %s\n' "$1" "$k" "$v"
      done
}

mkdir -p results
[[ -f "$OUT" ]] || echo "pattern,check,result,timestamp" > "$OUT"

TD_A="$(register a awsvpc FARGATE)"
TD_B="$(register b awsvpc EC2)"
TD_C="$(register c bridge EC2)"
TD_D="$(register d host EC2)"

run_probe A  "$TD_A" FARGATE        true
run_probe B1 "$TD_B" "$P-cp-b1"     true
run_probe C  "$TD_C" "$P-cp-c"      false
run_probe D  "$TD_D" "$P-cp-d"      false

echo "Results appended to $OUT"
echo "Clean up: deregister the $P-probe-* task definitions when you are done."
