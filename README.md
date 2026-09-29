# F.E.A.R. for Apple silicon — preview

Unofficial native macOS port of the single-player game F.E.A.R. for Apple silicon Macs. It does not use Rosetta,
Wine, CrossOver, emulation or a JIT. The game's x86 code is statically recompiled to ARM64 on your Mac, and a native
runtime provides the Windows, Direct3D 9 (drawn with Metal 4), DirectSound and DirectInput calls the game makes.

You need an Apple silicon Mac running macOS 26 or later, and your own copy of the game. This download contains no
game files and no code derived from the game.

## Use

1. Download `FEAR-Native-macOS-ARM64.zip` from the Releases page and unzip it.
2. Open **FEAR Native.app**. It looks for your F.E.A.R. folder and shows it in the launcher. Use **Change…** if it
   picked the wrong one or found none. The folder is the installed game (it contains `FEAR.exe` and the `.Arch00` files).
3. Choose a resolution, and MetalFX and HDR if you want them, then press **Play**.

The first launch converts the game on your Mac. This takes about 6 minutes, uses several GB of memory and about
90 MB of disk space, and needs nothing installed. Later launches start straight away. The result is stored in
`~/Library/Application Support/FEAR Native/` and is rebuilt automatically if the game files or the app change.
Your game folder is not modified.

Downloaded apps with an ad-hoc signature need approval the first time: open System Settings > Privacy & Security and
choose Open Anyway. The app is not notarized.

## Supported

- One exact build of the game: `FEAR.exe` must match the SHA-256 in `port/tools/module_hashes.json`. Other builds
  are refused with a message rather than converted wrongly. Steam, retail and Platinum Collection copies may differ.
- Single-player only.
- Keyboard and mouse. Xbox and PlayStation controllers work (SDL3); bindings are in `gamepad.cfg`.
- 16:9 is preserved with black bars when the window has a different shape.

## Known problems

- Looping stereo sound (mostly ambience and music) is muted by default because it played with background distortion.
  The cause is not found yet.
- Separate button for Activate (doors, items) is not mapped on the controller.
- Not tested on a Mac without Xcode; tested on one Mac only.
- MetalFX and HDR work but have had little visual checking.

## Build from source

Needs Xcode (macOS 26+ SDK), Homebrew `llvm`, `lld`, `sdl3`, a standalone CPython 3.12 (for example from `uv`), the
`capstone` and `pefile` Python packages installed into `port/.pydeps`, and the official LDC compiler
(osx-arm64 release) unpacked at `port/third_party/ldc`.

    cd port
    tools/package.sh

This builds the SR recompiler, `llasm`, the runtime and the bundled converter toolchain, and writes
`port/dist/FEAR Native.app` (ad-hoc signed). `tools/build_dev.sh` builds only the runtime for development.

## Credits and licences

The static recompiler is SR/SRW by Roman Pauer (MIT), kept in `port/third_party/SR` with the changes this port needed.
Controller support is based on EchoPatch by Wemino (github.com/Wemino/EchoPatch, GPL-3.0): the byte signatures used to find the game's input functions, and the default button layout, come from it. The app bundles LLVM/LLD, zstd, z3, CPython, SDL3,
capstone and pefile; their licences are in the app under `Contents/Resources/licenses`. See `LICENSE.md`.
"F.E.A.R." is a trademark of its owners; this project is not affiliated with them.
