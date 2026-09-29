#!/usr/bin/env python3
"""Translate recovered, bound guest modules to ARM64 objects.

Per module: SRW (fixed guest image) -> LLasm -> LLVM IR (llasm) -> ARM64 object (opt + llc).
Plus one unit holding every native-import thunk.

usage: translate.py <work/modules dir> <out dir> [module ...]
Environment: GP_TOOLS (dir with srw/srw, llasm), GP_LLVM (dir with bin/opt and bin/llc).
"""
import json, os, re, shutil, subprocess, sys, concurrent.futures as cf

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
TOOLS = os.environ.get('GP_TOOLS', os.path.join(PORT, 'build'))
SRW = os.path.join(TOOLS, 'srw', 'srw')
LLASM = os.path.join(TOOLS, 'llasm')
LLVM_BIN = os.path.join(os.environ.get('GP_LLVM', os.path.join(PORT, 'toolchain', 'llvm')), 'bin')
SUPPORT = os.path.join(PORT, 'third_party', 'SR', 'SR', 'llasm-support')
RUNTIME_LLINC = os.path.join(PORT, 'runtime', 'llasm')
TARGET = 'arm64-apple-macos26'
DATA_LAYOUT = 'e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32'
# modules whose guest code uses SSE only behind the CRT's own SSE2 check
NO_SSE = {'msvcr71.dll'}
DYN_THUNK_BASE = 0xE8000000
DYN_THUNKS = 512
DYN_INDEX_BASE = 0x10000


def run(cmd, cwd, log):
    with open(log, 'w') as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        tail = open(log).read()[-3000:]
        raise SystemExit(f'failed ({r.returncode}): {" ".join(cmd)}\n{tail}')


def unit_name(module):
    return re.sub(r'[^A-Za-z0-9]', '_', os.path.splitext(module)[0])


def top_llasm(srw_top, code_map, out):
    """SRW's top file minus the data segments: the runtime maps the real guest image."""
    lines, skip, names = [], False, []
    for line in open(srw_top):
        s = line.strip()
        if s.startswith('datasegment'):
            skip = True
        if not skip and not s.startswith('dlabel'):
            lines.append(line)
        if s == 'endd':
            skip = False
    with open(out, 'w') as f:
        f.writelines(lines)
    return names


def code_map_from(work, out):
    """Every procedure of every code segment (a module can have several)."""
    n = hooked = 0
    with open(out, 'w') as f:
        for seg in sorted(x for x in os.listdir(work) if re.fullmatch(r'seg\d+_code\.llinc', x)):
            for line in open(os.path.join(work, seg)):
                if line.startswith('proc loc_'):
                    name = line.split()[1]
                    f.write(f'{name},{name[4:]}\n')
                    n += 1
                elif line.startswith('proc hooked_'):
                    # helper procedures of a hooked function (tools/hooks.py): need a table entry, but no guest address
                    # is ever looked up for it, so it gets a synthetic one outside every module
                    f.write(f'{line.split()[1]},{0xD0000000 + 16 * hooked:X}\n')
                    hooked += 1
    return n


def translate_module(root, out, module):
    d = os.path.join(root, os.path.splitext(module)[0])
    w = os.path.join(out, unit_name(module))
    os.makedirs(w, exist_ok=True)
    for sci in ('global_aliases.sci', 'noret_procedures.sci'):
        shutil.copy(os.path.join(d, sci), w)
    pe = os.path.join(d, module + '.bound.pe')
    flags = ['--fixed-guest-image'] + (['--no-sse'] if module.lower() in NO_SSE else [])
    run([SRW] + flags + [pe, 'unit.srw.llasm'], w, os.path.join(w, 'srw.log'))
    top_llasm(os.path.join(w, 'unit.srw.llasm'), None, os.path.join(w, 'unit.llasm'))
    if module.lower() == 'gameclient.dll':                     # game controller support (see hooks.py)
        import hooks
        hooks.apply(w, pe, os.path.join(out, 'hooks.txt'))
    procs = code_map_from(w, os.path.join(w, 'code-map.csv'))
    compile_unit(w, unit_name(module), REUSE_IR)
    untranslated = sum(1 for l in open(os.path.join(w, 'srw.log')) if 'untranslated' in l)
    return module, procs, untranslated


