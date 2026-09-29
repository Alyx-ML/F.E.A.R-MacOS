#!/usr/bin/env python3
"""Static code recovery for one rebased analysis PE (never executes guest code).

Recursive descent with capstone from: entry point, exports, relocated pointers
stored outside code (vtables, callback tables), relocated immediates that point
into code (callbacks passed to Win32/CRT), and MSVC switch jump tables.

Writes into <work dir>:
  global_aliases.sci   code roots for SRW fixed-guest-image mode
  noret_procedures.sci procedures that never return
  recover.json         roots, jump tables, noreturn set, problems

usage: recover.py <analysis.pe> <work dir> [extra roots file]
"""
import json, os, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.pydeps'))
import pefile  # noqa: E402
import capstone  # noqa: E402
from capstone import x86 as X  # noqa: E402

# Imports that never return (by DLL-independent name).
NORET_IMPORTS = {
    'ExitProcess', 'ExitThread', 'FatalAppExitA', 'RaiseException', 'TerminateProcess_noret',
    'exit', '_exit', 'abort', '_amsg_exit', '_CxxThrowException', '?terminate@@YAXXZ',
    '__security_error_handler', '_invalid_parameter_noinfo', 'longjmp', '_longjmp',
}
MAX_TABLE = 4096
problems_dead = {}  # switch slots whose target is data (reported, not seeded)


class Image:
    def __init__(self, path):
        self.pe = pefile.PE(path)
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.img = self.pe.get_memory_mapped_image()
        self.code = [(self.base + s.VirtualAddress, self.base + s.VirtualAddress + s.Misc_VirtualSize)
                     for s in self.pe.sections if s.Characteristics & 0x20000000]
        self.relocs = set()
        for b in getattr(self.pe, 'DIRECTORY_ENTRY_BASERELOC', []):
            for e in b.entries:
                if e.type == 3:
                    self.relocs.add(self.base + e.rva)
        self.imports = {}
        for d in getattr(self.pe, 'DIRECTORY_ENTRY_IMPORT', []):
            for i in d.imports:
                name = i.name.decode() if i.name else f'#{i.ordinal}'
                self.imports[i.address] = (d.dll.decode(), name)

    def in_code(self, va):
        return any(a <= va < b for a, b in self.code)

    def dword(self, va):
        return struct.unpack_from('<I', self.img, va - self.base)[0]


