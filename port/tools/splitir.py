#!/usr/bin/env python3
"""Split one LLVM IR text module (llasm output) into several modules that link back together.

Apple's toolchain has no llvm-split, and compiling a large module whole needs about 80 bytes of memory per byte of IR
(measured: 131 MB of IR took 10.4 GB). llasm's output is regular: a header (types, declarations, a few globals), then
one `define` block per procedure, then the lookup tables and entry functions. This tool:
  - spreads the procedures over N parts, balanced by size;
  - keeps everything that is not a public procedure (tables, private helpers' users) in part 0;
  - turns private procedures (loc_*) into hidden ones so they can live in one part and be called from the others without
    being exported from the final library; other private helpers are copied into every part;
  - adds a `declare` to each part for every procedure it calls that another part defines.
usage: splitir.py <unit.ll> <parts> <out prefix>   -> writes <out prefix>0 .. <out prefix>N-1
"""
import os, re, sys

NAME = re.compile(r'@([A-Za-z0-9_.$]+)')
DEFINE_NAME = re.compile(r'^define [^@]*@([A-Za-z0-9_.$]+)\(')


def scan(path):
    """One pass: (header line count, list of (name, first line, last line, private?) per define block)."""
    blocks = []
    start = name = None
    private = False
    with open(path, errors='replace') as f:
        for i, line in enumerate(f):
            if start is None:
                if line.startswith('define '):
                    m = DEFINE_NAME.match(line)
                    if not m:
                        raise SystemExit(f'splitir: cannot read the function name in line {i + 1}: {line[:120]}')
                    start, name, private = i, m.group(1), ' private ' in line[:24] or line.startswith('define private ')
            elif line.startswith('}'):
                blocks.append((name, start, i, private))
                start = None
    if start is not None:
        raise SystemExit('splitir: unterminated function at the end of the file')
    return blocks


def split(path, parts, prefix):
    blocks = scan(path)
    is_proc = lambda b: b[0].startswith(('loc_', 'c_loc_'))
    public = [b for b in blocks if is_proc(b)]                # private procedures are shared as hidden ones
    assign = {}                                  # first line of a block -> part
    load = [0] * parts
    for name, a, z, _ in sorted(public, key=lambda b: b[2] - b[1], reverse=True):     # largest first, into the emptiest part
        p = min(range(parts), key=lambda k: load[k])
        assign[a] = p
        load[p] += z - a + 1
    private_blocks = {b[1]: b for b in blocks if b[3] and not is_proc(b)}     # small helpers: one copy per part
    defined_in = {b[0]: assign.get(b[1], 0) for b in blocks if not b[3] or is_proc(b)}   # every shareable function; unassigned ones stay in part 0
    signatures = {}
    outs = [open(f'{prefix}{k}', 'w') for k in range(parts)]
    try:
        with open(path, errors='replace') as f:
            current = None                        # parts the current block goes to
            for i, line in enumerate(f):
                if current is not None:
                    for k in current: outs[k].write(line)
                    if line.startswith('}'): current = None
                    continue
                if line.startswith('define '):
                    if i in private_blocks:
                        current = list(range(parts))          # private helpers exist in every part
                    else:
                        current = [assign.get(i, 0)]           # procedures by assignment; tables, entry points and other public code in part 0
                        if line.startswith('define private '):
                            line = 'define hidden ' + line[len('define private '):]      # shareable across parts, not exported
                        signatures[DEFINE_NAME.match(line).group(1)] = line.rstrip()
                    for k in current: outs[k].write(line)
                    continue
                if line.startswith('@'):
                    # definitions with initialisers cannot repeat; externals and common symbols can
                    if ' = external ' in line or ' = common ' in line: targets = range(parts)
                    else: targets = [0]
                    for k in targets: outs[k].write(line)
                else:
                    for k in range(parts): outs[k].write(line)   # header, declarations, comments, blank lines
    finally:
        for o in outs: o.close()
    # declarations for procedures a part calls but does not define
    for k in range(parts):
        text = open(f'{prefix}{k}', errors='replace').read()
        used = set(NAME.findall(text))
        with open(f'{prefix}{k}', 'a') as o:
            for name in sorted(used):
                if name in defined_in and defined_in[name] != k:
                    decl = signatures[name]
                    decl = 'declare ' + decl[len('define '):].rstrip('{').rstrip()
                    o.write(decl + '\n')
    # every part must stay small: clang needs ~80 bytes of memory per byte of IR
    limit = 3 * (sum(load) // parts + 1) + (64 << 20)
    for k in range(parts):
        size = os.path.getsize(f'{prefix}{k}')
        if size > limit:
            raise SystemExit(f'splitir: part {k} is {size >> 20} MB, far above the expected {(sum(load) // parts) >> 20} MB; not compiling it')
    return [f'{prefix}{k}' for k in range(parts)]


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    for p in split(sys.argv[1], int(sys.argv[2]), sys.argv[3]):
        print(p)
