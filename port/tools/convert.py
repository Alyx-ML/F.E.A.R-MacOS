#!/usr/bin/env python3
"""First-launch converter: the player's game files -> a cache the runtime can load.

usage: convert.py <game dir> <cache dir>          convert (resumable), then write the cache manifest
       convert.py --check <game dir> <cache dir>  exit 0 when the cache matches this game and this converter
       convert.py --identity <game dir>           print the game identity string
       convert.py --supported <game dir>          exit 0 when the folder holds the supported version of the game

Pipeline: prepare (pin, extract, rebase) -> recover (per module) -> bind imports -> translate (SRW -> LLasm ->
LLVM IR -> ARM64 object per module) -> link one guest.dylib. Nothing here executes guest code.
Progress is printed as "PROGRESS <0..1> <message>" lines. Uses the LLVM tools in ROOT/toolchain (nothing from Xcode is needed).
"""
import hashlib, json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                     # port/ in the repository, Resources/converter in the app
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, 'pydeps'))
sys.path.insert(0, os.path.join(ROOT, '.pydeps'))

LLVM = os.path.join(ROOT, 'toolchain', 'llvm')
LLD = os.path.join(LLVM, 'bin', 'ld64.lld')
LIBSYSTEM_STUB = os.path.join(HERE, 'stub')       # our own empty libSystem.tbd: the link needs the load command, not the symbols
TARGET = 'arm64-apple-macos26'
# files whose identity decides whether a cache is still valid (the archive holds GameClient/GameServer/ClientFx)
IDENTITY_FILES = ['FEAR.exe', 'EngineServer.dll', 'GameDatabase.dll', 'StringEditRuntime.dll', 'LTMemory.dll',
                  'SndDrv.dll', 'msvcr71.dll', 'msvcp71.dll', 'binkw32.dll']
IDENTITY_SIZED = ['FEARE_8.Arch00']


def progress(fraction, text):
    print(f'PROGRESS {min(max(fraction, 0.0), 1.0):.4f} {text}', flush=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def game_identity(game):
    h = hashlib.sha256()
    for name in IDENTITY_FILES:
        p = os.path.join(game, name)
        if not os.path.isfile(p):
            raise SystemExit(f'{game}: {name} not found; choose the F.E.A.R. game folder')
        h.update(f'{name}:{sha256_file(p)}\n'.encode())
    for name in IDENTITY_SIZED:
        p = os.path.join(game, name)
        if not os.path.isfile(p):
            raise SystemExit(f'{game}: {name} not found; choose the F.E.A.R. game folder')
        h.update(f'{name}:{os.path.getsize(p)}\n'.encode())
    return h.hexdigest()


def converter_id():
    """Changes whenever any converter input changes, so an old cache is never reused with new tools."""
    h = hashlib.sha256()
    inputs = []
    for base in (os.path.join(ROOT, 'tools'), os.path.join(ROOT, 'runtime', 'llasm'),
                 os.path.join(ROOT, 'third_party', 'SR', 'SR', 'llasm-support')):
        for dp, _, files in sorted(os.walk(base)):
            for f in sorted(files):
                if f.endswith(('.py', '.json', '.llinc', '.h')) and '__pycache__' not in dp:
                    inputs.append(os.path.join(dp, f))
    inputs += [os.path.join(ROOT, 'build', 'srw', 'srw'), os.path.join(ROOT, 'build', 'llasm')]
    inputs += [os.path.join(LLVM, 'bin', t) for t in ('opt', 'llc', 'ld64.lld')] + [os.path.join(HERE, 'stub', 'libSystem.tbd')]
    for p in inputs:
        if not os.path.isfile(p):
            raise SystemExit(f'converter file missing: {p}')
        h.update(f'{os.path.relpath(p, ROOT)}:{sha256_file(p)}\n'.encode())
    return h.hexdigest()


def supported(game):
    """Cheap check for the launcher's folder search: the files exist and FEAR.exe is the exact version we convert."""
    pins = json.load(open(os.path.join(HERE, 'module_hashes.json')))
    exe = os.path.join(game, 'FEAR.exe')
    if not all(os.path.isfile(os.path.join(game, n)) for n in IDENTITY_FILES + IDENTITY_SIZED):
        return False
    return sha256_file(exe) == pins['FEAR.exe']


def manifest_path(cache):
    return os.path.join(cache, 'manifest.json')


def cache_valid(game, cache):
    try:
        m = json.load(open(manifest_path(cache)))
    except (OSError, ValueError):
        return False
    return (m.get('converter') == converter_id() and m.get('game') == game_identity(game)
            and os.path.isfile(os.path.join(cache, 'guest.dylib')))


def run(cmd, log, cwd=None, env=None):
    with open(log, 'w') as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, env=env)
    if r.returncode:
        tail = open(log, errors='replace').read()[-2500:]
        raise SystemExit(f'{os.path.basename(cmd[1]) if len(cmd) > 1 else cmd[0]} failed ({r.returncode}); log {log}\n{tail}')


def check_tools():
    for rel in ('toolchain/llvm/bin/opt', 'toolchain/llvm/bin/llc', 'toolchain/llvm/bin/ld64.lld', 'build/srw/srw', 'build/llasm'):
        if not os.access(os.path.join(ROOT, rel), os.X_OK):
            raise SystemExit(f'converter tool {rel} is missing or not executable; the app is incomplete')
    for tool in ('opt', 'llc'):
        r = subprocess.run([os.path.join(LLVM, 'bin', tool), '--version'], capture_output=True)
        if r.returncode:
            raise SystemExit(f'the bundled {tool} does not run: {r.stderr.decode(errors="replace")[-500:]}')


