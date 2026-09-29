#!/bin/bash
# Build dist/FEAR Native.app: the runtime plus the first-launch converter. No game files, no converted code.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PORT/dist/FEAR Native.app"
RES="$APP/Contents/Resources"
CONV="$RES/converter"

"$PORT/tools/build_srw.sh" "$PORT/build/srw"
[ -x "$PORT/build/llasm" ] || "$PORT/tools/build_llasm.sh"
RUNTIME_ONLY="$PORT/build/fear-app" "$PORT/tools/build_dev.sh"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$CONV/tools" "$CONV/build/srw" "$CONV/runtime/llasm" "$CONV/third_party/SR/SR/llasm-support" "$CONV/pydeps"
cp "$PORT/build/fear-app" "$APP/Contents/MacOS/FEARNative"
# SDL3 (game controllers) travels inside the app instead of being taken from Homebrew
mkdir -p "$APP/Contents/Frameworks"
cp "$(python3 -c 'import os;print(os.path.realpath("/opt/homebrew/lib/libSDL3.0.dylib"))')" "$APP/Contents/Frameworks/libSDL3.0.dylib"
install_name_tool -id @rpath/libSDL3.0.dylib "$APP/Contents/Frameworks/libSDL3.0.dylib"
install_name_tool -change /opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib @rpath/libSDL3.0.dylib "$APP/Contents/MacOS/FEARNative"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/FEARNative"
cp "$PORT"/tools/{convert,prepare,recover,bind_imports,translate,ltar,hooks,splitir}.py "$PORT/tools/module_hashes.json" "$CONV/tools/"
cp -R "$PORT/tools/stub" "$CONV/tools/stub"
"$PORT/tools/make_toolchain.sh" "$CONV/toolchain"
cp "$PORT/build/srw/srw" "$CONV/build/srw/srw"
cp "$PORT/build/llasm" "$CONV/build/llasm"
cp "$PORT"/runtime/llasm/*.llinc "$CONV/runtime/llasm/"
cp "$PORT"/third_party/SR/SR/llasm-support/*.llinc "$PORT"/third_party/SR/SR/llasm-support/*.h "$CONV/third_party/SR/SR/llasm-support/"
cp -R "$PORT/.pydeps/capstone" "$PORT/.pydeps/ordlookup" "$PORT/.pydeps/pefile.py" "$PORT/.pydeps/peutils.py" "$CONV/pydeps/"
find "$CONV" -name __pycache__ -prune -exec rm -rf {} +

# licences of the bundled third-party code
mkdir -p "$RES/licenses"
[ -f /opt/homebrew/opt/sdl3/LICENSE.txt ] && cp /opt/homebrew/opt/sdl3/LICENSE.txt "$RES/licenses/SDL3-LICENSE.txt"
cp "$CONV"/toolchain/licenses/*.txt "$RES/licenses/"
cp "$PORT/.pydeps/capstone-5.0.9.dist-info/LICENSE.TXT" "$RES/licenses/capstone-LICENSE.txt"
cp "$PORT/.pydeps/pefile-2024.8.26.dist-info/LICENSE" "$RES/licenses/pefile-LICENSE.txt"
cp "$PORT/third_party/SR/SR/README.md" "$RES/licenses/SR-README.md" 2>/dev/null || true
cat > "$RES/licenses/NOTICE.txt" <<'N'
The converter uses SR (static recompiler, MIT licence, Roman Pauer), udis86 (BSD), capstone (BSD) and pefile (MIT).
Game controllers use SDL3 (zlib licence).
The first-launch converter bundles LLVM/LLD (Apache-2.0 with LLVM exception), zstd (BSD), z3 (MIT) and CPython (PSF licence).
The app contains no game files and no code derived from the game. The converted game code is created on the
player's own Mac from the player's own copy of the game and is kept in ~/Library/Application Support/FEAR Native.
N

cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleName</key><string>FEAR Native</string>
 <key>CFBundleDisplayName</key><string>FEAR Native</string>
 <key>CFBundleIdentifier</key><string>local.gameport.fear</string>
 <key>CFBundleExecutable</key><string>FEARNative</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>0.1</string>
 <key>CFBundleVersion</key><string>1</string>
 <key>LSMinimumSystemVersion</key><string>26.0</string>
 <key>NSHighResolutionCapable</key><true/>
 <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
 <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict></plist>
P
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo built "$APP"
