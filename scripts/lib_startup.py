"""Convert `aws ecs describe-tasks` JSON (stdin) into CSV rows of startup durations.

Used by measure-startup.sh. Only the Python standard library is used.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timezone


def parse(ts):
    if ts is None:
        return None
    if isinstance(ts, (int, float)):  # epoch seconds (CLI v1 style)
        return datetime.fromtimestamp(ts, tz=timezone.utc)
    s = str(ts).replace("Z", "+00:00")
    # Python < 3.11 only accepts 3 or 6 fraction digits: pad to 6.
    s = re.sub(r"\.(\d{1,6})", lambda m: "." + m.group(1).ljust(6, "0"), s, count=1)
    return datetime.fromisoformat(s)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--label", required=True)
    p.add_argument("--run", required=True)
    a = p.parse_args()

    doc = json.load(sys.stdin)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    metrics = {
        "network_ready": "connectivityAt",
        "pull_started": "pullStartedAt",
        "pull_stopped": "pullStoppedAt",
        "startup_total": "startedAt",
    }
    for i, task in enumerate(doc.get("tasks", []), start=1):
        created = parse(task.get("createdAt"))
        if created is None:
            continue
        pull_s = parse(task.get("pullStartedAt"))
        pull_e = parse(task.get("pullStoppedAt"))
        for name, field in metrics.items():
            t = parse(task.get(field))
            if t is None:
                continue
            print(f"{a.label},{name},{a.run},{i},{(t - created).total_seconds():.3f},s,{now}")
        if pull_s and pull_e:
            print(f"{a.label},pull_duration,{a.run},{i},{(pull_e - pull_s).total_seconds():.3f},s,{now}")
    for f in doc.get("failures", []):
        print(f"# failure: {f.get('arn', '')} {f.get('reason', '')}", file=sys.stderr)


if __name__ == "__main__":
    main()
