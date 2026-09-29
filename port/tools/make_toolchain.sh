#!/bin/bash
# Copy the self-contained converter toolchain into <dest>: LLVM opt, llc, ld64.lld (with their libraries) and a
# relocatable CPython. Players then need no Xcode or Command Line Tools. Sources: Homebrew LLVM/LLD and uv's CPython.
set -euo pipefail
DEST="$1"
LLVM=/opt/homebrew/opt/llvm
LLD=/opt/homebrew/opt/lld
PY="$(ls -d "$HOME"/.local/share/uv/python/cpython-3.12.*-macos-aarch64-none | sort | tail -1)"
[ -x "$PY/bin/python3" ] || { echo "no standalone CPython 3.12 found" >&2; exit 1; }
chmod -R u+w "$DEST" 2>/dev/null || true; rm -rf "$DEST"
mkdir -p "$DEST/llvm/bin" "$DEST/llvm/lib"
for t in "$LLVM/bin/opt" "$LLVM/bin/llc" "$LLD/bin/ld64.lld"; do cp "$(readlink -f "$t")" "$DEST/llvm/bin/$(basename "$t")"; done
cp "$(readlink -f "$LLVM/lib/libLLVM.dylib")" "$DEST/llvm/lib/libLLVM.23.1.dylib"; chmod u+w "$DEST/llvm/lib/libLLVM.23.1.dylib"
for l in "$LLD"/lib/liblld*.23.1.dylib; do cp "$(readlink -f "$l")" "$DEST/llvm/lib/"; done
# Homebrew libraries the tools need (zstd, z3): copy them next to the others; references are rewritten below
for f in "$DEST"/llvm/bin/* "$DEST"/llvm/lib/*; do
  for dep in $(otool -L "$f" | awk '/\/opt\/homebrew/ {print $1}'); do
    [ -e "$DEST/llvm/lib/$(basename "$dep")" ] || cp "$(readlink -f "$dep")" "$DEST/llvm/lib/$(basename "$dep")"; chmod u+w "$DEST/llvm/lib/$(basename "$dep")"
  done
done
chmod -R u+w "$DEST/llvm"
for f in "$DEST"/llvm/bin/* "$DEST"/llvm/lib/*; do
  for dep in $(otool -L "$f" | awk '/\/opt\/homebrew/ {print $1}'); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
  done
  case "$f" in *.dylib) install_name_tool -id "@rpath/$(basename "$f")" "$f"; install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true;; esac
  codesign --force --sign - --timestamp=none "$f"
done
# every non-system library reference must now be inside the bundle
if otool -L "$DEST"/llvm/bin/* "$DEST"/llvm/lib/* | grep -E "/opt/homebrew|/usr/local"; then echo "toolchain still refers to Homebrew" >&2; exit 1; fi
mkdir -p "$DEST/licenses"
cp "$LLVM/LICENSE.TXT" "$DEST/licenses/LLVM.txt"
cp "$PY/lib/python3.12/LICENSE.txt" "$DEST/licenses/Python.txt" 2>/dev/null || true
rsync -a --exclude test --exclude idlelib --exclude tkinter --exclude turtledemo --exclude __pycache__ --exclude site-packages --exclude ensurepip --exclude 'config-3.12-darwin' "$PY/" "$DEST/python/"
"$DEST/python/bin/python3" -c "import sys; print('python', sys.version.split()[0])"
"$DEST/llvm/bin/llc" --version | sed -n 2p
