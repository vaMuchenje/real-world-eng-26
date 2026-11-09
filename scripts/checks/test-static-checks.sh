#!/bin/bash
# Regression tests for the static checks. Run from the repo root:
#   bash scripts/checks/test-static-checks.sh
#
# 1. Every check-*.sh is wired into .github/workflows/static-checks.yml and
#    documented, every script the workflow lists exists, and
#    docs/task-schema.json matches .github/harbor-version.
# 2. Every check passes on every task in tasks/.
# 3. Every fail-static-* fixture fails its target check with a FAIL line.
#    (Fixtures may also trip unrelated checks; only the target is asserted.)
# 4. The check-specific unit tests (test-*.sh, test-*.py) pass.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
CHECKS_DIR=scripts/checks
FIXTURES=$CHECKS_DIR/test-tasks
WORKFLOW=.github/workflows/static-checks.yml
ERRORS=0

fail() {
    echo "FAIL: $*"
    ERRORS=$((ERRORS + 1))
}

# Fixture -> target check, where the name doesn't map directly
# (fail-static-<x> -> check-<x>.sh otherwise).
target_for() {
    case "$1" in
        fail-static-canary-format) echo check-canary.sh ;;
        fail-static-dockerfile-refs) echo check-dockerfile-references.sh ;;
        fail-static-test-refs) echo check-test-file-references.sh ;;
        fail-static-invalid-category) echo check-task-fields.sh ;;
        fail-static-task-slug-too-long) echo check-task-slug.sh ;;
        fail-static-absolute-path) echo check-task-absolute-path.sh ;;
        fail-static-allow-internet) echo check-network-mode.sh ;;
        *) echo "check-${1#fail-static-}.sh" ;;
    esac
}

# 1. Workflow wiring.
WIRED=$(grep -oE 'check-[a-z0-9-]+\.sh' "$WORKFLOW" | sort -u)
for script in $WIRED; do
    [ -f "$CHECKS_DIR/$script" ] || fail "$WORKFLOW lists $script, which does not exist"
done
for path in "$CHECKS_DIR"/check-*.sh; do
    script=$(basename "$path")
    echo "$WIRED" | grep -qx "$script" || fail "$script is not listed in $WORKFLOW"
    grep -q "^#### ${script%.sh}\$" docs/TASK_REVIEW_AUTOMATION.md \
        || fail "$script has no '#### ${script%.sh}' section in docs/TASK_REVIEW_AUTOMATION.md"
done

# The committed schema must match the Harbor version CI installs.
PINNED=$(tr -d '[:space:]' < .github/harbor-version)
SCHEMA_VERSION=$(python3 -c "import json; print(json.load(open('docs/task-schema.json')).get('x-harbor-version', ''))")
[ "$SCHEMA_VERSION" = "$PINNED" ] \
    || fail "docs/task-schema.json is for harbor '$SCHEMA_VERSION' but .github/harbor-version is '$PINNED'; run scripts/update-task-schema.sh"

# 2. Real tasks pass every check.
for task in tasks/*/; do
    task=${task%/}
    for script in $WIRED; do
        if ! out=$(bash "$CHECKS_DIR/$script" "$task" 2>&1); then
            fail "$script fails on $task:"
            echo "$out" | grep '^FAIL' | sed 's/^/    /'
        fi
    done
done

# 3. Fixtures fail their target check.
for fixture in "$FIXTURES"/fail-static-*/; do
    name=$(basename "$fixture")
    script=$(target_for "$name")
    if [ ! -f "$CHECKS_DIR/$script" ]; then
        fail "$name: target check $script does not exist (update target_for)"
        continue
    fi
    if out=$(bash "$CHECKS_DIR/$script" "${fixture%/}" 2>&1); then
        fail "$name: expected $script to fail, but it passed"
    elif ! echo "$out" | grep -q '^FAIL '; then
        fail "$name: $script exited non-zero without a FAIL line"
    fi
done

# 4. Unit tests for individual checks.
for t in "$CHECKS_DIR"/test-*.sh; do
    [ "$(basename "$t")" = "$(basename "$0")" ] && continue
    bash "$t" > /dev/null 2>&1 || fail "$(basename "$t") failed (run it directly for output)"
done
for t in "$CHECKS_DIR"/test-*.py; do
    python3 "$t" > /dev/null 2>&1 || fail "$(basename "$t") failed (run it directly for output)"
done

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "$ERRORS static-check test(s) failed"
    exit 1
fi
echo "All static-check tests passed"
