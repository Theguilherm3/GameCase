#!/usr/bin/env python3
"""Structured zh-Hans patcher for compiled storyboard nibs (NIBArchive).

Walks the archive's value table with the real format semantics
(varint = 7-bit groups, last byte has the high bit set; type 8 = DATA,
whose payload may be a UTF-8 display string or a nested NIBArchive).
Only DATA payloads that exactly equal a known storyboard display text
are replaced; nested archives are patched recursively. The header's
class-names offset is adjusted by the values-region size delta.
Usage: patch_nib_strings.py <SideStoreApp.framework> <map.json>
"""
import json, sys, os, glob, struct, collections

FIXED = {0: 1, 1: 2, 2: 4, 3: 8, 4: 0, 5: 0, 6: 4, 7: 8, 9: 0, 10: 4}
DATA = 8

def read_varint(buf, i):
    result = 0; shift = 0
    while True:
        b = buf[i]; i += 1
        result |= (b & 0x7F) << shift; shift += 7
        if b & 0x80: return result, i

def write_varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: out.append(b)
        else: out.append(b | 0x80); return bytes(out)

def patch_archive(data, mapping, hits):
    assert data[:10] == b'NIBArchive'
    f = struct.unpack('<10I', data[10:50])
    (obj_count, off_obj, key_count, off_keys, val_count, off_vals,
     cls_count, off_cls) = f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9]
    i = off_vals; out = bytearray()
    for _ in range(val_count):
        start = i
        _, i = read_varint(data, i)          # key index
        vtype = data[i]; i += 1
        if vtype in FIXED:
            i += FIXED[vtype]
            out += data[start:i]
        elif vtype == DATA:
            len_start = i
            length, i = read_varint(data, i)
            payload = data[i:i + length]; i += length
            if payload[:10] == b'NIBArchive':
                payload = patch_archive(payload, mapping, hits)
                out += data[start:len_start] + write_varint(len(payload)) + payload
            elif payload in mapping:
                zh = mapping[payload]; hits[payload] += 1
                out += data[start:len_start] + write_varint(len(zh)) + zh
            else:
                out += data[start:i]
        else:
            raise ValueError(f'unknown value type {vtype}')
    assert i == off_cls, f'values walk ended at {i}, expected {off_cls}'
    delta = len(out) - (off_cls - off_vals)
    hdr = bytearray(data[:50])
    struct.pack_into('<I', hdr, 46, off_cls + delta)
    return bytes(hdr) + data[50:off_vals] + bytes(out) + data[off_cls:]

def main():
    fw, map_path = sys.argv[1], sys.argv[2]
    raw = json.load(open(map_path))
    mapping = {e.encode(): z.encode() for e, z in raw.items() if e != z}
    hits = collections.Counter(); files = 0
    for nib in glob.glob(os.path.join(fw, '*.storyboardc', '*.nib')):
        data = open(nib, 'rb').read()
        if not data.startswith(b'NIBArchive'): continue
        before = sum(hits.values())
        new = patch_archive(data, mapping, hits)
        if sum(hits.values()) > before:
            open(nib, 'wb').write(new); files += 1
    print(f'nib patch: {files} files, {sum(hits.values())} occurrences, {len(hits)} texts')

if __name__ == '__main__':
    main()
