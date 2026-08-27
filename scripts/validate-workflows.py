#!/usr/bin/env python3

from pathlib import Path
import sys

import yaml


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    workflows = sorted((root / ".github" / "workflows").glob("*.yml"))
    if not workflows:
        print("no workflow files found", file=sys.stderr)
        return 1

    for path in workflows:
        with path.open(encoding="utf-8") as stream:
            document = yaml.safe_load(stream)
        if not isinstance(document, dict):
            print(f"{path}: expected a mapping", file=sys.stderr)
            return 1
        if "jobs" not in document or not isinstance(document["jobs"], dict):
            print(f"{path}: missing jobs mapping", file=sys.stderr)
            return 1

    action = root / "action.yml"
    with action.open(encoding="utf-8") as stream:
        document = yaml.safe_load(stream)
    if not isinstance(document, dict):
        print(f"{action}: expected a mapping", file=sys.stderr)
        return 1
    runs = document.get("runs")
    if not isinstance(runs, dict) or runs.get("using") != "composite":
        print(f"{action}: expected a composite runs mapping", file=sys.stderr)
        return 1

    print(f"workflow YAML parsed: {len(workflows)}; composite action parsed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
