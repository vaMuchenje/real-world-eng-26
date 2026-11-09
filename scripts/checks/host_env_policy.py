#!/usr/bin/env python3
"""Single source of truth for which repository secrets a task may receive.

task.toml [metadata.services] host_env lists host environment variables that the task's
`env = { X = "${NAME}" }` templates need; CI supplies each from the repository secret of the
same name. Harbor resolves those templates, and `${NAME}` / `$NAME` in the task's
docker-compose files, from the host environment, which also holds CI's own credentials. So:

- CI's own secrets (RESERVED) may never be requested or referenced, not even with a `:-default`.
- Every other secret must be granted to the task by name in .github/provisioned-secrets.toml.
  That file is read from main, so a task PR cannot grant itself another task's secret.

Used by scripts/trials/host_env.py (CI secret export) and scripts/checks/check-task-services.sh:
  from host_env_policy import task_policy_errors, refusal, is_reserved
  python3 scripts/checks/host_env_policy.py NAME...   # prints one FAIL line per refused name
"""

from __future__ import annotations

import pathlib
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

GRANTS_FILE = pathlib.Path(__file__).resolve().parents[2] / ".github" / "provisioned-secrets.toml"
# task.toml env templates: ${NAME} or ${NAME:-default}.
TEMPLATE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}")
# Compose interpolation: ${NAME}, ${NAME:-x}, ${NAME?err}, or bare $NAME ($$ is a literal $).
COMPOSE_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|\$([A-Za-z_][A-Za-z0-9_]*)")

NAME = re.compile(r"[A-Z][A-Z0-9_]*")
# CUSTOMIZE: secrets the workflows themselves use (agent API keys, Modal token, GitHub token,
# AI-detection keys). Add any new repository secret the CI holds for its own use.
RESERVED = frozenset({
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "MODAL_TOKEN_ID",
    "MODAL_TOKEN_SECRET",
    "OPENAI_API_KEY",
})
RESERVED_PREFIXES = ("GITHUB_", "GPTZERO", "MODAL_TOKEN", "ACTIONS_", "RUNNER_")


def is_reserved(name: str) -> bool:
    """True if `name` is one of the CI's own secrets (never requested, never templated)."""
    return name in RESERVED or name.startswith(RESERVED_PREFIXES)


def refusal(name: object) -> str | None:
    """Why `name` may not be requested through host_env, or None if it may."""
    if not isinstance(name, str) or not NAME.fullmatch(name):
        return f"{name!r} is not an UPPER_SNAKE_CASE environment variable name matching [A-Z][A-Z0-9_]*"
    if is_reserved(name):
        return f"{name} is one of the repository's own infrastructure secrets"
    return None


def env_templates(node, inside_env: bool = False):
    """Yield (name, has_default) for every ${NAME} in a string under an `env` table."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from env_templates(value, inside_env or key == "env")
    elif isinstance(node, list):
        for value in node:
            yield from env_templates(value, inside_env)
    elif inside_env and isinstance(node, str):
        for m in TEMPLATE.finditer(node):
            yield m.group(1), ":-" in m.group(0)


def compose_references(task_dir: pathlib.Path) -> set[str]:
    """Host variables the task's docker-compose files interpolate (environment/ and tests/)."""
    names: set[str] = set()
    for folder in ("environment", "tests"):
        for compose in sorted((task_dir / folder).glob("docker-compose*.y*ml")):
            text = compose.read_text(errors="replace").replace("$$", "")
            names.update(a or b for a, b in COMPOSE_REF.findall(text))
    return names


def granted(task_dir: pathlib.Path, grants_file: pathlib.Path = GRANTS_FILE) -> set[str]:
    """Secrets maintainers granted to this task ([tasks.<task-dir-name>] host_env)."""
    try:
        data = tomllib.loads(grants_file.read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return set()
    entry = (data.get("tasks") or {}).get(task_dir.name) or {}
    names = entry.get("host_env") if isinstance(entry, dict) else None
    return {n for n in names if isinstance(n, str)} if isinstance(names, list) else set()


def task_policy_errors(task_dir: pathlib.Path, task: dict, host_env: list,
                       grants_file: pathlib.Path = GRANTS_FILE) -> list[str]:
    """Every way this task would receive a secret it may not have."""
    errors = []
    for name in sorted({n for n, _ in env_templates(task) if is_reserved(n)}):
        errors.append(f"env template ${{{name}}} would hand the repository's own secret {name} to the task")
    for name in sorted(n for n in compose_references(task_dir) if is_reserved(n)):
        errors.append(f"a docker-compose file references ${name}, the repository's own secret")
    allowed = granted(task_dir, grants_file)
    for name in host_env:
        reason = refusal(name)
        if reason:
            errors.append(f"metadata.services.host_env: {reason}")
        elif name not in allowed:
            errors.append(
                f"metadata.services.host_env lists {name}, which is not granted to {task_dir.name} in "
                ".github/provisioned-secrets.toml (a maintainer adds the grant on main)"
            )
    return errors


def main(argv: list[str]) -> int:
    failed = False
    for name in argv:
        reason = refusal(name)
        if reason:
            print(f"FAIL host_env: {reason}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
