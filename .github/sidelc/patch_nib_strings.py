#!/usr/bin/env python3
"""Structured zh-Hans patcher for compiled storyboard nibs (NIBArchive v2).

Walks the archive properly (header / objects / keys / values / class
names; varint = 7-bit groups, last byte has the high bit set; type 8 =
DATA whose payload may be a UTF-8 display string or a nested archive).

Safety rule: a string that is ALSO referenced as a resource name
(UIImageNibPlaceholder.UIResourceName - e.g. a tab icon asset literally
named "News") is never renamed in place. Instead the NSString object
is split: display references (UITitle, attributed strings) are
retargeted to a cloned object holding the translation, while resource
references keep pointing at the original English payload.
Usage: patch_nib_strings.py <SideStoreApp.framework> <map.json>
"""
import json, sys, os, glob, struct, collections

FIXED = {0: 1, 1: 2, 2: 4, 3: 8, 4: 0, 5: 0, 6: 4, 7: 8, 9: 0, 10: 4}
DATA, OBJREF = 8, 10
RESOURCE_KEY = 'UIResourceName'
IMAGE_CLASSES = {'UIImageNibPlaceholder', 'UIImage'}

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

class Val:
    __slots__ = ('key', 'type', 'payload', 'raw')
    def __init__(self, key, type_, payload, raw):
        self.key, self.type, self.payload, self.raw = key, type_, payload, raw
    def encode(self):
        if self.raw is not None: return self.raw
        if self.type == DATA:
            return write_varint(self.key) + bytes([DATA]) + write_varint(len(self.payload)) + self.payload
        if self.type == OBJREF:
            return write_varint(self.key) + bytes([OBJREF]) + struct.pack('<i', self.payload)
        raise ValueError('cannot encode')

def parse_archive(data):
    assert data[:10] == b'NIBArchive'
    f = struct.unpack('<10I', data[10:50])
    hdr = {'obj_count': f[2], 'off_obj': f[3], 'key_count': f[4], 'off_keys': f[5],
           'val_count': f[6], 'off_vals': f[7], 'cls_count': f[8], 'off_cls': f[9]}
    i = hdr['off_obj']; objects = []
    for _ in range(hdr['obj_count']):
        cni, i = read_varint(data, i); vi, i = read_varint(data, i); vc, i = read_varint(data, i)
        objects.append([cni, vi, vc])
    keys_raw = data[hdr['off_keys']:hdr['off_vals']]
    i = hdr['off_keys']; keys = []
    for _ in range(hdr['key_count']):
        ln, i = read_varint(data, i); keys.append(data[i:i + ln].decode('utf-8')); i += ln
    i = hdr['off_vals']; values = []
    for _ in range(hdr['val_count']):
        start = i
        key, i = read_varint(data, i); vtype = data[i]; i += 1
        if vtype in FIXED:
            payload = struct.unpack('<i', data[i:i + 4])[0] if vtype == OBJREF else None
            i += FIXED[vtype]
            values.append(Val(key, vtype, payload, data[start:i]))
        elif vtype == DATA:
            ln, i = read_varint(data, i)
            values.append(Val(key, vtype, data[i:i + ln], None)); i += ln
        else:
            raise ValueError(f'unknown value type {vtype}')
    assert i == hdr['off_cls']
    # class names (names only; raw section preserved)
    i = hdr['off_cls']; classes = []
    for _ in range(hdr['cls_count']):
        ln, i = read_varint(data, i); extras, i = read_varint(data, i)
        i += 4 * extras
        classes.append(data[i:i + ln - 1].decode('utf-8')); i += ln
    return hdr, objects, keys, keys_raw, values, classes, data[hdr['off_cls']:]

