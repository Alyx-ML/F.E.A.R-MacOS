#!/usr/bin/env python3
"""gaps.py <analysis.pe> <work dir>: classify code-section bytes not covered by recovered instructions."""
import json, os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import recover
im = recover.Image(sys.argv[1])
d = json.load(open(os.path.join(sys.argv[2], 'recover.json')))
extra = []
insns, roots, tables, dic, problems, _ = recover.recover(im, extra, {int(x, 16) for x in d['noret']})
cov = bytearray(max(b for a, b in im.code) - im.base)
for va, (size, _) in insns.items():
    cov[va - im.base:va - im.base + size] = b'\1' * size
for va in dic:
    if va in im.relocs: cov[va - im.base:va - im.base + 4] = b'\2' * 4
kinds = collections.Counter(); samples = collections.defaultdict(list)
for a, b in im.code:
    va = a
    while va < b:
        if cov[va - im.base]: va += 1; continue
        s = va
        while va < b and not cov[va - im.base]: va += 1
        g = bytes(im.img[s - im.base:va - im.base])
        if all(c in (0xcc, 0x90) for c in g): k = 'padding'
        elif all(c == 0 for c in g): k = 'zeros'
        elif any(x in im.relocs for x in range(s, va)): k = 'has-reloc'
        elif g[:3] in (b'\x55\x8b\xec', b'\x83\xec') or g[:1] in (b'\x56', b'\x53', b'\x57', b'\x51', b'\x6a', b'\x8b', b'\x83', b'\x81', b'\xa1', b'\xb8', b'\x33', b'\xd9', b'\xe9', b'\xc3', b'\xc2'): k = 'code-like'
        else: k = 'other'
        kinds[k] += va - s; samples[k].append((s, va - s))
for k, n in kinds.most_common():
    print(f'{k:10} {n:8} bytes in {len(samples[k])} gaps; e.g. ' + ' '.join(f'{s:#x}+{l}' for s, l in sorted(samples[k], key=lambda x: -x[1])[:6]))
