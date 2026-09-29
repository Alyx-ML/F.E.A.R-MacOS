#!/bin/bash
# Dev build: runtime + translated units -> build/fear-dev, cache index -> work/cache.
# RUNTIME_ONLY=<output path>: link only the runtime (the packaged app loads converted code from its cache).
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
CC=/usr/bin/clang
SUP="$PORT/third_party/SR/SR/llasm-support"
OBJ="$PORT/build/runtime"; mkdir -p "$OBJ"
CFLAGS=(-target arm64-apple-macos26 -O2 -g -Wall -Wextra -Wno-unused-parameter -DPTROFS_64BIT -I"$PORT/runtime" -I"$SUP" -I/opt/homebrew/include)
for f in "$PORT"/runtime/*.c; do "$CC" "${CFLAGS[@]}" -c "$f" -o "$OBJ/$(basename "$f" .c).o"; done
for f in "$PORT"/runtime/*.m; do "$CC" "${CFLAGS[@]}" -fobjc-arc -c "$f" -o "$OBJ/$(basename "$f" .m).mo.o"; done
for f in llasm_float llasm_divide llasm_movs llasm_stos llasm_cmps llasm_scas llasm_pushx llasm_int llasm_inout; do
  "$CC" "${CFLAGS[@]}" -Wno-sign-compare -w -c "$SUP/$f.c" -o "$OBJ/sr_$f.o"
done
LINK=("$CC" -target arm64-apple-macos26 -Wl,-export_dynamic -L/opt/homebrew/lib -lSDL3 -Wl,-rpath,/opt/homebrew/lib -framework AppKit -framework QuartzCore -framework Metal -framework CoreText -framework CoreGraphics -framework ImageIO -framework CoreServices -framework UniformTypeIdentifiers -framework AVFoundation -framework AudioToolbox -framework MetalFX)
if [ -n "${RUNTIME_ONLY:-}" ]; then
  "${LINK[@]}" -o "$RUNTIME_ONLY" "$OBJ"/*.o
  echo built "$RUNTIME_ONLY"
  exit 0
fi
"${LINK[@]}" -o "$PORT/build/fear-dev" "$OBJ"/*.o "$PORT"/work/units/*/unit.o
CACHE="$PORT/work/cache"; mkdir -p "$CACHE/images"
cp "$PORT/work/modules/modules.txt" "$PORT/work/modules/imports.txt" "$PORT/work/units/hooks.txt" "$CACHE/"
for d in "$PORT"/work/modules/*/; do for f in "$d"*.bound.pe; do [ -e "$f" ] && cp "$f" "$CACHE/images/"; done; done
echo built "$PORT/build/fear-dev"