def recover(im, extra_roots=(), noret=frozenset()):
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = True
    insns = {}          # va -> (size, mnemonic)
    owner = {}          # byte va -> insn start (overlap detection)
    data_in_code = {}   # va -> reason
    roots, tables, problems = {}, {}, []
    dead_cases = {}
    callers = {}        # callee -> list of call-site fallthrough addresses (for noreturn fixups)

    def add_root(va, why):
        if im.in_code(va) and va not in roots:
            roots[va] = why
            work.append(va)

    ep = im.base + im.pe.OPTIONAL_HEADER.AddressOfEntryPoint
    work = []
    if im.pe.OPTIONAL_HEADER.AddressOfEntryPoint:
        add_root(ep, 'entry')
    for s in getattr(getattr(im.pe, 'DIRECTORY_ENTRY_EXPORT', None), 'symbols', []):
        if s.forwarder is None:
            add_root(im.base + s.address, 'export:' + (s.name.decode() if s.name else f'#{s.ordinal}'))
    for site in sorted(im.relocs):
        if not im.in_code(site):
            t = im.dword(site)
            if im.in_code(t):
                add_root(t, f'dataptr@{site:#x}')
    for va in extra_roots:
        add_root(va, 'extra')

    def mem_disp_site(ins, op):
        """True when the relocation of this instruction is the displacement of op."""
        return op.type == X.X86_OP_MEM and op.mem.disp != 0

    while work:
        va = work.pop()
        origin = va
        while True:
            if va in insns:
                break
            if not im.in_code(va):
                problems.append(f'flow leaves code at {va:#x}')
                break
            if va in data_in_code:
                if va == origin and roots.get(va, '').startswith('case@'):
                    dead_cases[va] = roots.pop(va)  # unused switch slot pointing at a table
                else:
                    problems.append(f'flow into data-in-code at {va:#x} ({data_in_code[va]}) from {origin:#x}')
                break
            off = va - im.base
            try:
                ins = next(md.disasm(bytes(im.img[off:off + 16]), va, 1))
            except StopIteration:
                problems.append(f'invalid instruction at {va:#x}')
                break
            for b in range(va, va + ins.size):
                if b in owner and owner[b] != va:
                    problems.append(f'overlap: insn {va:#x} overlaps insn {owner[b]:#x}')
                    break
                owner[b] = va
            insns[va] = (ins.size, ins.mnemonic)
            nxt = va + ins.size
            ops = ins.operands
            relsite = [s for s in range(va, nxt) if s in im.relocs]
            # relocated immediates pointing into code are callbacks/code pointers
            for op in ops:
                if op.type == X.X86_OP_IMM and relsite and im.in_code(op.imm & 0xffffffff) \
                        and ins.mnemonic not in ('call', 'jmp') and not ins.mnemonic.startswith('j'):
                    add_root(op.imm & 0xffffffff, f'imm@{va:#x}')
            m = ins.mnemonic
            if m in ('ret', 'retf', 'iretd', 'hlt', 'ud2', 'int3'):
                break
            if m == 'jmp':
                op = ops[0]
                if op.type == X.X86_OP_IMM:
                    work.append(op.imm & 0xffffffff)
                elif op.type == X.X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0 \
                        and (op.mem.disp & 0xffffffff) in im.imports:
                    pass  # import thunk
                elif op.type == X.X86_OP_MEM and op.mem.index != 0 and op.mem.scale == 4 \
                        and op.mem.base == 0 and im.in_code(op.mem.disp & 0xffffffff):
                    t0 = op.mem.disp & 0xffffffff
                    ents = []
                    a = t0
                    # index may start at 1..3 (hand-written CRT asm leaves slot 0 as padding)
                    for skip in range(4):
                        if t0 + 4 * skip in im.relocs:
                            a = t0 + 4 * skip
                            break
                    while len(ents) < MAX_TABLE and a in im.relocs and im.in_code(im.dword(a)):
                        ents.append(im.dword(a))
                        data_in_code[a] = f'jumptable@{va:#x}'
                        a += 4
                    a = t0 - 4
                    if t0 - 4 in im.relocs:
                        # hand-written CRT asm (memcpy) may index with a negative
                        # register: entries can precede the displacement. The sign
                        # is not known statically, so seed both readings; each
                        # entry is a relocated pointer into code either way.
                        while len(ents) < MAX_TABLE and a in im.relocs and im.in_code(im.dword(a)):
                            ents.append(im.dword(a))
                            data_in_code[a] = f'jumptable@{va:#x}'
                            a -= 4
                    if not ents:
                        problems.append(f'unresolved jump table at {va:#x} -> {t0:#x}')
                    tables[va] = {'table': t0, 'targets': ents}
                    for t in ents:
                        add_root(t, f'case@{va:#x}')
                else:
                    pass  # indirect jump through register/memory: resolved at run time
                break
            if m.startswith('j') or m.startswith('loop') or m == 'jecxz':
                op = ops[0]
                if op.type == X.X86_OP_IMM:
                    work.append(op.imm & 0xffffffff)
                va = nxt
                continue
            if m == 'call':
                op = ops[0]
                if op.type == X.X86_OP_IMM:
                    t = op.imm & 0xffffffff
                    add_root(t, 'call')
                    callers.setdefault(t, []).append(nxt)
                    if t in noret:
                        break
                elif op.type == X.X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0 \
                        and (op.mem.disp & 0xffffffff) in im.imports:
                    if im.imports[op.mem.disp & 0xffffffff][1] in NORET_IMPORTS:
                        break
                va = nxt
                continue
            va = nxt
    for va in list(roots):
        if va in data_in_code:  # became a table after being queued
            dead_cases[va] = roots.pop(va)
    if dead_cases:
        problems_dead.update(dead_cases)
    return insns, roots, tables, data_in_code, problems, callers


