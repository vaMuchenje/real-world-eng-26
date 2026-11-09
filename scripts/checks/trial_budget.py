#!/usr/bin/env python3
"""Compute a task's worst-case trial time and its budget class.

standard      <= GH_CAP_SEC: trials run inside a GitHub-hosted job (6h limit).
long-horizon  <= DETACHED_CAP_SEC: /run and /cheat launch detached on Modal (24h function cap).
over-cap      >  DETACHED_CAP_SEC: rejected by check-task-timeout.sh.

Usage: trial_budget.py <task_dir>  ->  JSON on stdout. Exit 1 if task.toml is unreadable.
"""

from __future__ import annotations

import json
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

# Both caps leave 30 minutes for agent setup (CI allows up to 18 min) and result upload.
GH_CAP_SEC = 19800  # 5.5h under GitHub's 6h job limit
DETACHED_CAP_SEC = 84600  # 23.5h under Modal's 24h function timeout

SCHEMA = pathlib.Path(__file__).resolve().parents[2] / "docs" / "task-schema.json"


def budget(task_dir: pathlib.Path) -> dict:
    with (task_dir / "task.toml").open("rb") as f:
        data = tomllib.load(f)
    defs = json.loads(SCHEMA.read_text())["$defs"]
    violations: list[str] = []

    def default(model: str, field: str) -> float:
        return float(defs[model]["properties"][field].get("default") or 0)

    def seconds(value, model: str, field: str, where: str) -> float:
        if value is None:
            return default(model, field)
        try:
            return float(value)
        except (TypeError, ValueError):
            violations.append(f"{where}.{field} is not numeric: {value!r}")
            return 0.0

    agent = data.get("agent", {})
    verifier = data.get("verifier", {})
    environment = data.get("environment", {})
    steps = data.get("steps") or []

    if agent.get("timeout_sec") is None and not (
        steps and all((s.get("agent") or {}).get("timeout_sec") is not None for s in steps)
    ):
        violations.append("agent.timeout_sec is required (without it Harbor runs the agent with no time limit)")

    parts = [("environment build", seconds(environment.get("build_timeout_sec"), "EnvironmentConfig", "build_timeout_sec", "environment"))]
    if verifier.get("environment_mode", "separate") != "shared":
        venv = verifier.get("environment") or {}
        build = venv.get("build_timeout_sec", environment.get("build_timeout_sec"))
        parts.append(("verifier build", seconds(build, "EnvironmentConfig", "build_timeout_sec", "verifier.environment")))

    agent_sec = seconds(agent.get("timeout_sec"), "AgentConfig", "timeout_sec", "agent")
    verifier_sec = seconds(verifier.get("timeout_sec"), "VerifierConfig", "timeout_sec", "verifier")
    if steps:
        for i, step in enumerate(steps):
            sa = (step.get("agent") or {}).get("timeout_sec")
            sv = (step.get("verifier") or {}).get("timeout_sec")
            parts.append((f"steps[{i}] agent", seconds(sa, "AgentConfig", "timeout_sec", f"steps[{i}].agent") if sa is not None else agent_sec))
            parts.append((f"steps[{i}] verifier", seconds(sv, "VerifierConfig", "timeout_sec", f"steps[{i}].verifier") if sv is not None else verifier_sec))
    else:
        parts += [("agent", agent_sec), ("verifier", verifier_sec)]

    for i, hook in enumerate(verifier.get("collect") or []):
        parts.append((f"collect[{i}]", seconds(hook.get("timeout_sec"), "VerifierCollectConfig", "timeout_sec", f"verifier.collect[{i}]")))

    total = sum(sec for _, sec in parts)
    if total <= GH_CAP_SEC:
        budget_class = "standard"
    elif total <= DETACHED_CAP_SEC:
        budget_class = "long-horizon"
    else:
        budget_class = "over-cap"
    return {
        "worst_case_sec": total,
        "budget_class": budget_class,
        "gh_cap_sec": GH_CAP_SEC,
        "detached_cap_sec": DETACHED_CAP_SEC,
        "breakdown": parts,
        "violations": violations,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        result = budget(pathlib.Path(sys.argv[1]))
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"cannot read task.toml: {e}", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
