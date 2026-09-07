#!/usr/bin/env python3
"""Fails the build on a missing key, or on format specifiers that do not match.

A missing key is not a crash: NSLocalizedString falls back to returning the key
itself, so the app would quietly show "menu.quit" in the menu.

A dropped specifier is worse. `String(format:)` reads its arguments positionally
from the translated string, so a "%ld" lost in translation makes it read an
argument that was never passed. This catches both before they ship.

A literal percent sign is the same trap wearing a disguise: "100% gesetzt" reads
as the specifier "% g", so a percentage followed by a word is flagged here even
though the key takes no arguments today. Put it at the end of the sentence, or
write "%%".
"""
import pathlib, re, subprocess, sys

SOURCES = pathlib.Path("Sources")
RESOURCES = pathlib.Path("Resources")

used = set()
for swift in SOURCES.glob("*.swift"):
    for call in re.findall(r"localized\(([^)]*)", swift.read_text(encoding="utf-8")):
        used.update(re.findall(r'"([a-z][A-Za-z]*\.[A-Za-z.]+)"', call))

tables, entries = {}, {}
for lproj in sorted(RESOURCES.glob("*.lproj")):
    strings = lproj / "Localizable.strings"
    if not strings.exists():
        continue
    text = strings.read_text(encoding="utf-8")
    tables[lproj.name] = set(re.findall(r'^"([^"]+)"\s*=', text, re.M))
    entries[lproj.name] = dict(re.findall(r'^\s*"(.+?)"\s*=\s*"(.*?)";\s*$', text, re.M))

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

# English is the reference: it is the one the code was written against, and the one
# macOS falls back to.
SPECIFIER = re.compile(r"%(?:\d+\$)?[-#0 +\']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|j|t)?[@dioufFeEgGxXscpaA%]")

def specifiers(text):
    return [s for s in SPECIFIER.findall(text) if s != "%%"]

reference = entries.get("en.lproj", {})
for lang, table in sorted(entries.items()):
    if lang == "en.lproj":
        continue
    for key, english in reference.items():
        if key not in table:
            continue
        want, got = specifiers(english), specifiers(table[key])
        if want != got:
            failed = True
            print(f"{lang}: {key} has {got or 'no specifiers'}, English has {want or 'none'}",
                  file=sys.stderr)

# A syntax error in a .strings file is not a missing key: the whole table fails to load,
# and every key in that language shows up in the menu as its own name.
for strings in sorted(RESOURCES.glob("*.lproj/*.strings")):
    result = subprocess.run(["plutil", "-lint", str(strings)], capture_output=True, text=True)
    if result.returncode != 0:
        failed = True
        print(f"{strings}: {result.stdout.strip() or result.stderr.strip()}", file=sys.stderr)

print(f"localization: {len(used)} keys used, {len(tables)} language(s) — {'FAIL' if failed else 'ok'}")
sys.exit(1 if failed else 0)
