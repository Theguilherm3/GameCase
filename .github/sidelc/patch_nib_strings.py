#!/usr/bin/env python3
"""Patch display strings inside compiled storyboard nibs (NIBArchive).

Display values are stored as: 0x08, length byte (0x80 + byte-length),
then the UTF-8 bytes. We only rewrite occurrences anchored by that
exact prefix whose full byte sequence matches a known storyboard
display text, so identifiers/class names (stored differently) are
never touched. Usage: patch_nib_strings.py <SideStoreApp.framework> <map.json>
"""
import json, sys, os, glob, collections

def patch(data, items):
    out = bytearray(); i = 0; n = len(data); hits = collections.Counter()
    while i < n:
        matched = False
        if i >= 2 and data[i - 2] == 0x08:
            for en_b, zh_b in items:
                if len(en_b) < 128 and data[i - 1] == 0x80 + len(en_b) and data[i:i + len(en_b)] == en_b:
                    out[-1] = 0x80 + len(zh_b)
                    out += zh_b; i += len(en_b); hits[en_b] += 1; matched = True; break
        if not matched:
            out.append(data[i]); i += 1
    return bytes(out), hits

def main():
    fw, map_path = sys.argv[1], sys.argv[2]
    mapping = json.load(open(map_path))
    items = sorted(((e.encode(), z.encode()) for e, z in mapping.items() if e != z and len(z.encode()) < 128),
                   key=lambda kv: -len(kv[0]))
    total = collections.Counter(); files = 0
    for nib in glob.glob(os.path.join(fw, '*.storyboardc', '*.nib')):
        data = open(nib, 'rb').read()
        if not data.startswith(b'NIBArchive'): continue
        new, hits = patch(data, items)
        if hits:
            open(nib, 'wb').write(new); files += 1; total.update(hits)
    print(f'nib patch: {files} files, {sum(total.values())} occurrences, {len(total)} texts')

if __name__ == '__main__':
    main()
