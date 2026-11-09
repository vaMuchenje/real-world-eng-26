#!/bin/bash
# Validate [metadata.services] host_env: the host environment variables a task
# needs at trial time for its provisioned services (graders, trainers, other
# Modal endpoints). Harbor resolves `${NAME}` templates in task.toml `env`
# tables from the host, and CI supplies each declared name from the repository
# secret of the same name.
#
# Fails when:
#   - host_env is not a list of unique UPPER_SNAKE_CASE names,
#   - a name, any task.toml env template (even one with a `:-default`), or any
#     docker-compose interpolation is one of the repository's own
#     infrastructure secrets (CI would hand its API keys or Modal token to the
#     task),
#   - a name is not granted to this task in .github/provisioned-secrets.toml
#     (read from main, so a PR cannot grant itself another task's secret),
#   - a task.toml env template `${NAME}` without a `:-default` is not declared
#     (CI would leave it empty and the trial would fail for infrastructure
#     reasons),
#   - a declared name is referenced by no task.toml env template and no
#     environment/docker-compose file (Harbor would never pass it through).

CHECKS_DIR="$(cd "$(dirname "$0")" && pwd)" python3 - "$@" <<'PY'
import os
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

# The secret policy (reserved names, per-task grants) is shared with the workflows that export them.
sys.path.insert(0, os.environ["CHECKS_DIR"])
from host_env_policy import compose_references, env_templates, task_policy_errors  # noqa: E402

dirs = [pathlib.Path(p) for p in sys.argv[1:]] or sorted(p.parent for p in pathlib.Path("tasks").glob("*/task.toml"))
failed = False


for task_dir in dirs:
    path = task_dir / "task.toml"
    bad = False
    if not path.is_file():
        continue
    try:
        with path.open("rb") as f:
            task = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        print(f"FAIL {path}: invalid TOML: {e}")
        failed = True
        continue

    services = task.get("metadata", {}).get("services", {})
    if not isinstance(services, dict):
        print(f"FAIL {path}: [metadata.services] must be a table")
        failed = True
        continue
    host_env = services.get("host_env", [])
    if not isinstance(host_env, list) or not all(isinstance(n, str) for n in host_env):
        print(f"FAIL {path}: metadata.services.host_env must be a list of UPPER_SNAKE_CASE names, got {host_env!r}")
        failed = True
        continue
    if len(set(host_env)) != len(host_env):
        print(f"FAIL {path}: metadata.services.host_env lists a name twice")
        bad = True
    # Reserved names (even with a `:-default`, even in compose files) and ungranted names.
    for error in task_policy_errors(task_dir, task, host_env):
        print(f"FAIL {path}: {error}")
        bad = True

    referenced = set(compose_references(task_dir))
    for name, has_default in env_templates(task):
        referenced.add(name)
        if not has_default and name not in host_env:
            print(f"FAIL {path}: env template ${{{name}}} has no default and is not listed in metadata.services.host_env")
            bad = True
    for name in host_env:
        if name not in referenced:
            print(f"FAIL {path}: metadata.services.host_env lists {name}, but no task.toml env template or docker-compose file references ${{{name}}}")
            bad = True

    if bad:
        failed = True
    else:
        print(f"PASS {path}: host_env={host_env}")

sys.exit(1 if failed else 0)
PY