def convert(game, cache):
    game, cache = os.path.abspath(game), os.path.abspath(cache)
    check_tools()
    ident = game_identity(game)
    cid = converter_id()
    os.makedirs(cache, exist_ok=True)
    try:
        os.remove(manifest_path(cache))                    # a partial conversion must never look valid
    except FileNotFoundError:
        pass
    work = os.path.join(cache, 'work')
    modules = os.path.join(work, 'modules')
    units = os.path.join(work, 'units')
    stamp = os.path.join(work, 'inputs.json')
    if os.path.exists(stamp) and json.load(open(stamp)) != {'converter': cid, 'game': ident}:
        shutil.rmtree(work)                                # partial work from other inputs
    os.makedirs(modules, exist_ok=True)
    os.makedirs(units, exist_ok=True)
    json.dump({'converter': cid, 'game': ident}, open(stamp, 'w'))
    env = dict(os.environ, PYTHONPATH=os.pathsep.join([HERE, os.path.join(ROOT, 'pydeps'), os.path.join(ROOT, '.pydeps')]))
    py = sys.executable

    progress(0.00, 'Checking the game files')
    if not os.path.exists(os.path.join(modules, 'manifest.json')):
        run([py, os.path.join(HERE, 'prepare.py'), game, modules], os.path.join(work, 'prepare.log'), env=env)
    manifest = json.load(open(os.path.join(modules, 'manifest.json')))
    names = sorted(manifest, key=lambda n: manifest[n]['size'])

    progress(0.02, 'Analysing the game code')
    for i, name in enumerate(names):
        d = os.path.join(modules, os.path.splitext(name)[0])
        if not os.path.exists(os.path.join(d, 'recover.json')):
            run([py, os.path.join(HERE, 'recover.py'), os.path.join(d, name + '.analysis.pe'), d],
                os.path.join(d, 'recover.log'), env=env)
        progress(0.02 + 0.08 * (i + 1) / len(names), f'Analysing the game code ({name})')
    if not os.path.exists(os.path.join(modules, 'imports.json')):
        run([py, os.path.join(HERE, 'bind_imports.py'), modules], os.path.join(work, 'bind.log'), env=env)

    # translate.py reads its tool locations from the environment at import time
    os.environ['GP_LLVM'] = LLVM
    os.environ['GP_TOOLS'] = os.path.join(ROOT, 'build')
    import translate
    translate.TARGET = TARGET
    total = sum(manifest[n]['size'] for n in names)
    done = 0
    progress(0.10, 'Preparing the system call layer')
    if not os.path.exists(os.path.join(units, 'imports', 'unit.objs')):
        translate.translate_imports(modules, units)
    for name in names:
        w = os.path.join(units, translate.unit_name(name))
        share = 0.85 * manifest[name]['size'] / total
        if os.path.exists(os.path.join(w, '.done')):
            done += manifest[name]['size']
            continue
        progress(0.10 + 0.85 * done / total, f'Converting {name} (this happens once)')
        shutil.rmtree(w, ignore_errors=True)
        translate.translate_module(modules, units, name)
        for junk in ('unit.ll', 'unit.llasm', 'unit.srw.llasm', 'split') + tuple(f for f in os.listdir(w) if f.endswith('.llinc')):
            p = os.path.join(w, junk)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else (os.path.exists(p) and os.remove(p))
        open(os.path.join(w, '.done'), 'w').close()
        done += manifest[name]['size']
        progress(0.10 + 0.85 * done / total, f'Converted {name}')

    progress(0.95, 'Linking')
    objs = []
    for u in sorted(os.listdir(units)):
        lst = os.path.join(units, u, 'unit.objs')
        if os.path.exists(lst):
            objs += [os.path.join(units, u, o) for o in open(lst).read().split()]
    tmp = os.path.join(cache, 'guest.dylib.tmp')
    run([LLD, '-arch', 'arm64', '-platform_version', 'macos', '26.0', '26.0', '-dylib', '-undefined', 'dynamic_lookup',
         '-L', LIBSYSTEM_STUB, '-lSystem', '-o', tmp] + objs, os.path.join(work, 'link.log'))
    os.replace(tmp, os.path.join(cache, 'guest.dylib'))
    for f in ('modules.txt', 'imports.txt'):
        shutil.copy(os.path.join(modules, f), os.path.join(cache, f))
    shutil.copy(os.path.join(units, 'hooks.txt'), os.path.join(cache, 'hooks.txt'))
    images = os.path.join(cache, 'images')
    shutil.rmtree(images, ignore_errors=True)
    os.makedirs(images)
    for name in names:
        d = os.path.join(modules, os.path.splitext(name)[0])
        shutil.copy(os.path.join(d, name + '.bound.pe'), images)
    shutil.rmtree(work)                                     # intermediates are not needed to run
    json.dump({'converter': cid, 'game': ident, 'created': time.time(), 'modules': names}, open(manifest_path(cache), 'w'), indent=1)
    progress(1.0, 'Done')


def main():
    args = sys.argv[1:]
    if args[:1] == ['--identity'] and len(args) == 2:
        print(game_identity(args[1]))
    elif args[:1] == ['--supported'] and len(args) == 2:
        sys.exit(0 if supported(args[1]) else 1)
    elif args[:1] == ['--check'] and len(args) == 3:
        sys.exit(0 if cache_valid(args[1], args[2]) else 1)
    elif len(args) == 2 and not args[0].startswith('--'):
        convert(args[0], args[1])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
