#!/bin/bash
# Builds Attune.app from source. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Attune.app"
BIN="$APP/Contents/MacOS/Attune"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement \
    -o "$BIN" \
    Sources/*.swift

# Compile-check the AppleScript before shipping it. Terminology collisions (a variable
# named `st`, say) only show up here — at runtime they are just a silent failure.
osacompile -o /dev/null Resources/Snapshot.applescript

# A missing translation is not a crash — NSLocalizedString hands back the key — so the
# app would quietly show "menu.quit" in its menu. Catch it here instead.
python3 tools/check-localization.py

# Regenerate the icon only when its source changed; rendering it compiles a second binary.
if [ ! -f Resources/AppIcon.icns ] || [ tools/make-icon.swift -nt Resources/AppIcon.icns ]; then
    ./tools/make-icon.sh
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Snapshot.applescript "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# How the app is signed decides whether it keeps its permissions across rebuilds.
#
# Ad-hoc (`--sign -`) produces a designated requirement of `cdhash H"..."` — the hash of
# the binary itself — so every rebuild is a new identity to macOS and the Media & Apple
# Music prompt comes back. A self-signed certificate anchors the requirement to the
# certificate instead, and rebuilds keep what you granted. See README → Permissões.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Attune Local\)"/\1/p' | head -1)}"

if [ -n "$IDENTITY" ]; then
    echo "Signing as: $IDENTITY"
else
    IDENTITY="-"
    echo "Signing ad-hoc — permissions will be re-requested after every rebuild."
    echo "Run ./tools/create-signing-identity.sh once to stop that."
fi

codesign --force --sign "$IDENTITY" --identifier com.macario.attune "$APP"

echo "Built $APP"

# With a copy in /Applications and another here, it is far too easy to rebuild and then
# keep running the old one. `./build.sh --install` replaces the installed copy.
if [ "${1:-}" = "--install" ]; then
    if pgrep -f "Attune.app" >/dev/null; then
        echo "Quit Attune first (menu bar → Quit), then run this again." >&2
        exit 1
    fi
    rm -rf "/Applications/Attune.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Attune.app"
fi
