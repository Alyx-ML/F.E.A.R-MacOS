#!/usr/bin/env python3
"""Engine hooks for the game controller, applied while a module is converted.

F.E.A.R. has no controller support of its own. The community patch EchoPatch (github.com/Wemino/EchoPatch) adds it
by hooking GameClient.dll's command functions; it finds them by byte signatures. This tool does the same job at
conversion time: it finds the functions in the player's GameClient.dll with those signatures and inserts a native hook
at the start of the two functions that report input, so the runtime can supply controller input. It also writes the
addresses of the game's OnCommandOn/OnCommandOff and the game-shell pointer for the runtime.

Nothing here executes guest code. A signature that does not match exactly once stops the conversion loudly.
"""
import os, re, struct, sys

# EchoPatch src/Client/ClientPatch.cpp signatures (game version 1.08)
SIG_SHELL = 'C1 F8 02 C1 E0 05 2B C2 8B CB BA 01 00 00 00 D3 E2 8B CD 03 C3 50 85 11'
SIG_EXTREMAL = '83 EC 08 56 57 8B F9 8B 77 04 3B 77 08 C7 44 24 08 00 00 00 00'
SIG_IS_COMMAND_ON = '8B D1 8A 42 4C 84 C0 56 74 58'
SIG_USE_CURSOR = '8A 44 24 04 84 C0 56 8B F1 88 46 01 74'


def scan(image, base, name, sig):
    pat = b''.join(re.escape(bytes.fromhex(t)) if t != '??' else b'.' for t in sig.split())
    hits = [m.start() for m in re.finditer(pat, image, re.S)]
    if len(hits) != 1:
        raise SystemExit(f'controller hooks: signature for {name} matched {len(hits)} times (expected 1); '
                         f'this GameClient.dll is not the supported version')
    return base + hits[0], hits[0]


def locate(pe_path):
    """Addresses the hooks and the runtime need, from the rebased analysis/bound image."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'pydeps'))
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '.pydeps'))
    import pefile
    pe = pefile.PE(pe_path)
    base = pe.OPTIONAL_HEADER.ImageBase
    image = pe.get_memory_mapped_image()
    shell, off = scan(image, base, 'pGameClientShell', SIG_SHELL)
    rel = lambda o: struct.unpack_from('<i', image, off + o)[0]
    return {
        'IsCommandOn': scan(image, base, 'IsCommandOn', SIG_IS_COMMAND_ON)[0],
        'GetExtremalCommandValue': scan(image, base, 'GetExtremalCommandValue', SIG_EXTREMAL)[0],
        'UseCursor': scan(image, base, 'UseCursor', SIG_USE_CURSOR)[0],
        'OnCommandOn': (shell + rel(0x21) + 0x25) & 0xffffffff,
        'OnCommandOff': (shell + rel(0x28) + 0x2c) & 0xffffffff,
        'ShellVariable': struct.unpack_from('<I', image, off + 0x1a)[0],      # global that holds the shell pointer
    }


# Hook preludes in LLasm. Both functions are thiscall with the command id at [esp+4] and end in "ret 4".
# A hook returns non-zero when it supplied the result; otherwise the original body runs.
# (llasm wants a conditional tail call to be followed directly by a tail call, hence the three procedures.)
IS_COMMAND_ON = '''\
;controller hook: a command held by the game controller
add tmpadr, esp, 4
load tmp2, tmpadr, 1
call tc_hook_is_command_on $, tmp2
ctcallnz tmp0, hooked_done_{addr:08X}
tcall hooked_orig_{addr:08X}
endp

proc hooked_done_{addr:08X}
and eax, eax, 0xffffff00
or eax, eax, 1
POP tmp1
add esp, esp, 4
tcall tmp1
endp

proc hooked_orig_{addr:08X}
'''
EXTREMAL = '''\
;controller hook: analog stick value for a command (the helper pushes it on the x87 stack)
add tmpadr, esp, 4
load tmp2, tmpadr, 1
call tc_hook_extremal_value $, tmp2
ctcallnz tmp0, hooked_done_{addr:08X}
tcall hooked_orig_{addr:08X}
endp

proc hooked_done_{addr:08X}
POP tmp1
add esp, esp, 4
tcall tmp1
endp

proc hooked_orig_{addr:08X}
'''


# Observer: UseCursor(show, lock) is called whenever the game shows or hides its mouse cursor (menu vs gameplay).
# The hook only reports the flag and the original function then runs unchanged.
USE_CURSOR = '''\
;controller hook: the game shows or hides its cursor
add tmpadr, esp, 4
load8z tmp2, tmpadr, 1
call tc_hook_note_cursor $, tmp2
'''


def apply(work_dir, pe_path, hooks_out):
    """Insert the hooks into the module's code segments and write the addresses for the runtime."""
    a = locate(pe_path)
    targets = {a['IsCommandOn']: IS_COMMAND_ON, a['GetExtremalCommandValue']: EXTREMAL, a['UseCursor']: USE_CURSOR}
    done = set()
    for seg in sorted(f for f in os.listdir(work_dir) if re.fullmatch(r'seg\d+_code\.llinc', f)):
        path = os.path.join(work_dir, seg)
        text = open(path).read()
        for addr, template in targets.items():
            m = re.search(rf'^proc loc_{addr:08X} global [^\n]*\n', text, re.M)
            if not m:
                continue
            text = text[:m.end()] + template.format(addr=addr) + text[m.end():]
            done.add(addr)
        open(path, 'w').write(text)
    if done != set(targets):
        raise SystemExit(f'controller hooks: functions {[hex(x) for x in set(targets) - done]} were not found in the converted code')
    with open(hooks_out, 'w') as f:
        for k in ('OnCommandOn', 'OnCommandOff', 'ShellVariable'):
            f.write(f'{k} {a[k]:08x}\n')
    return a


if __name__ == '__main__':
    for k, v in locate(sys.argv[1]).items():
        print(f'{k} {v:08x}')
