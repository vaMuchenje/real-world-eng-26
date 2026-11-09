#!/usr/bin/env bash
# Container entry point. The verifier checks this file's SHA-256 digest.

set -eu

FRONTIER_TIMER_BOOTSTRAP=1 env -u BASH_ENV -u ENV /app/timer.sh >/dev/null 2>&1 &

if [ "$#" -eq 0 ]; then
    exec tail -f /dev/null
fi

exec "$@"