def patch_archive(data, mapping, hits):
    hdr, objects, keys, keys_raw, values, classes, classes_raw = parse_archive(data)
    def keyname(v): return keys[v.key] if v.key < len(keys) else '?'
    # NSString objects: obj index -> (value index, payload)
    ns_strings = {}
    for oi, (cni, vi, vc) in enumerate(objects):
        if classes[cni] == 'NSString' and vc >= 1:
            v = values[vi]
            if v.type == DATA and keyname(v) == 'NS.bytes':
                ns_strings[oi] = (vi, v.payload)
    # references: target obj -> [(referrer obj, key name, value index)]
    refs = collections.defaultdict(list)
    for oi, (cni, vi, vc) in enumerate(objects):
        for k in range(vc):
            v = values[vi + k]
            if v.type == OBJREF:
                refs[v.payload].append((oi, keyname(v), vi + k))
    changed = False
    # nested archives first (direct DATA payloads)
    for oi, (cni, vi, vc) in enumerate(objects):
        for k in range(vc):
            v = values[vi + k]
            if v.type == DATA and v.payload[:10] == b'NIBArchive':
                newp = patch_archive(v.payload, mapping, hits)
                if newp != v.payload: v.payload = newp; v.raw = None; changed = True
    for oi, (vi, payload) in list(ns_strings.items()):
        if payload not in mapping: continue
        zh = mapping[payload]
        ref_list = refs.get(oi, [])
        ref_keys = {k for (_, k, _) in ref_list}
        if RESOURCE_KEY in ref_keys:
            display = [(o, k, vidx) for (o, k, vidx) in ref_list if k != RESOURCE_KEY]
            if not display: continue
            # split: clone object with translated payload
            new_val_idx = len(values)
            values.append(Val(values[vi].key, DATA, zh, None))
            new_obj_idx = len(objects)
            objects.append([objects[oi][0], new_val_idx, 1])
            for (_, _, vidx) in display:
                values[vidx].payload = new_obj_idx; values[vidx].raw = None
            hits[payload] += 1; changed = True
        else:
            values[vi].payload = zh; values[vi].raw = None
            hits[payload] += 1; changed = True
    # direct DATA payloads (not NSString NS.bytes)
    ns_value_idxs = {vi for (vi, _) in ns_strings.values()}
    for oi, (cni, vi, vc) in enumerate(objects):
        if classes[cni] in IMAGE_CLASSES: continue
        for k in range(vc):
            vidx = vi + k; v = values[vidx]
            if vidx in ns_value_idxs or v.type != DATA: continue
            if keyname(v) == RESOURCE_KEY: continue
            if v.payload[:10] == b'NIBArchive': continue
            if v.payload in mapping:
                en = v.payload
                v.payload = mapping[en]; v.raw = None
                hits[en] += 1
                changed = True
    if not changed:
        return data
    obj_bytes = b''.join(write_varint(c) + write_varint(vi) + write_varint(vc) for (c, vi, vc) in objects)
    val_bytes = b''.join(v.encode() for v in values)
    off_keys = 50 + len(obj_bytes)
    off_vals = off_keys + len(keys_raw)
    off_cls = off_vals + len(val_bytes)
    fields = list(struct.unpack('<10I', data[10:50]))
    fields[2] = len(objects); fields[3] = 50
    fields[5] = off_keys; fields[6] = len(values); fields[7] = off_vals; fields[9] = off_cls
    hdr_out = data[:10] + struct.pack('<10I', *fields)
    return bytes(hdr_out) + obj_bytes + keys_raw + val_bytes + classes_raw

def main():
    fw, map_path = sys.argv[1], sys.argv[2]
    raw = json.load(open(map_path))
    mapping = {e.encode(): z.encode() for e, z in raw.items() if e != z}
    hits = collections.Counter(); files = 0
    for nib in glob.glob(os.path.join(fw, '*.storyboardc', '*.nib')):
        data = open(nib, 'rb').read()
        if not data.startswith(b'NIBArchive'): continue
        new = patch_archive(data, mapping, hits)
        if new != data:
            open(nib, 'wb').write(new); files += 1
    print(f'nib patch: {files} files, {sum(hits.values())} title/string hits')

if __name__ == '__main__':
    main()
