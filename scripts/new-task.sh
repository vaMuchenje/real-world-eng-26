#!/bin/bash
# Create a new RealWorldEngineer task under tasks/<task-name>.
#
# Wraps `harbor tasks init`, then:
#   - swaps Harbor's shared canary for RealWorldEngineer's own (see check-canary.sh),
#   - replaces Harbor's shared-verifier tests/ scaffold with a separate-verifier
#     one (tests/Dockerfile with pytest baked in, no installs in test.sh),
#   - writes README.md with the required reviewer-facing sections,
#   - adds an instruction placeholder to instruction.md,
#   - starts evidence/scores.json for the score anchors (check-score-anchors.sh).
#
# Usage: scripts/new-task.sh [--no-solution] <task-name>
#   --no-solution: open-ended task without a reference solution/solve.sh; the
#                  oracle anchor is dropped and /validate runs nop only.

set -euo pipefail

INIT_FLAGS=()
if [ "${1:-}" = "--no-solution" ]; then
    INIT_FLAGS+=(--no-solution)
    shift
fi
if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: scripts/new-task.sh [--no-solution] <task-name>" >&2
    echo "  <task-name>: lowercase kebab-case, at most 3 words (e.g. debug-raft-election)" >&2
    echo "  --no-solution: open-ended task without a reference solution/solve.sh" >&2
    exit 2
fi

NAME="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_DIR="$ROOT/tasks/$NAME"
SCAFFOLD="$ROOT/scripts/task-scaffold"

# Same rule as scripts/checks/check-task-slug.sh, checked up front so a bad
# name fails before anything is created.
if ! [[ "$NAME" =~ ^[a-z0-9]+(-[a-z0-9]+){0,2}$ ]]; then
    echo "Task name must be lowercase kebab-case with at most 3 words: got '$NAME'" >&2
    exit 1
fi
if [ -e "$TASK_DIR" ]; then
    echo "$TASK_DIR already exists" >&2
    exit 1
fi
if ! command -v harbor > /dev/null; then
    echo "harbor not found. Install it with:" >&2
    echo "  uv tool install --python 3.12 \"harbor==\$(cat .github/harbor-version)\"" >&2
    exit 1
fi

PINNED="$(tr -d '[:space:]' < "$ROOT/.github/harbor-version")"
INSTALLED="$(harbor --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$PINNED" ]; then
    echo "warning: harbor $INSTALLED is installed but CI uses $PINNED (.github/harbor-version)" >&2
fi

cd "$ROOT"
harbor tasks init "$NAME" --org RealWorldEngineer --include-canary-strings \
    --metadata-template docs/task-template.toml -p tasks/ ${INIT_FLAGS[@]+"${INIT_FLAGS[@]}"}

# Harbor's tests/ scaffold installs pytest at verify time, which the static
# checks reject for separate-verifier tasks. Replace it.
rm -f "$TASK_DIR/tests/test_outputs.py"
cp "$SCAFFOLD/tests/Dockerfile" "$SCAFFOLD/tests/test.sh" "$SCAFFOLD/tests/test_state.py" "$TASK_DIR/tests/"
chmod +x "$TASK_DIR/tests/test.sh"
mkdir -p "$TASK_DIR/evidence"
cp "$SCAFFOLD/evidence/scores.json" "$TASK_DIR/evidence/"

python3 - "$TASK_DIR" "$NAME" "$SCAFFOLD/README.md" <<'PY'
import pathlib
import re
import sys

task_dir, name, readme_template = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])

checker = (task_dir.parent.parent / "scripts/checks/check-canary.sh").read_text()
ours = re.search(r'^CANARY_STRING="([^"]+)"', checker, re.M).group(1)
harbors = re.search(r'^HARBOR_CANARY="([^"]+)"', checker, re.M).group(1)

for path in task_dir.rglob("*"):
    if not path.is_file():
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    if harbors in text:
        path.write_text(text.replace(harbors, ours))

(task_dir / "README.md").write_text(readme_template.read_text().replace("{{TASK_NAME}}", name))

# The template's oracle anchor is the reward expected from solution/solve.sh.
if not (task_dir / "solution" / "solve.sh").is_file():
    toml = task_dir / "task.toml"
    toml.write_text(re.sub(r"(?m)^oracle = .*\n", "", toml.read_text(), count=1))

instruction = task_dir / "instruction.md"
instruction.write_text(
    instruction.read_text().rstrip("\n") + "\n\n<!-- Write the task instruction here. -->\n"
)
PY

echo
echo "Created tasks/$NAME. Next:"
echo "  1. Fill in instruction.md, environment/, tests/, task.toml [metadata], and README.md"
echo "     (and solution/solve.sh, unless you passed --no-solution)"
echo "  2. List every file the verifier reads from the agent in task.toml 'artifacts'"
echo "  3. Set the score anchors in task.toml [metadata.scoring] and record the baseline,"
echo "     reference and regrade runs behind them in evidence/scores.json"
echo "  4. Run the checks: for c in scripts/checks/check-*.sh; do bash \"\$c\" tasks/$NAME; done"
