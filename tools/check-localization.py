#!/usr/bin/env python3
"""Fails the build when a localized() key is missing from any language.

A missing key is not a crash: NSLocalizedString falls back to returning the key
itself, so the app would quietly show "menu.quit" in the menu. This catches that
before it ships.
"""
import pathlib, re, sys

SOURCES = pathlib.Path("Sources")
RESOURCES = pathlib.Path("Resources")

used = set()
for swift in SOURCES.glob("*.swift"):
    for call in re.findall(r"localized\(([^)]*)", swift.read_text(encoding="utf-8")):
        used.update(re.findall(r'"([a-z][A-Za-z]*\.[A-Za-z.]+)"', call))

tables = {}
for lproj in sorted(RESOURCES.glob("*.lproj")):
    strings = lproj / "Localizable.strings"
    if not strings.exists():
        continue
    text = strings.read_text(encoding="utf-8")
    tables[lproj.name] = set(re.findall(r'^"([^"]+)"\s*=', text, re.M))

if not tables:
    sys.exit("No .lproj tables found under Resources/")

failed = False
for lang, keys in tables.items():
    missing = sorted(used - keys)
    if missing:
        failed = True
        print(f"{lang}: {len(missing)} missing key(s)", file=sys.stderr)
        for key in missing:
            print(f"    {key}", file=sys.stderr)
    unused = sorted(keys - used)
    if unused:
        print(f"{lang}: {len(unused)} unused key(s): {', '.join(unused)}")

print(f"localization: {len(used)} keys used, {len(tables)} language(s) — {'FAIL' if failed else 'ok'}")
sys.exit(1 if failed else 0)
