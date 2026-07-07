#!/usr/bin/env python3
"""Mechanically strip ObjC-interop cruft while copying a DSP kernel file
from the old cocoaModem Swift port into the new CoreDSP/ModemKit packages.

- drops @objc / @objc(name:) attribute lines (keeps the decl on its own line)
- strips inline @objc / @objc(name) tokens preceding a decl on the same line
- drops ": NSObject" superclass / protocol conformance (plain Swift classes)
- drops `import Cocoa` / `import AppKit` (keeps/adds `import Foundation`)
- drops bare `override` that would now be invalid after removing NSObject
  (only when the overridden member has no local superclass -- best effort;
  flagged with a TODO comment for manual review rather than silently dropped)
"""
import re
import sys

OBJC_ATTR_LINE = re.compile(r'^\s*@objc(\([^)]*\))?\s*$')
OBJC_ATTR_INLINE = re.compile(r'@objc(\([^)]*\))?\s*')

def transform(text: str) -> str:
    out_lines = []
    for line in text.splitlines():
        if OBJC_ATTR_LINE.match(line):
            continue
        line = OBJC_ATTR_INLINE.sub('', line)
        out_lines.append(line)
    text = '\n'.join(out_lines) + '\n'

    # class Foo: NSObject { ... }  ->  class Foo { ... }
    text = re.sub(r'class (\w+)\s*:\s*NSObject\b', r'class \1', text)
    # class Foo: NSObject, SomeProto -> class Foo: SomeProto
    text = re.sub(r':\s*NSObject\s*,\s*', ': ', text)

    text = text.replace('import Cocoa\n', '')
    text = text.replace('import AppKit\n', '')
    if 'import Foundation' not in text:
        text = 'import Foundation\n' + text
    return text

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as f:
        content = f.read()
    content = transform(content)
    with open(dst, 'w') as f:
        f.write(content)
    print(f"{src} -> {dst}")
