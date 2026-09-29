#!/bin/bash
# Build llasm (LLasm -> LLVM IR) with LDC into port/build/llasm. LDC: port/third_party/ldc (official osx-arm64 release).
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PORT/build"
"$PORT/third_party/ldc/bin/ldc2" -O2 -of="$PORT/build/llasm" "$PORT/third_party/SR/llasm/llasm.d"
rm -f "$PORT/build/llasm.o"
