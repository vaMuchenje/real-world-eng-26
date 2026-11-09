#!/bin/bash

# Caps a task's worst-case wall-clock time so every trial has somewhere to run.
#
#   standard      <= 19800s (5.5h): /validate, /run and /cheat drive the trial
#                 from one GitHub Actions job, which GitHub kills at 6h.
#   long-horizon  <= 84600s (23.5h): /run and /cheat launch the trial detached
#                 on Modal (24h function cap) and collect-trials.yml posts the
#                 results; /validate runs nop only and skips the oracle.
#   over the long-horizon cap: rejected.
#
# Both caps leave ~30 min for agent setup, which the trial workflows allow up
# to 18 min via AGENT_SETUP_TIMEOUT_MULTIPLIER, plus setup and result upload.
# Worst-case time (computed by trial_budget.py, which the workflows also use
# to route trials):
#     environment build_timeout_sec
#   + verifier image build_timeout_sec (separate verifier mode)
#   + agent timeout_sec + verifier timeout_sec   (summed over [[steps]], if any)
#   + [[verifier.collect]] timeout_sec
# Omitted fields count at Harbor's defaults (docs/task-schema.json).
# [agent] timeout_sec is required: without it Harbor runs the agent with no
# time limit.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Arguments: task directories (e.g., tasks/my-task) or no args to check all
if [ $# -eq 0 ]; then
    TASK_DIRS=$(find tasks -type f -name "task.toml" -exec dirname {} \;)
else
    TASK_DIRS=""
    for task_dir in "$@"; do
        if [ -d "$task_dir" ] && [ -f "$task_dir/task.toml" ]; then
            TASK_DIRS="$TASK_DIRS ${task_dir%/}"
        fi
    done
fi

if [ -z "$TASK_DIRS" ]; then
    echo "No task.toml files to check"
    exit 0
fi

FAILED=0
for task_dir in $TASK_DIRS; do
    file="$task_dir/task.toml"
    echo "Checking $file..."

    if ! BUDGET=$(python3 "$SCRIPT_DIR/trial_budget.py" "$task_dir" 2>&1); then
        echo "FAIL $file: $BUDGET"
        FAILED=1
        continue
    fi

    RESULT=$(python3 - "$BUDGET" <<'PYEOF'
import json
import sys

b = json.loads(sys.argv[1])
total, cls = b["worst_case_sec"], b["budget_class"]
breakdown = " + ".join(f"{name} {sec:g}" for name, sec in b["breakdown"])
for v in b["violations"]:
    print(f"FAIL {v}")
if cls == "over-cap":
    print(
        f"FAIL worst-case trial time {total:g}s exceeds the {b['detached_cap_sec']:g}s (23.5h) "
        f"long-horizon cap: {breakdown}"
    )
elif cls == "long-horizon":
    print(
        f"INFO long-horizon task ({total:g}s > {b['gh_cap_sec']:g}s): /run and /cheat launch detached "
        f"on Modal and /validate skips the oracle. {breakdown}"
    )
else:
    print(f"INFO standard task ({total:g}s): {breakdown}")
PYEOF
    )
    while IFS= read -r line; do
        case "$line" in
            FAIL\ *) echo "FAIL $file: ${line#FAIL }"; FAILED=1 ;;
            INFO\ *) echo "  ${line#INFO }" ;;
        esac
    done <<< "$RESULT"
done

if [ $FAILED -eq 1 ]; then
    echo ""
    echo "Some task.toml files exceed the 84600-second (23.5h) worst-case trial time cap or are missing agent.timeout_sec."
    echo "Detached trials run inside a 24h Modal function; lower the agent, verifier or build timeouts."
    exit 1
fi

echo "All task.toml worst-case trial times are within the 84600-second (23.5h) cap"
