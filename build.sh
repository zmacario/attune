#!/bin/bash
# Builds BitPerfect DX.app from source. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/BitPerfect DX.app"
BIN="$APP/Contents/MacOS/BitPerfectDX"

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

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Snapshot.applescript "$APP/Contents/Resources/"

# How the app is signed decides whether it keeps its permissions across rebuilds.
#
# Ad-hoc (`--sign -`) produces a designated requirement of `cdhash H"..."` — the hash of
# the binary itself — so every rebuild is a new identity to macOS and the Media & Apple
# Music prompt comes back. A self-signed certificate anchors the requirement to the
# certificate instead, and rebuilds keep what you granted. See README → Permissões.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(BitPerfect DX Local\)"/\1/p' | head -1)}"

if [ -n "$IDENTITY" ]; then
    echo "Signing as: $IDENTITY"
else
    IDENTITY="-"
    echo "Signing ad-hoc — permissions will be re-requested after every rebuild."
    echo "Run ./tools/create-signing-identity.sh once to stop that."
fi

codesign --force --sign "$IDENTITY" --identifier com.macario.bitperfectdx "$APP"

echo "Built $APP"

# With a copy in /Applications and another here, it is far too easy to rebuild and then
# keep running the old one. `./build.sh --install` replaces the installed copy.
if [ "${1:-}" = "--install" ]; then
    if pgrep -f "BitPerfect DX.app" >/dev/null; then
        echo "Quit BitPerfect DX first (menu bar → Quit), then run this again." >&2
        exit 1
    fi
    rm -rf "/Applications/BitPerfect DX.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/BitPerfect DX.app"
fi
