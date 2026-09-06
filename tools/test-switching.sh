#!/bin/bash
# Drives a full verification cycle: reinstall, launch, skip tracks, then check that the DAC
# ended on the rate the player last reported.
#
# The check is about the settled outcome, not each intermediate read: skipping faster than
# the player reports leaves transient mismatches that are expected, while the rate you are
# left listening at must never be wrong.
#
#   tools/test-switching.sh [skips] [seconds between skips]
set -uo pipefail
cd "$(dirname "$0")/.."

SKIPS=${1:-8}
GAP=${2:-1.2}
APP="/Applications/BitPerfect DX.app"
BIN="$APP/Contents/MacOS/BitPerfectDX"
sleep_for() { python3 -c "import time,sys; time.sleep(float(sys.argv[1]))" "$1"; }

pkill -f "BitPerfect DX.app" 2>/dev/null
for _ in $(seq 1 25); do pgrep -f "BitPerfect DX.app" >/dev/null || break; sleep_for 0.2; done

./build.sh --install >/dev/null || { echo "build failed"; exit 1; }
MARK=$(date "+%Y-%m-%d %H:%M:%S")

open "$APP"
sleep_for 4

echo "skipping $SKIPS tracks, $GAP s apart"
for _ in $(seq 1 "$SKIPS"); do
    osascript -e 'tell application id "com.apple.Music" to next track' >/dev/null 2>&1
    sleep_for "$GAP"
done

echo "settling"
sleep_for 8

# Only fair once the player has gone quiet: it keeps reporting while preparing the next
# track, and taking its last line regardless compares the DAC against a track that is not
# playing — which produced a false failure before this check existed.
last_report() {
    /usr/bin/log show --start "$MARK" --info --style compact \
        --predicate 'process == "Music" AND eventMessage CONTAINS "ReportAudioPlaybackThroughFig"' 2>/dev/null \
        | grep -oE "SampleRate [0-9]+" | tail -1
}

FIRST=$(last_report)
sleep_for 3
SECOND=$(last_report)

TRACK=$(osascript -e 'tell application id "com.apple.Music" to get name of current track' 2>/dev/null)
ACTUAL=$("$BIN" --list-devices | grep -A2 "DX3 Pro+" | grep "now:" | grep -oE "[0-9.]+ kHz" | head -1)
EXPECTED=$(echo "$SECOND" | grep -oE "[0-9]+")

echo
echo "track:            ${TRACK:-?}"
echo "player reported:  ${EXPECTED:-?} Hz"
echo "DAC ended at:     ${ACTUAL:-?}"
echo

if [ "$FIRST" != "$SECOND" ]; then
    echo "RESULT: INCONCLUSIVE — the player was still reporting during the measurement"
    exit 2
fi

echo "$EXPECTED ${ACTUAL%% *}" | awk '{
    want = $1 / 1000; got = $2 + 0
    diff = want - got; if (diff < 0) diff = -diff
    print (want > 0 && got > 0 && diff < 0.05) ? "RESULT: PASS" : "RESULT: FAIL"
    exit (want > 0 && got > 0 && diff < 0.05) ? 0 : 1
}'
