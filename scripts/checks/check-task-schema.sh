#!/bin/bash

# Validates task.toml against Harbor's task config schema (docs/task-schema.json,
# generated for the Harbor version in .github/harbor-version by
# scripts/update-task-schema.sh). Harbor silently ignores fields it does not
# know, so a typo such as `timeout_secs` would otherwise take effect as the
# default without anyone noticing. Also rejects retired metadata fields
# that RealWorldEngineer keeps elsewhere or does not use.
#
# [metadata] is free-form in Harbor; required RealWorldEngineer fields are enforced
# by check-task-fields.sh.

set -e

SCHEMA="$(cd "$(dirname "$0")/../.." && pwd)/docs/task-schema.json"

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

if [ ! -f "$SCHEMA" ]; then
    echo "FAIL $SCHEMA: schema not found; run scripts/update-task-schema.sh"
    exit 1
fi

FAILED=0
for file in $FILES_TO_CHECK; do
    if [ ! -f "$file" ]; then
        echo "File $file does not exist, skipping"
        continue
    fi

    echo "Checking $file..."

    RESULT=$(python3 - "$file" "$SCHEMA" <<'PYEOF'
import difflib
import json
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # type: ignore

path, schema_path = sys.argv[1], sys.argv[2]
schema = json.load(open(schema_path))
defs = schema.get("$defs", {})
HARBOR = f"Harbor {schema['x-harbor-version']}" if "x-harbor-version" in schema else "Harbor"

# Retired fields that do not belong in a RealWorldEngineer task.toml.
RETIRED_METADATA = {
    "difficulty_explanation": "moved to the '## Difficulty explanation' section of README.md",
    "solution_explanation": "moved to the '## What success looks like' section of README.md",
    "verification_explanation": "moved to the '## Verification explanation' section of README.md",
    "relevant_experience": "moved to the optional '## Relevant experience' section of README.md",
    "referral": "RealWorldEngineer has no referral program",
}

TYPES = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
    "null": lambda v: v is None,
}


def resolve(node):
    while "$ref" in node:
        node = defs[node["$ref"].rsplit("/", 1)[-1]]
    return node


def type_name(value):
    for name in ("boolean", "integer", "number", "string", "array", "object"):
        if TYPES[name](value):
            return name
    return type(value).__name__


def validate(value, node, where):
    node = resolve(node)
    if "anyOf" in node:
        branches = [resolve(b) for b in node["anyOf"]]
        results = [validate(value, b, where) for b in branches]
        if any(not r for r in results):
            return []
        # Report against the branch whose type matches, if any, for a precise message.
        for branch, errs in zip(branches, results):
            t = branch.get("type")
            if t and TYPES.get(t, lambda v: False)(value):
                return errs
        wanted = sorted({b.get("type") or b.get("title") or "?" for b in branches} - {"null"})
        return [f"{where}: expected {' or '.join(wanted)}, got {type_name(value)}"]

    errors = []
    t = node.get("type")
    if t and not TYPES[t](value):
        return [f"{where}: expected {t}, got {type_name(value)}"]
    if "enum" in node and value not in node["enum"]:
        return [f"{where}: {value!r} is not one of {node['enum']}"]
    if isinstance(value, str) and len(value) < node.get("minLength", 0):
        errors.append(f"{where}: must not be empty")

    if isinstance(value, dict):
        props = node.get("properties", {})
        extra = node.get("additionalProperties")
        for key, sub in value.items():
            child = f"{where}.{key}" if where else key
            if key in props:
                errors += validate(sub, props[key], child)
            elif isinstance(extra, dict):
                errors += validate(sub, extra, child)
            elif extra is True or not props:
                continue
            else:
                hint = difflib.get_close_matches(key, props, n=1)
                suggestion = f" (did you mean '{hint[0]}'?)" if hint else ""
                errors.append(f"{child}: unknown field; {HARBOR} ignores it{suggestion}")
        for key in node.get("required", []):
            if key not in value:
                errors.append(f"{where + '.' if where else ''}{key}: required field is missing")

    if isinstance(value, list) and "items" in node:
        for i, item in enumerate(value):
            errors += validate(item, node["items"], f"{where}[{i}]")
    return errors


try:
    with open(path, "rb") as f:
        data = tomllib.load(f)
except tomllib.TOMLDecodeError as e:
    print(f"invalid TOML: {e}")
    sys.exit(1)

errors = validate(data, schema, "")
metadata = data.get("metadata", {})
if isinstance(metadata, dict):
    for key, reason in RETIRED_METADATA.items():
        if key in metadata:
            errors.append(f"metadata.{key}: not a RealWorldEngineer field; {reason}")

if errors:
    print("\n".join(errors))
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
    echo "Some task.toml files contain fields Harbor does not recognize or values of the wrong type."
    echo "See docs/task-schema.json (Harbor $(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('x-harbor-version','?'))" "$SCHEMA"))."
    exit 1
fi

echo "All task.toml files match the Harbor task schema"
