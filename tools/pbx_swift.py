#!/usr/bin/env python3
"""Add Swift files to (and remove replaced .m files from) the cocoaModem pbxproj.

Usage:
  pbx_swift.py add  <path-relative-to-repo-root>...   # e.g. Sources/Swift/Application/UTC.swift
  pbx_swift.py remove-m <basename.m>...               # stop compiling an Obj-C file
"""
import hashlib
import re
import sys

PBXPROJ = "/Users/oskin/Desktop/cm/cocoaModem 2.0/cocoaModem 2.0.xcodeproj/project.pbxproj"
MAIN_GROUP = "29B97314FDCFA39411CA2CEA"
SWIFT_GROUP_ID = "AAAA00000000000000000001"


def uid(key):
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def load():
    with open(PBXPROJ) as f:
        return f.read()


def save(text):
    with open(PBXPROJ, "w") as f:
        f.write(text)


def ensure_swift_group(text):
    if SWIFT_GROUP_ID in text:
        return text
    group = (
        "\t\t%s /* Swift */ = {\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        "\t\t\t);\n"
        "\t\t\tname = Swift;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n" % SWIFT_GROUP_ID
    )
    text = text.replace("/* Begin PBXGroup section */\n",
                        "/* Begin PBXGroup section */\n" + group, 1)
    # add to main group children
    pat = re.compile(r"(%s /\* [^*]* \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)" % MAIN_GROUP)
    text = pat.sub(lambda m: m.group(1) + "\t\t\t\t%s /* Swift */,\n" % SWIFT_GROUP_ID, text, 1)
    return text


def add_files(paths):
    text = ensure_swift_group(load())
    for rel in paths:
        name = rel.split("/")[-1]
        fid = uid("fileref:" + rel)
        bid = uid("buildfile:" + rel)
        if fid in text:
            print("already added:", rel)
            continue
        text = text.replace(
            "/* Begin PBXBuildFile section */\n",
            "/* Begin PBXBuildFile section */\n"
            "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n"
            % (bid, name, fid, name), 1)
        text = text.replace(
            "/* Begin PBXFileReference section */\n",
            "/* Begin PBXFileReference section */\n"
            "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            "name = \"%s\"; path = \"../%s\"; sourceTree = SOURCE_ROOT; };\n"
            % (fid, name, name, rel), 1)
        # group children
        text = text.replace(
            "%s /* Swift */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n" % SWIFT_GROUP_ID,
            "%s /* Swift */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
            "\t\t\t\t%s /* %s */,\n" % (SWIFT_GROUP_ID, fid, name), 1)
        # sources build phase: insert after the phase's "files = (" line
        pat = re.compile(r"(isa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)")
        text = pat.sub(lambda m: m.group(1) + "\t\t\t\t%s /* %s in Sources */,\n" % (bid, name), text, 1)
        print("added:", rel)
    save(text)


def remove_m(names):
    text = load()
    for name in names:
        pat = re.compile(r"^.*/\* %s in Sources \*/.*\n" % re.escape(name), re.M)
        text, n = pat.subn("", text)
        print("removed %s (%d entries)" % (name, n))
    save(text)


def purge(names):
    """Remove every pbxproj line referencing <name>.h or <name>.m (file refs,
    build files, group children, Sources/CopyFiles/Resources phase entries)."""
    text = load()
    alt = "|".join(re.escape(n) for n in names)
    pat = re.compile(r".*/\* (" + alt + r")\.[hm]( in (Sources|CopyFiles|Resources))? \*/.*\n")
    text2, n = pat.subn("", text)
    save(text2)
    print("purged %d ref lines for %d classes" % (n, len(names)))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "add":
        add_files(sys.argv[2:])
    elif cmd == "remove-m":
        remove_m(sys.argv[2:])
    elif cmd == "purge":
        purge(sys.argv[2:])
    else:
        sys.exit("unknown command")
