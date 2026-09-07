#!/bin/bash
# Feeds the .movpkg parser everything it should survive.
#
# It is the only hand-written binary reader in the app, and the only place where a defect
# becomes a crash rather than a wrong sample rate: a truncated or half-written download is
# an ordinary thing for Music to leave on disk, and the app must answer "I don't know"
# rather than fall over.
#
# Two rounds. First every real package in the library, which must all still resolve — the
# fix for a crash is worthless if it costs a correct answer. Then a corpus of damaged
# inputs, each run in its own process, because only a separate process can tell a crash
# from a nil.
#
# It found two real crashes on its first run: a mdhd box declaring size 8 carries no
# payload, and the version byte was read without a bounds check; and a 64-bit box size
# above Int.max trapped on conversion rather than being rejected.
set -uo pipefail
cd "$(dirname "$0")/.."

LIBRARY="${1:-$HOME/Music/Music/Media.localized}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
// One answer per process. Exits 0 for any answer including nil; the failure this exists to
// catch is the process not coming back at all.
let path = CommandLine.arguments[1]
var isDirectory: ObjCBool = false
FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
let variant = isDirectory.boolValue
    ? Movpkg.preferredVariant(at: path)
    : Movpkg.parse(initSegment: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data(), bitrate: 1)
print(variant.map { "\($0.codec) \($0.sampleRate)" } ?? "nil")
SWIFT

swiftc -O -o "$WORK/probe" "$WORK/main.swift" \
    Sources/Movpkg.swift Sources/Log.swift Sources/AudioDevice.swift Sources/Localization.swift

# Runs one case, reporting crash or hang rather than letting either stop the sweep.
# macOS has no `timeout`, so the wait is done by hand.
run_case() {
    "$WORK/probe" "$1" >/dev/null 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
        perl -e 'select(undef,undef,undef,0.1)'
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; return 2; fi
    wait "$pid"
}

echo "== real packages under $LIBRARY"
real=0 lost=0
while IFS= read -r package; do
    if output=$("$WORK/probe" "$package" 2>/dev/null) && [ "$output" != "nil" ]; then
        real=$((real + 1))
    else
        lost=$((lost + 1))
        echo "   no answer: $(basename "$package")"
    fi
done < <(find "$LIBRARY" -name "*.movpkg" 2>/dev/null)
echo "   $real resolved, $lost without an answer"

seed="$(find "$LIBRARY" -name "*.initfrag" 2>/dev/null | head -1)"
mkdir -p "$WORK/damaged"
python3 tools/make-damaged-movpkg.py "$WORK/damaged" "$seed"

echo "== damaged inputs"
crashes=0 hangs=0
for case_file in "$WORK/damaged"/*.bin; do
    run_case "$case_file"
    case $? in
        0) ;;
        2) hangs=$((hangs + 1));   echo "   HUNG:  $(basename "$case_file")" ;;
        *) crashes=$((crashes + 1)); echo "   CRASH: $(basename "$case_file")" ;;
    esac
done
total=$(ls "$WORK/damaged" | wc -l | tr -d ' ')
echo "   $total cases, $crashes crashed, $hangs hung"

[ "$lost" -eq 0 ] && [ "$crashes" -eq 0 ] && [ "$hangs" -eq 0 ] \
    && { echo "movpkg parser ok"; exit 0; } \
    || { echo "movpkg parser FAILED" >&2; exit 1; }
