#!/bin/bash
# Validate each task's score anchors ([metadata.scoring] in task.toml) and the
# evidence behind them (evidence/scores.json). Tasks are open-ended and scored
# in [0, 1], so the anchors stand in for "the oracle scores 1.0": they say what
# nop, the unmodified starting state, the reference attempts, and the best
# possible submission score, and how much re-grading one submission can move
# the reward. A binary task is the special case floor = baseline = 0,
# reference = ceiling = 1, regrade_tolerance = 0.
#
# The rules live in score_anchors.py, which validate-task.yml also uses to
# judge the oracle and nop trials.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
    TASK_DIRS=$(find tasks -mindepth 1 -maxdepth 1 -type d | sort)
else
    TASK_DIRS="$*"
fi

FAILED=0
for task_dir in $TASK_DIRS; do
    task_dir=${task_dir%/}
    [ -f "$task_dir/task.toml" ] || continue
    if OUT=$(python3 "$SCRIPT_DIR/score_anchors.py" "$task_dir" --evidence 2>&1); then
        echo "PASS $task_dir: $OUT"
    else
        echo "$OUT"
        echo "$OUT" | grep -q '^FAIL ' || echo "FAIL $task_dir/task.toml: score_anchors.py failed"
        FAILED=1
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo ""
    echo "Declare floor, baseline, reference, ceiling and regrade_tolerance under [metadata.scoring]"
    echo "(plus oracle when solution/solve.sh exists) and back them with evidence/scores.json."
    echo "See docs/TASK_REVIEW_AUTOMATION.md#check-score-anchors."
    exit 1
fi

echo "All score anchors are consistent with their evidence"
