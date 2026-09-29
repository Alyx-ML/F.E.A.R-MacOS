#!/bin/bash
# Build SRW (LLasm output) from third_party/SR. Usage: build_srw.sh <outdir> [extra cflags...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; shift
mkdir -p "$OUT"
cd "$ROOT/third_party/SR/SRW"
F=(-O2 -Iudis86-1.7.2 -DHAVE_STRING_H=1 -DOUTPUT_TYPE=OUT_LLASM "$@")
for f in *.c udis86-1.7.2/libudis86/*.c; do clang -c "${F[@]}" -w -o "$OUT/$(basename "$f" .c).o" "$f"; done
clang++ -c "${F[@]}" -std=c++20 -o "$OUT/container_helpers.o" container_helpers.cpp
clang++ "$@" -o "$OUT/srw" "$OUT"/*.o
