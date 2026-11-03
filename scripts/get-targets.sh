#!/usr/bin/env bash
# Print how to reach each running task of a service directly (without the ALB).
#   awsvpc       : task ENI IP + container port
#   bridge / host: container instance IP + host port (from networkBindings)
#
# Output (TSV): task_id  ip  web_port  iperf_port  instance_id  az
# Example: ./scripts/get-targets.sh svc-c
set -euo pipefail
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "bash 4.4+ required (use CloudShell or brew bash)" >&2; exit 1; }

SERVICE="${1:?usage: get-targets.sh <service-name>}"
CLUSTER="${PREFIX:-netmode-lab}"

mapfile -t tasks < <(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --desired-status RUNNING --query 'taskArns[]' --output text | tr '\t' '\n' | sed '/^$/d')
(( ${#tasks[@]} > 0 )) || { echo "no running tasks in $SERVICE" >&2; exit 1; }

desc="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "${tasks[@]}" --output json)"

printf 'task_id\tip\tweb_port\tiperf_port\tinstance_id\taz\n'
while IFS=$'\t' read -r task_id ci_arn az eni_ip web_bind iperf_bind; do
  instance_id="-"
  if [[ "$ci_arn" != "null" ]]; then
    instance_id="$(aws ecs describe-container-instances --cluster "$CLUSTER" \
      --container-instances "$ci_arn" --query 'containerInstances[0].ec2InstanceId' --output text)"
  fi
  if [[ "$eni_ip" != "null" ]]; then
    ip="$eni_ip"; web_port=8080; iperf_port=5201          # awsvpc
  else
    ip="$(aws ec2 describe-instances --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
    web_port="$web_bind"; iperf_port="$iperf_bind"        # bridge / host
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$task_id" "$ip" "$web_port" "$iperf_port" "$instance_id" "$az"
done < <(jq -r '
  .tasks[] |
  [ (.taskArn | split("/") | last),
    (.containerInstanceArn // "null"),
    .availabilityZone,
    ((.attachments[]? | select(.type=="ElasticNetworkInterface") | .details[] | select(.name=="privateIPv4Address") | .value) // "null"),
    ((.containers[] | select(.name=="web")   | .networkBindings[0].hostPort) // "null"),
    ((.containers[] | select(.name=="iperf") | .networkBindings[0].hostPort) // "null")
  ] | @tsv' <<<"$desc")
