#!/usr/bin/env python3
"""Bind imports of every analysis image (static PE loader step; never executes guest code).

- Import from another guest module (msvcr71, msvcp71, ...): the IAT slot gets the
  export's guest address (code or data), exactly as the Windows loader would.
- Import from a system DLL: the IAT slot gets a unique native-thunk address in the
  THUNK_BASE range. The translated code reaches it through the guest code map and
  the runtime handles it by (dll, name).

Writes <module>/<name>.bound.pe per module and <work>/imports.json.
usage: bind_imports.py <work/modules dir>
"""
import json, os, re, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.pydeps'))
import pefile  # noqa: E402

THUNK_BASE = 0xE0000000
THUNK_STRIDE = 8


def exports_of(pe):
    by_name, by_ord = {}, {}
    exp = getattr(pe, 'DIRECTORY_ENTRY_EXPORT', None)
    if exp:
        for s in exp.symbols:
            if s.forwarder:
                raise SystemExit(f'forwarded export {s.name} not supported')
            va = pe.OPTIONAL_HEADER.ImageBase + s.address
            if s.name:
                by_name[s.name.decode()] = va
            by_ord[s.ordinal] = va
    return by_name, by_ord


def main():
    root = sys.argv[1]
    manifest = json.load(open(os.path.join(root, 'manifest.json')))
    pes, paths = {}, {}
    for name in manifest:
        d = os.path.join(root, os.path.splitext(name)[0])
        paths[name] = os.path.join(d, name + '.analysis.pe')
        pes[name.lower()] = pefile.PE(paths[name])
    exports = {n: exports_of(p) for n, p in pes.items()}
    native = []          # index -> record
    native_index = {}    # (dll, name) -> index
    for name in manifest:
        pe = pes[name.lower()]
        raw = bytearray(open(paths[name], 'rb').read())
        bound = 0
        for d in getattr(pe, 'DIRECTORY_ENTRY_IMPORT', []):
            dll = d.dll.decode().lower()
            for imp in d.imports:
                sym = imp.name.decode() if imp.name else None
                slot_off = pe.get_offset_from_rva(imp.address - pe.OPTIONAL_HEADER.ImageBase)
                if dll in exports:
                    by_name, by_ord = exports[dll]
                    va = by_name.get(sym) if sym else by_ord.get(imp.ordinal)
                    if va is None:
                        raise SystemExit(f'{name}: {dll}!{sym or imp.ordinal} not exported')
                else:
                    key = (dll, sym if sym else f'#{imp.ordinal}')
                    if key not in native_index:
                        native_index[key] = len(native)
                        native.append({'dll': key[0], 'name': key[1],
                                       'address': THUNK_BASE + THUNK_STRIDE * len(native)})
                    va = native[native_index[key]]['address']
                    native[native_index[key]].setdefault('users', []).append(f'{name}@{imp.address:#x}')
                struct.pack_into('<I', raw, slot_off, va)
                bound += 1
        with open(os.path.join(os.path.dirname(paths[name]), name + '.bound.pe'), 'wb') as f:
            f.write(raw)
        print(f'{name:22} bound {bound} import slots')
    for i, r in enumerate(native):
        r['index'] = i
    json.dump(native, open(os.path.join(root, 'imports.json'), 'w'), indent=1)
    # plain-text copies for the C runtime
    with open(os.path.join(root, 'imports.txt'), 'w') as f:
        for r in native:
            f.write(f"{r['index']} {r['dll']} {r['name']}\n")
    with open(os.path.join(root, 'modules.txt'), 'w') as f:
        for name, m in manifest.items():
            pe = pes[name.lower()]
            unit = re.sub(r'[^A-Za-z0-9]', '_', os.path.splitext(name)[0])
            dll = 1 if pe.FILE_HEADER.Characteristics & 0x2000 else 0
            entry = m['base'] + pe.OPTIONAL_HEADER.AddressOfEntryPoint if pe.OPTIONAL_HEADER.AddressOfEntryPoint else 0
            f.write(f"{name} {unit} {m['base']:#x} {m['size']:#x} {entry:#x} {dll} "
                    f"{pe.OPTIONAL_HEADER.SizeOfStackReserve:#x} {m['sha256']}\n")
    print(f'native imports: {len(native)} from', sorted({r["dll"] for r in native}))


if __name__ == '__main__':
    main()
