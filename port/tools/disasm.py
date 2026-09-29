#!/usr/bin/env python3
"""dis.py <pe> <va_hex> [count]: disassemble from a VA using udcli (never executes code)."""
import sys, os, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '.pydeps'))
import pefile
pe = pefile.PE(sys.argv[1], fast_load=True)
va = int(sys.argv[2], 16); n = int(sys.argv[3]) if len(sys.argv) > 3 else 40
data = pe.get_data(va - pe.OPTIONAL_HEADER.ImageBase, n * 15)
udcli = os.path.join(os.path.dirname(__file__), '..', 'build', 'udcli')
out = subprocess.run([udcli, '-32', '-intel', '-noff', '-o', hex(va)], input=data, capture_output=True).stdout.decode()
print('\n'.join(out.splitlines()[:n]))
