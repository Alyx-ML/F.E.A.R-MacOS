#!/bin/bash
# Headless dev run; prints the tail of the log. usage: run_dev.sh [seconds]
PORT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PORT/work/userdata"
GP_HEADLESS=${GP_HEADLESS:-1} GP_USER_DIR="$PORT/work/userdata" timeout "${1:-60}" "$PORT/build/fear-dev" "$PORT/work/cache" "$PORT/.." < /dev/null > "$PORT/work/run.log" 2>&1
echo "rc=$?"
grep -v "^[0-9]* *fear-dev\|^[0-9] " "$PORT/work/run.log" | tail -${TAIL:-8}