# Memory safety: clang -O2 needs about 80 bytes of memory per byte of IR (131 MB of IR peaked at 10.4 GB), so modules are
# split into ~12 MB parts (about 1 GB each) and at most two parts are compiled at a time.
PART_BYTES = 12 * 1024 * 1024
# Each ~12 MB part needs about 1 GB to compile, so allow one job per 4 GB of RAM (and never more than the CPU count).
def _compile_jobs():
    ram_gb = os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') / 2**30
    return max(2, min(os.cpu_count() or 2, int(ram_gb // 4)))
COMPILE_JOBS = _compile_jobs()


def compile_unit(w, unit, reuse_ir=False):
    if not (reuse_ir and os.path.exists(os.path.join(w, 'unit.ll'))):
        run([LLASM, '-m64', '-ptrofs', '-O', '-guest-code-map', 'code-map.csv', '-guest-unit', unit,
             '-I', SUPPORT, '-I', RUNTIME_LLINC, '-o', 'unit.ll', 'unit.llasm'], w, os.path.join(w, 'llasm.log'))
    parts = max(1, -(-os.path.getsize(os.path.join(w, 'unit.ll')) // PART_BYTES))
    split = os.path.join(w, 'split')
    shutil.rmtree(split, ignore_errors=True)
    os.makedirs(split)
    if parts == 1:
        inputs = [os.path.join(w, 'unit.ll')]
    else:
        import splitir                                  # our own splitter: Apple's toolchain has no llvm-split
        inputs = splitir.split(os.path.join(w, 'unit.ll'), parts, os.path.join(split, 'part'))

    objdir = os.path.join(w, 'obj')
    shutil.rmtree(objdir, ignore_errors=True)
    os.makedirs(objdir)

    def one(src):
        base = os.path.join(objdir, os.path.basename(src))
        log = base + '.log'
        run([os.path.join(LLVM_BIN, 'opt'), '-O2', f'-mtriple={TARGET}', f'--data-layout={DATA_LAYOUT}', src, '-o', base + '.bc'], w, log)
        run([os.path.join(LLVM_BIN, 'llc'), '-O2', f'-mtriple={TARGET}', '-filetype=obj', base + '.bc', '-o', base + '.o'], w, log)
        os.remove(base + '.bc')
        return os.path.relpath(base + '.o', w)
    with cf.ThreadPoolExecutor(max_workers=COMPILE_JOBS) as ex:
        objs = list(ex.map(one, inputs))
    with open(os.path.join(w, 'unit.objs'), 'w') as f:        # the final link reads this list (Apple-free lld has no partial link)
        f.write('\n'.join(objs) + '\n')


def translate_imports(root, out):
    imports = json.load(open(os.path.join(root, 'imports.json')))
    w = os.path.join(out, 'imports')
    os.makedirs(w, exist_ok=True)
    with open(os.path.join(w, 'unit.llasm'), 'w') as f, open(os.path.join(w, 'code-map.csv'), 'w') as m:
        f.write('include llasm.llinc\ninclude extern.llinc\ninclude macros.llinc\n\n')
        for r in imports:
            name = f"imp_{r['address']:08X}"
            # The handler pops the stdcall frame and returns the guest return address.
            f.write(f"proc {name}\ncall gp_import $, {r['index']}\ntcall tmp0\nendp\n\n")
            m.write(f"{name},{r['address']:08X}\n")
        # Spare thunks for native functions the game looks up at run time
        # (GetProcAddress on a system DLL); the runtime assigns them on demand.
        for k in range(DYN_THUNKS):
            addr = DYN_THUNK_BASE + 8 * k
            f.write(f"proc imp_{addr:08X}\ncall gp_import $, {DYN_INDEX_BASE + k}\ntcall tmp0\nendp\n\n")
            m.write(f"imp_{addr:08X},{addr:08X}\n")
    compile_unit(w, 'imports', False)
    return len(imports)


REUSE_IR = False


def main():
    global REUSE_IR
    args = sys.argv[1:]
    if '--reuse-ir' in args:
        args.remove('--reuse-ir')
        REUSE_IR = True
    root, out = os.path.abspath(args[0]), os.path.abspath(args[1])
    manifest = json.load(open(os.path.join(root, 'manifest.json')))
    only = args[2:]
    mods = [m for m in manifest if not only or m in only]
    os.makedirs(out, exist_ok=True)
    print('imports: thunks', translate_imports(root, out), flush=True)
    # One module at a time; parallelism lives only inside the capped compile step.
    for m in mods:
        module, procs, untranslated = translate_module(root, out, m)
        print(f'{module:22} procs {procs:7} untranslated-traps {untranslated}', flush=True)


if __name__ == '__main__':
    main()