def find_noret(im, insns, roots):
    """A procedure is noreturn when no path from its entry reaches a ret.
    Evaluated with a fixed point over direct calls; import thunks by name."""
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = True
    noret = set()
    # import thunks: jmp [IAT]
    for va, (size, m) in insns.items():
        if m == 'jmp' and size == 6:
            ins = next(md.disasm(bytes(im.img[va - im.base:va - im.base + 6]), va, 1))
            d = ins.operands[0].mem.disp & 0xffffffff if ins.operands[0].type == X.X86_OP_MEM else None
            if d in im.imports and im.imports[d][1] in NORET_IMPORTS:
                noret.add(va)
    changed = True
    while changed:
        changed = False
        for r in roots:
            if r in noret:
                continue
            seen, stack, returns = set(), [r], False
            while stack and not returns:
                va = stack.pop()
                while va in insns and va not in seen:
                    seen.add(va)
                    size, m = insns[va]
                    ins = next(md.disasm(bytes(im.img[va - im.base:va - im.base + size]), va, 1))
                    if m in ('ret', 'retf'):
                        returns = True
                        break
                    if m in ('hlt', 'ud2', 'int3'):
                        break
                    op = ins.operands[0] if ins.operands else None
                    if m == 'jmp':
                        if op.type == X.X86_OP_IMM:
                            t = op.imm & 0xffffffff
                            if t in noret:
                                break
                            if t in roots and t != r:
                                returns = True  # tail call into another procedure: assume it returns
                                break
                            va = t
                            continue
                        if op.type == X.X86_OP_MEM and (op.mem.disp & 0xffffffff) in im.imports:
                            if im.imports[op.mem.disp & 0xffffffff][1] not in NORET_IMPORTS:
                                returns = True
                            break
                        returns = True  # jump table / indirect: assume some case returns
                        break
                    if m.startswith('j') or m.startswith('loop'):
                        if op.type == X.X86_OP_IMM:
                            stack.append(op.imm & 0xffffffff)
                        va += size
                        continue
                    if m == 'call' and op is not None:
                        if op.type == X.X86_OP_IMM and (op.imm & 0xffffffff) in noret:
                            break
                        if op.type == X.X86_OP_MEM and (op.mem.disp & 0xffffffff) in im.imports \
                                and im.imports[op.mem.disp & 0xffffffff][1] in NORET_IMPORTS:
                            break
                    va += size
                if va not in insns and va not in seen:
                    returns = True  # flow into unknown code: be conservative
            if not returns:
                noret.add(r)
                changed = True
    return noret


def main():
    pe_path, work_dir = sys.argv[1], sys.argv[2]
    extra = []
    if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
        extra = [int(l.split()[0], 16) for l in open(sys.argv[3]) if l.strip() and not l.startswith('#')]
    im = Image(pe_path)
    insns, roots, tables, dic, problems, callers = recover(im, extra)
    noret = find_noret(im, insns, roots)
    # Second pass: stop descent after calls to procedures found noreturn so the
    # bytes after such calls are not decoded as code. Repeat until stable.
    while True:
        insns, roots, tables, dic, problems, callers = recover(im, extra, noret)
        again = find_noret(im, insns, roots)
        # A relocated pointer stored in code outside every decoded instruction is
        # a jump-table entry (including tables indexed from an unknown base); its
        # target is code. Seed those and repeat until nothing new appears.
        covered = set()
        for va, (size, _) in insns.items():
            covered.update(range(va, va + size))
        table_targets = {im.dword(s) for s in im.relocs
                         if im.in_code(s) and s not in covered and im.in_code(im.dword(s))
                         and im.dword(s) not in dic}
        new_roots = [x for x in table_targets if x not in roots and x not in extra]
        if again == noret and not new_roots:
            break
        noret = again
        extra = list(extra) + new_roots
    os.makedirs(work_dir, exist_ok=True)
    with open(os.path.join(work_dir, 'global_aliases.sci'), 'w') as f:
        for va in sorted(roots):
            f.write(f'loc_{va:X},loc_{va:X}\n')
    with open(os.path.join(work_dir, 'noret_procedures.sci'), 'w') as f:
        for va in sorted(noret):
            f.write(f'loc_{va:X}\n')
    code_bytes = sum(s for s, _ in insns.values())
    total = sum(b - a for a, b in im.code)
    json.dump({'roots': {f'{k:#x}': v for k, v in sorted(roots.items())},
               'jump_tables': {f'{k:#x}': {'table': f"{v['table']:#x}", 'targets': [f'{t:#x}' for t in v['targets']]}
                               for k, v in tables.items()},
               'noret': [f'{v:#x}' for v in sorted(noret)],
               'problems': problems,
               'dead_switch_slots': {f'{k:#x}': v for k, v in problems_dead.items()},
               'stats': {'instructions': len(insns), 'code_bytes': code_bytes, 'code_section_bytes': total}},
              open(os.path.join(work_dir, 'recover.json'), 'w'), indent=1)
    print(f'{os.path.basename(pe_path)}: roots {len(roots)} insns {len(insns)} '
          f'coverage {code_bytes}/{total} ({100 * code_bytes / total:.1f}%) tables {len(tables)} '
          f'noret {len(noret)} problems {len(problems)}')


if __name__ == '__main__':
    main()
