#!/usr/bin/env python3
"""List instruction mnemonics (udis86 names) in recovered code of each module, with counts."""
import sys, os, json, collections, ctypes
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import recover
tot = collections.Counter(); where = {}
for d in sorted(os.listdir('work/modules')):
    p = os.path.join('work/modules', d)
    if not os.path.isdir(p): continue
    pe = [f for f in os.listdir(p) if f.endswith('.analysis.pe')][0]
    im = recover.Image(os.path.join(p, pe))
    j = json.load(open(os.path.join(p, 'recover.json')))
    insns = recover.recover(im, (), {int(x, 16) for x in j['noret']})[0]
    for va, (size, m) in insns.items():
        tot[m] += 1; where.setdefault(m, (d, va))
json.dump({m: [n, where[m][0], hex(where[m][1])] for m, n in tot.items()}, open('work/mnemonics.json', 'w'), indent=0)
print(len(tot))
