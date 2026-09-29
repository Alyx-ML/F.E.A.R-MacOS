#!/usr/bin/env python3
"""List/extract files from LithTech LTAR v3 archives (.Arch00). Read-only on input."""
import struct, sys, os, zlib

def read(path):
    f = open(path, 'rb')
    magic, ver, nsz, ndir, nfile = struct.unpack('<4sIIII', f.read(20))
    if magic != b'LTAR' or ver != 3:
        raise SystemExit(f'{path}: not LTAR v3')
    f.seek(0x30)
    names = f.read(nsz)
    files = [struct.unpack('<IQQQI', f.read(32)) for _ in range(nfile)]
    dirs = [struct.unpack('<IIII', f.read(16)) for _ in range(ndir)]
    name = lambda o: names[o:names.index(b'\0', o)].decode('latin1')
    out, fi = [], 0
    for d in dirs:  # files are stored in directory order
        dn = name(d[0])
        for _ in range(d[3]):
            no, off, csz, sz, comp = files[fi]; fi += 1
            out.append((os.path.join(dn, name(no)).replace('\\', '/'), off, csz, sz, comp))
    assert fi == nfile, (fi, nfile)
    return f, out

def data(f, e):
    _, off, csz, sz, comp = e
    f.seek(off); b = f.read(csz)
    if comp:
        b = zlib.decompress(b)
    if len(b) != sz:
        raise SystemExit(f'{e[0]}: size {len(b)} != {sz}')
    return b

if __name__ == '__main__':
    f, ents = read(sys.argv[1])
    pat = sys.argv[2].lower() if len(sys.argv) > 2 else None
    for e in ents:
        if pat and pat not in e[0].lower(): continue
        if len(sys.argv) > 3:
            dst = os.path.join(sys.argv[3], os.path.basename(e[0]))
            open(dst, 'wb').write(data(f, e)); print('wrote', dst, e[3])
        else:
            print(e[0], e[3], 'z' if e[4] else '')
