#!/usr/bin/env python3
"""Extracts localizable literals from Sources/ and (re)generates the .strings files.
Fails if a key has no French translation."""
import glob, os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from strings_fr import FR

STRING_VARS = {"groupName", "item.name", "watcher.names", "name", "names[0]"}
pat = re.compile(r'(?:\bText|\bButton|\bLabel|\bToggle|\bSection|\bTextField|\bLabeledContent|\.help|LocalizedStringKey|String\(localized:)\s*\(?\s*"((?:[^"\\]|\\.|\\\([^)]*\))*)"')
keys = set()
for f in glob.glob(os.path.join(ROOT, "Sources", "*.swift")):
    src = open(f, encoding="utf-8").read()
    for m in pat.finditer(src):
        # skip Text(verbatim:)
        if src[max(0, m.start()-1):m.end()].find("verbatim") != -1:
            continue
        raw = m.group(1)
        key = re.sub(r'\\\(([^)]*)\)', lambda mm: "%@" if mm.group(1).strip() in STRING_VARS else "%lld", raw)
        keys.add(key)
keys.discard("Stack")
missing = sorted(k for k in keys if k not in FR)
unused = sorted(k for k in FR if k not in keys)
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"')
with open(os.path.join(ROOT, "Resources/fr.lproj/Localizable.strings"), "w", encoding="utf-8") as fh:
    fh.write("/* Stack — French */\n")
    for k in sorted(FR):
        fh.write(f'"{esc(k)}" = "{esc(FR[k])}";\n')
with open(os.path.join(ROOT, "Resources/en.lproj/Localizable.strings"), "w", encoding="utf-8") as fh:
    fh.write("/* Stack — English (keys are English) */\n")
    for k in sorted(FR):
        fh.write(f'"{esc(k)}" = "{esc(k)}";\n')
print(f"{len(keys)} keys found, {len(FR)} translations")
if unused: print("UNUSED:", *unused, sep="\n  ")
if missing:
    print("MISSING:", *missing, sep="\n  "); sys.exit(1)
print("OK")
