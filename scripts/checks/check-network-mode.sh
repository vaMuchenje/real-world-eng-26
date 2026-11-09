#!/bin/bash

# Enforces RealWorldEngineer's open-internet policy for the agent phase. In
# [environment], [agent], and each [[steps]] agent table:
#   - network_mode must be "public" or omitted (Harbor's default is "public");
#     "no-network" and "allowlist" are rejected, and so is allowed_hosts,
#     which only applies to "allowlist".
# Anywhere in task.toml:
#   - allow_internet is rejected. Harbor deprecated it in favour of
#     network_mode, and a task that sets both is ambiguous to a reviewer.
# The verifier may restrict its own network ([verifier] or
# [verifier.environment]); that only tightens verifier isolation.
# Disabling network access is not a valid way to make a task harder.

set -e

# Arguments: task directories (e.g., tasks/my-task) or no args to check all
if [ $# -eq 0 ]; then
    FILES_TO_CHECK=$(find tasks -type f -name "task.toml")
else
    FILES_TO_CHECK=""
    for task_dir in "$@"; do
        if [ -d "$task_dir" ] && [ -f "$task_dir/task.toml" ]; then
            FILES_TO_CHECK="$FILES_TO_CHECK $task_dir/task.toml"
        fi
    done
fi

if [ -z "$FILES_TO_CHECK" ]; then
    echo "No task.toml files to check"
    exit 0
fi

FAILED=0
for file in $FILES_TO_CHECK; do
    if [ ! -f "$file" ]; then
        echo "File $file does not exist, skipping"
        continue
    fi

    echo "Checking $file..."

    RESULT=$(python3 - "$file" <<'PYEOF'
import sys

path = sys.argv[1]

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

with open(path, "rb") as f:
    data = tomllib.load(f)

violations = []

# Tables that control the agent phase's network.
agent_phase = [("environment", data.get("environment", {})), ("agent", data.get("agent", {}))]
for i, step in enumerate(data.get("steps", []) or []):
    agent_phase.append((f"steps[{i}].agent", step.get("agent", {})))
for where, table in agent_phase:
    if not isinstance(table, dict):
        continue
    mode = table.get("network_mode", "public")
    if mode != "public":
        violations.append(
            f"{where}.network_mode={mode!r}; RealWorldEngineer agents run with open internet (use \"public\" or omit it)"
        )
    if "allowed_hosts" in table:
        violations.append(f"{where}.allowed_hosts only applies to network_mode=\"allowlist\"; remove it")

for where, table in (
    ("environment", data.get("environment", {})),
    ("verifier.environment", data.get("verifier", {}).get("environment", {})),
):
    if isinstance(table, dict) and "allow_internet" in table:
        violations.append(
            f"{where}.allow_internet is deprecated; remove it (network_mode defaults to \"public\")"
        )

if violations:
    print("\n".join(violations))
    sys.exit(1)
PYEOF
    ) || {
        echo "$RESULT" | while IFS= read -r line; do
            [ -n "$line" ] && echo "FAIL $file: $line"
        done
        FAILED=1
        continue
    }
done

if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Some task.toml files restrict network access or use the deprecated allow_internet field."
    echo "RealWorldEngineer is an open-internet benchmark: set network_mode = \"public\" or omit it."
    exit 1
fi

echo "All task.toml files use open internet (network_mode = \"public\")"
