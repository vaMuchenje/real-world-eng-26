#!/usr/bin/env python3
"""Read and validate a task's score anchors ([metadata.scoring]) and, optionally, its evidence.

Usage: score_anchors.py <task_dir> [--evidence]

Prints the anchors as JSON on success. On failure prints `FAIL <path>: <reason>` lines and exits 1.
--evidence also validates <task_dir>/evidence/scores.json against the anchors.
"""

from __future__ import annotations

import datetime
import json
import math
import pathlib
import statistics
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

ANCHORS = ("floor", "baseline", "reference", "ceiling", "regrade_tolerance")
EVIDENCE_KINDS = {"baseline", "reference", "regrade"}
OPTIONAL_STRINGS = ("date", "agent", "budget", "receipt")
# Declared anchors are medians of recorded rewards; allow float formatting slack only.
SLACK = 1e-6


def _number(value) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def read_anchors(task_dir: pathlib.Path) -> tuple[dict, list[str]]:
    path = task_dir / "task.toml"
    with path.open("rb") as f:
        scoring = tomllib.load(f).get("metadata", {}).get("scoring")
    errors: list[str] = []
    if not isinstance(scoring, dict):
        return {}, ["[metadata.scoring] is missing (floor, baseline, reference, ceiling, regrade_tolerance)"]

    anchors: dict = {}
    for name in ANCHORS:
        value = _number(scoring.get(name))
        if value is None:
            errors.append(f"metadata.scoring.{name} must be a finite number, got {scoring.get(name)!r}")
        anchors[name] = value
    has_solution = (task_dir / "solution" / "solve.sh").is_file()
    anchors["has_solution"] = has_solution
    anchors["oracle"] = None
    if "oracle" in scoring:
        anchors["oracle"] = _number(scoring["oracle"])
        if anchors["oracle"] is None:
            errors.append(f"metadata.scoring.oracle must be a finite number, got {scoring['oracle']!r}")
        elif not has_solution:
            errors.append("metadata.scoring.oracle is set but solution/solve.sh does not exist")
    elif has_solution:
        errors.append("solution/solve.sh exists, so metadata.scoring.oracle (its expected reward) is required")
    unknown = sorted(set(scoring) - set(ANCHORS) - {"oracle"})
    if unknown:
        errors.append(f"metadata.scoring has unknown keys: {', '.join(unknown)}")
    if any(anchors[n] is None for n in ANCHORS):
        return anchors, errors

    floor, baseline, reference, ceiling, tol = (anchors[n] for n in ANCHORS)
    if not 0.0 <= floor <= baseline < reference <= ceiling <= 1.0:
        errors.append(
            "anchors must satisfy 0 <= floor <= baseline < reference <= ceiling <= 1, got "
            f"floor={floor:g} baseline={baseline:g} reference={reference:g} ceiling={ceiling:g}"
        )
    if tol < 0:
        errors.append(f"metadata.scoring.regrade_tolerance must be >= 0, got {tol:g}")
    elif reference - baseline <= 2 * tol:
        errors.append(
            f"reference - baseline ({reference - baseline:g}) must exceed 2 * regrade_tolerance ({2 * tol:g}), "
            "otherwise the reference gain is indistinguishable from grading noise"
        )
    oracle = anchors["oracle"]
    if oracle is not None and not baseline + tol < oracle <= ceiling:
        errors.append(
            f"metadata.scoring.oracle ({oracle:g}) must satisfy baseline + regrade_tolerance < oracle <= ceiling"
        )
    return anchors, errors


def check_evidence(task_dir: pathlib.Path, anchors: dict) -> list[str]:
    path = task_dir / "evidence" / "scores.json"
    if not path.is_file():
        return ["evidence/scores.json is missing (baseline, reference and regrade runs backing the anchors)"]
    try:
        data = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        return [f"evidence/scores.json is not valid JSON: {e}"]
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        return ["evidence/scores.json must be an object with schema_version = 1"]
    runs = data.get("runs")
    if not isinstance(runs, list) or not runs:
        return ["evidence/scores.json has no runs; record at least one baseline, one reference and one regrade run"]

    errors: list[str] = []
    rewards: dict[str, list[float]] = {kind: [] for kind in EVIDENCE_KINDS}
    regrade_groups: list[list[float]] = []
    for i, run in enumerate(runs):
        where = f"evidence/scores.json runs[{i}]"
        if not isinstance(run, dict):
            errors.append(f"{where} must be an object")
            continue
        kind = run.get("kind")
        if kind not in EVIDENCE_KINDS:
            errors.append(f"{where}.kind must be one of {', '.join(sorted(EVIDENCE_KINDS))}, got {kind!r}")
            continue
        if not isinstance(run.get("note"), str) or not run["note"].strip():
            errors.append(f"{where}.note must be a non-empty string")
        for field in OPTIONAL_STRINGS:
            if field in run and not isinstance(run[field], str):
                errors.append(f"{where}.{field} must be a string")
        if isinstance(run.get("date"), str):
            try:
                datetime.date.fromisoformat(run["date"])
            except ValueError:
                errors.append(f"{where}.date must be YYYY-MM-DD, got {run['date']!r}")
        if kind == "regrade":
            values = run.get("rewards")
            if not isinstance(values, list) or len(values) < 2:
                errors.append(f"{where}.rewards must list at least two rewards for one submission")
                continue
            group = [_number(v) for v in values]
        else:
            group = [_number(run.get("reward"))]
        if any(v is None or not 0.0 <= v <= 1.0 for v in group):
            errors.append(f"{where} rewards must be finite numbers in [0, 1]")
            continue
        if kind == "regrade":
            regrade_groups.append(group)
        else:
            rewards[kind].extend(group)

    for kind in ("baseline", "reference"):
        if not rewards[kind]:
            errors.append(f"evidence/scores.json needs at least one {kind} run")
    if not regrade_groups:
        errors.append("evidence/scores.json needs at least one regrade run (one submission graded at least twice)")
    if errors or anchors.get("regrade_tolerance") is None:
        return errors

    tol = anchors["regrade_tolerance"]
    for kind in ("baseline", "reference"):
        median = statistics.median(rewards[kind])
        if abs(median - anchors[kind]) > max(tol, SLACK):
            errors.append(
                f"metadata.scoring.{kind} ({anchors[kind]:g}) must match the median {kind} reward in "
                f"evidence/scores.json ({median:g}) within regrade_tolerance"
            )
    for group in regrade_groups:
        if max(group) - min(group) > tol + 1e-9:
            errors.append(
                f"a regrade run spans {max(group) - min(group):g}, more than regrade_tolerance ({tol:g})"
            )
    return errors


def main() -> int:
    args = sys.argv[1:]
    with_evidence = "--evidence" in args
    args = [a for a in args if a != "--evidence"]
    if len(args) != 1:
        print("Usage: score_anchors.py <task_dir> [--evidence]", file=sys.stderr)
        return 2
    task_dir = pathlib.Path(args[0])
    toml_path = task_dir / "task.toml"
    try:
        anchors, errors = read_anchors(task_dir)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"FAIL {toml_path}: cannot read task.toml: {e}")
        return 1
    if with_evidence and not errors:
        errors = check_evidence(task_dir, anchors)
    if errors:
        for error in errors:
            where = task_dir / "evidence" / "scores.json" if error.startswith("evidence/") else toml_path
            print(f"FAIL {where}: {error}")
        return 1
    print(json.dumps(anchors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
