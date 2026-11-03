#!/usr/bin/env python3
"""Estimate monthly compute cost per ECS network mode pattern.

No prices are built in: pass the prices you read from the AWS pricing pages
on the day of the test, so the numbers stay correct and traceable.

Example:
  python3 scripts/cost-calc.py --tasks 40 --task-vcpu 0.25 --task-mem-gib 0.5 \
      --instance-vcpu 2 --instance-mem-gib 4 --max-eni 3 --trunk-eni-limit 12 \
      --instance-hourly <EC2 $/h> --fargate-vcpu-hourly <$/vCPU-h> --fargate-gb-hourly <$/GB-h>

  # Sweep task counts and write CSV for a chart:
  python3 scripts/cost-calc.py ... --sweep 10,20,40,80,160 --csv results/cost-sweep.csv
"""
import argparse
import csv
import math
import sys


def per_instance_limits(a):
    usable_mem = a.instance_mem_gib * a.usable_mem_ratio
    by_cpu = math.floor(a.instance_vcpu / a.task_vcpu)
    by_mem = math.floor(usable_mem / a.task_mem_gib)
    cpu_mem = min(by_cpu, by_mem)
    return {
        "B1": (min(cpu_mem, a.max_eni - 1), "ENI" if a.max_eni - 1 < cpu_mem else "CPU/memory"),
        "B2": (min(cpu_mem, a.trunk_eni_limit), "trunk ENI" if a.trunk_eni_limit < cpu_mem else "CPU/memory"),
        "C": (cpu_mem, "CPU/memory"),
        # host mode: every task listens on the same port, so one task per instance.
        "D": (min(cpu_mem, 1), "port" if cpu_mem > 1 else "CPU/memory"),
    }


def estimate(a, tasks):
    hours = a.hours
    rows = []
    fargate = tasks * (a.task_vcpu * a.fargate_vcpu_hourly + a.task_mem_gib * a.fargate_gb_hourly) * hours
    rows.append({
        "pattern": "A", "name": "Fargate awsvpc", "tasks": tasks, "tasks_per_instance": "-",
        "instances": "-", "monthly_usd": round(fargate, 2), "limited_by": "per-task billing",
        "vpc_ips": tasks,
    })
    names = {"B1": "EC2 awsvpc", "B2": "EC2 awsvpc + trunking", "C": "EC2 bridge", "D": "EC2 host"}
    for key, (per, reason) in per_instance_limits(a).items():
        if per < 1:
            rows.append({"pattern": key, "name": names[key], "tasks": tasks, "tasks_per_instance": 0,
                         "instances": "n/a", "monthly_usd": "n/a", "limited_by": reason + " (task too large)",
                         "vpc_ips": "n/a"})
            continue
        instances = math.ceil(tasks / per) + a.headroom_instances
        cost = instances * a.instance_hourly * hours
        if key == "B1":
            ips = tasks + instances                # task ENIs + primary ENIs
        elif key == "B2":
            ips = tasks + instances * 2            # task branch ENIs + primary + trunk ENI
        else:
            ips = instances
        rows.append({"pattern": key, "name": names[key], "tasks": tasks, "tasks_per_instance": per,
                     "instances": instances, "monthly_usd": round(cost, 2), "limited_by": reason,
                     "vpc_ips": ips})
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tasks", type=int, default=40)
    p.add_argument("--task-vcpu", type=float, required=True)
    p.add_argument("--task-mem-gib", type=float, required=True)
    p.add_argument("--instance-vcpu", type=float, required=True)
    p.add_argument("--instance-mem-gib", type=float, required=True)
    p.add_argument("--usable-mem-ratio", type=float, default=0.9,
                   help="share of instance memory ECS can give to tasks (check registeredResources)")
    p.add_argument("--max-eni", type=int, required=True, help="max ENIs of the instance type")
    p.add_argument("--trunk-eni-limit", type=int, required=True,
                   help="awsvpc task limit with ENI trunking (see the ECS supported instances table)")
    p.add_argument("--headroom-instances", type=int, default=0,
                   help="extra instances kept for rolling deployments")
    p.add_argument("--instance-hourly", type=float, required=True)
    p.add_argument("--fargate-vcpu-hourly", type=float, required=True)
    p.add_argument("--fargate-gb-hourly", type=float, required=True)
    p.add_argument("--hours", type=float, default=730)
    p.add_argument("--sweep", help="comma separated task counts, e.g. 10,20,40,80")
    p.add_argument("--csv", help="write rows to this CSV file")
    a = p.parse_args()

    for name in ("task_vcpu", "task_mem_gib", "instance_vcpu", "instance_mem_gib"):
        if getattr(a, name) <= 0:
            p.error(f"--{name.replace('_', '-')} must be > 0")

    counts = [int(x) for x in a.sweep.split(",")] if a.sweep else [a.tasks]
    all_rows = [r for n in counts for r in estimate(a, n)]

    print(f"{'pat':<4}{'name':<24}{'tasks':>6}{'per_inst':>9}{'instances':>10}{'monthly_usd':>13}{'vpc_ips':>8}  limited_by")
    for r in all_rows:
        print(f"{r['pattern']:<4}{r['name']:<24}{r['tasks']:>6}{str(r['tasks_per_instance']):>9}"
              f"{str(r['instances']):>10}{str(r['monthly_usd']):>13}{str(r['vpc_ips']):>8}  {r['limited_by']}")
    print("\nNot included: data transfer, ALB, VPC endpoints, logs/metrics, public IPv4, EBS.", file=sys.stderr)

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(all_rows[0].keys()))
            w.writeheader()
            w.writerows(all_rows)


if __name__ == "__main__":
    main()
