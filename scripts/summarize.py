#!/usr/bin/env python3
"""Summarize result CSVs (median / p95 / n per pattern and metric) as a Markdown table.

  python3 scripts/summarize.py results/startup.csv
  python3 scripts/summarize.py results/iperf.csv --group parallel,az_relation
  python3 scripts/summarize.py results/k6.csv --group path,rate
"""
import argparse
import csv
import statistics
from collections import defaultdict


def pct(values, q):
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("csv")
    p.add_argument("--group", default="", help="extra columns to group by (comma separated)")
    a = p.parse_args()
    extra = [g for g in a.group.split(",") if g]

    groups = defaultdict(list)
    units = {}
    with open(a.csv, newline="") as f:
        for row in csv.DictReader(r for r in f if not r.startswith("#")):
            key = (row["pattern"], *[row[g] for g in extra], row["metric"])
            try:
                groups[key].append(float(row["value"]))
            except ValueError:
                continue
            units[key] = row.get("unit", "")

    header = ["pattern", *extra, "metric", "n", "median", "p95", "min", "max", "unit"]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for key in sorted(groups):
        v = groups[key]
        print("| " + " | ".join([*key[:-1], key[-1], str(len(v)),
                                 f"{statistics.median(v):.3f}", f"{pct(v, 0.95):.3f}",
                                 f"{min(v):.3f}", f"{max(v):.3f}", units[key]]) + " |")


if __name__ == "__main__":
    main()
