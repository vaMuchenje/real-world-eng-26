#!/bin/bash
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/task.toml" <<'EOF'
[environment]
cpus = 1
memory_mb = 1024
[verifier.environment]
cpus = 32
memory_mb = 131072
EOF
bash "$(dirname "$0")/check-resource-sizes.sh" "$tmp"

sed -i.bak -e 's/cpus = 1/cpus = 3/' -e 's/cpus = 32/cpus = 3/' -e 's/memory_mb = 131072/memory_mb = 128000/' "$tmp/task.toml"
if bash "$(dirname "$0")/check-resource-sizes.sh" "$tmp" > "$tmp/output"; then
    echo "Expected invalid resource sizes to fail" >&2
    exit 1
fi
grep -q 'verifier.environment.cpus=3' "$tmp/output"
grep -q 'verifier.environment.memory_mb=128000' "$tmp/output"
grep -q ': environment.cpus=3;' "$tmp/output"
