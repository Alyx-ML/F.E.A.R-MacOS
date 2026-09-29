#!/usr/bin/env python3
"""Prepare analysis copies of every F.E.A.R. guest module.

Reads the player's game folder, checks each module against its pinned SHA-256,
extracts archived modules from the LTAR archives, rebases each copy to a unique
guest base with its own relocation table, and verifies the result. The original
files are opened read-only. No guest code is executed.

usage: prepare.py <game dir> <out dir>
"""
import hashlib, json, os, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.pydeps'))
import pefile  # noqa: E402
import ltar  # noqa: E402

# name -> (source, sha256, guest base). Bases are unique and non-overlapping in
# the 32-bit guest window. Source is 'dir' or the archive holding the newest copy.
MODULES = {
    'FEAR.exe':              ('dir', 'c1678aa4df37e87c097f45d8eb68a7c379d99ad12d8da2771cf6235d9493d0b2', 0x00400000),
    'EngineServer.dll':      ('dir', None, 0x10000000),
    'GameDatabase.dll':      ('dir', None, 0x10200000),
    'StringEditRuntime.dll': ('dir', None, 0x10300000),
    'LTMemory.dll':          ('dir', None, 0x10400000),
    'SndDrv.dll':            ('dir', None, 0x10500000),
    'ClientFx.fxd':          ('FEARE_8.Arch00', None, 0x10600000),
    'GameClient.dll':        ('FEARE_8.Arch00', None, 0x10800000),
    'GameServer.dll':        ('FEARE_8.Arch00', None, 0x10c00000),
    'msvcr71.dll':           ('dir', None, 0x7c340000),
    'msvcp71.dll':           ('dir', None, 0x7c3a0000),
    'binkw32.dll':           ('dir', None, 0x18000000),
}
HASHES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'module_hashes.json')


def module_bytes(game, name, source):
    if source == 'dir':
        with open(os.path.join(game, name), 'rb') as f:
            return f.read()
    f, entries = ltar.read(os.path.join(game, source))
    for e in entries:
        if os.path.basename(e[0]).lower() == name.lower():
            return ltar.data(f, e)
    raise SystemExit(f'{name}: not found in {source}')


def reloc_sites(pe):
    sites = []
    for block in getattr(pe, 'DIRECTORY_ENTRY_BASERELOC', []):
        for e in block.entries:
            if e.type == 3:  # IMAGE_REL_BASED_HIGHLOW
                sites.append(e.rva)
            elif e.type != 0:  # 0 = padding
                raise SystemExit(f'unsupported relocation type {e.type} at {e.rva:#x}')
    return sites


def check(pe, base, sites, name):
    """Every relocated dword must point inside the image; entry/exports inside code."""
    size = pe.OPTIONAL_HEADER.SizeOfImage
    img = pe.get_memory_mapped_image()
    bad = [s for s in sites if not (base <= struct.unpack_from('<I', img, s)[0] < base + size)]
    if bad:
        # MSVC emits some relocated "end of array" pointers one past the image; allow == end only.
        hard = [s for s in bad if struct.unpack_from('<I', img, s)[0] != base + size]
        if hard:
            raise SystemExit(f'{name}: {len(hard)} relocation targets outside image, first at rva {hard[0]:#x}')
    code = [s for s in pe.sections if s.Characteristics & 0x20000000]
    def in_code(rva):
        return any(s.VirtualAddress <= rva < s.VirtualAddress + s.Misc_VirtualSize for s in code)
    ep = pe.OPTIONAL_HEADER.AddressOfEntryPoint
    if ep and not in_code(ep):
        raise SystemExit(f'{name}: entry point outside code')
    for s in getattr(getattr(pe, 'DIRECTORY_ENTRY_EXPORT', None), 'symbols', []):
        if s.forwarder is None and not in_code(s.address) and not s.name.startswith(b'?_'):
            # data exports (mangled variables) are allowed outside code
            if not any(sec.VirtualAddress <= s.address < sec.VirtualAddress + sec.Misc_VirtualSize for sec in pe.sections):
                raise SystemExit(f'{name}: export {s.name} outside image')
    return len(bad)


def main():
    game, out = sys.argv[1], sys.argv[2]
    pinned = json.load(open(HASHES)) if os.path.exists(HASHES) else {}
    manifest = {}
    for name, (source, sha, base) in MODULES.items():
        raw = module_bytes(game, name, source)
        digest = hashlib.sha256(raw).hexdigest()
        want = sha or pinned.get(name)
        if want and digest != want:
            raise SystemExit(f'{name}: unsupported version (sha256 {digest}, expected {want})')
        pe = pefile.PE(data=raw)
        if pe.FILE_HEADER.Machine != 0x14c:
            raise SystemExit(f'{name}: not an i386 PE')
        sites = reloc_sites(pe)
        if not sites and pe.OPTIONAL_HEADER.ImageBase != base:
            raise SystemExit(f'{name}: no relocations, cannot rebase')
        old = pe.OPTIONAL_HEADER.ImageBase
        # Rebase on raw bytes: add the delta at each HIGHLOW site and set ImageBase.
        # (pefile.write() rewrites parsed import thunks, which corrupts the lookup table.)
        out_bytes = bytearray(raw)
        delta = (base - old) & 0xffffffff
        for rva in sites:
            off = pe.get_offset_from_rva(rva)
            if off is None or off + 4 > len(out_bytes):
                raise SystemExit(f'{name}: relocation site {rva:#x} has no file bytes')
            v = struct.unpack_from('<I', out_bytes, off)[0]
            struct.pack_into('<I', out_bytes, off, (v + delta) & 0xffffffff)
        struct.pack_into('<I', out_bytes, pe.OPTIONAL_HEADER.get_field_absolute_offset('ImageBase'), base)
        dst = os.path.join(out, os.path.splitext(name)[0])
        os.makedirs(dst, exist_ok=True)
        path = os.path.join(dst, name + '.analysis.pe')
        with open(path, 'wb') as f:
            f.write(out_bytes)
        edge = check(pefile.PE(path), base, sites, name)
        manifest[name] = {'sha256': digest, 'source': source, 'original_base': old, 'base': base,
                          'size': pe.OPTIONAL_HEADER.SizeOfImage, 'relocations': len(sites), 'end_pointers': edge}
        print(f'{name:22} {digest[:16]} base {old:#010x} -> {base:#010x} relocs {len(sites)}')
    bases = sorted((m['base'], m['base'] + m['size'], n) for n, m in manifest.items())
    for (a0, a1, n0), (b0, b1, n1) in zip(bases, bases[1:]):
        if a1 > b0:
            raise SystemExit(f'{n0} overlaps {n1}')
    if not pinned:
        json.dump({n: m['sha256'] for n, m in manifest.items()}, open(HASHES, 'w'), indent=1)
    json.dump(manifest, open(os.path.join(out, 'manifest.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
