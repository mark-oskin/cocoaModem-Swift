#!/usr/bin/env python3
"""Analyze the Obj-C class hierarchy and emit a leaves-first conversion order.

A class is safe to convert to Swift only once ALL its Obj-C subclasses are
already Swift (Obj-C cannot subclass a Swift class).  So we convert in reverse
topological order: leaves (no Obj-C subclasses) first.
"""
import os
import re
import sys

ROOT = "/Users/oskin/Desktop/cm/Sources"
SWIFT_ROOT = "/Users/oskin/Desktop/cm/Sources/Swift"

iface = re.compile(r"@interface\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)")

# class -> superclass, class -> defining .m path (if it has one still in ObjC)
supers = {}
mfile = {}
hfile = {}

# already-converted Swift classes
swift_classes = set()
for dirpath, _, files in os.walk(SWIFT_ROOT):
    for f in files:
        if f.endswith(".swift"):
            swift_classes.add(f[:-6])

for dirpath, _, files in os.walk(ROOT):
    if "/Swift" in dirpath:
        continue
    for f in files:
        if not f.endswith(".h"):
            continue
        p = os.path.join(dirpath, f)
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception:
            continue
        for m in iface.finditer(text):
            cls, sup = m.group(1), m.group(2)
            supers[cls] = sup
            hfile[cls] = p
            mp = p[:-2] + ".m"
            if os.path.exists(mp):
                mfile[cls] = mp

project_classes = set(supers) - swift_classes
# children map among project (still-ObjC) classes
children = {c: [] for c in project_classes}
for c in project_classes:
    s = supers[c]
    if s in children:
        children[s].append(c)

# leaves = project classes with no still-ObjC subclass
def obj_subclasses(c):
    return [k for k in children.get(c, [])]

order = []
remaining = set(project_classes)
while remaining:
    leaves = [c for c in remaining if not any(k in remaining for k in children[c])]
    if not leaves:
        # cycle (shouldn't happen); dump the rest
        leaves = list(remaining)
    order.extend(sorted(leaves))
    remaining -= set(leaves)

if len(sys.argv) > 1 and sys.argv[1] == "leaves":
    # print current leaves (subclasses all Swift or none), with file + module
    for c in sorted(project_classes):
        if not any(k in project_classes for k in children[c]):
            mp = mfile.get(c, "(no .m)")
            mod = mp.split("/Sources/")[-1].split("/")[0] if "/Sources/" in mp else "?"
            print(f"{mod}\t{c}\t{supers[c]}\t{mp}")
else:
    # full order with wave numbers by depth
    for i, c in enumerate(order):
        mp = mfile.get(c, "")
        print(f"{c}\t:{supers[c]}\t{mp}")
    print(f"\n# {len(order)} project classes remaining; {len(swift_classes)} already Swift", file=sys.stderr)
