#!/usr/bin/env python3
"""Enforces the line-coverage threshold for StickflowCore (spec 17.3).

Usage: check-coverage.py <llvm-cov export JSON> <minimum percent>
The JSON comes from `swift test --enable-code-coverage`; its path is printed by
`swift test --show-codecov-path`.
"""

import json
import sys

SOURCES = "/Sources/StickflowCore/"


def main() -> int:
    report_path, minimum = sys.argv[1], float(sys.argv[2])
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)

    total = covered = 0
    rows = []
    for item in report["data"][0]["files"]:
        name = item["filename"]
        if SOURCES not in name:
            continue
        lines = item["summary"]["lines"]
        total += lines["count"]
        covered += lines["covered"]
        rows.append((lines["percent"], name.split(SOURCES, 1)[1], lines["covered"], lines["count"]))

    for percent, name, hit, count in sorted(rows):
        print(f"{percent:6.1f}%  {hit:4}/{count:<4}  {name}")

    percent = 100.0 * covered / total if total else 0.0
    print(f"StickflowCore line coverage: {percent:.1f}% ({covered}/{total}), required {minimum:.0f}%")
    return 0 if percent >= minimum else 1


if __name__ == "__main__":
    sys.exit(main())
