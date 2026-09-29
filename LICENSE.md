# License information

## This port (port/runtime, port/tools, launcher)

MIT License. Copyright (c) 2026 the FEAR-MacOS-Metal contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Third-party code

- SR / SRW (port/third_party/SR): MIT, Roman Pauer. Modified for this port. Includes udis86 (BSD) and other libraries
  under their own licences inside that tree.
- LLVM and LLD (bundled tools): Apache-2.0 with LLVM exceptions.
- CPython (bundled): PSF licence. zstd (BSD), z3 (MIT).
- SDL3: zlib licence. capstone: BSD. pefile: MIT.
- EchoPatch (github.com/Wemino/EchoPatch, GPL-3.0, Wemino and contributors): the byte signatures for the game's input
  functions (`port/tools/hooks.py`) and the default controller layout follow it. No EchoPatch code is included.
Licence texts for the bundled binaries are inside the app in Contents/Resources/licenses.
