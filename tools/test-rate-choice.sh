#!/bin/bash
# Which rate the device is put on when it cannot match the track's own.
#
# The rule exists because the fallback used to be "leave the device where it was", which left
# a 192 kHz track playing into 88.2 kHz — the rate the previous track happened to leave behind
# — rather than the 96 kHz that stands in an exact 2:1 ratio to it. Every case below is a shape
# that rule has to get right, and the first one is the one that prompted it.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    ok ? (passed += 1) : (failed += 1)
}

// Observed rates as CoreAudio reports them: the built-in output tops out at 96 kHz.
let builtIn: [Double] = [44100, 48000, 88200, 96000]
let full: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]

func chosen(_ track: Double, _ supported: [Double]) -> Double? {
    AudioDevice.bestRate(for: track, supported: supported)
}

// MARK: the case that prompted the rule

check("the exact rate is taken when the device has it", chosen(48000, builtIn) == 48000)
check("192 onto 44.1/48/88.2/96 is 96, not 88.2", chosen(192000, builtIn) == 96000,
      chosen(192000, builtIn).map { rateLabel($0) } ?? "nil")

// MARK: whole-number ratios, in both directions

check("a divisor is accepted: 88.2 onto 44.1", chosen(88200, [44100, 48000]) == 44100)
check("a multiple is accepted: 44.1 onto 88.2", chosen(44100, [176400]) == 176400)
check("96 onto 48", chosen(96000, [44100, 48000]) == 48000)
check("192 onto 48", chosen(192000, [44100, 48000]) == 48000)

// MARK: no whole-number ratio: the device's own maximum

check("44.1 onto 48/96 has no ratio, so the maximum", chosen(44100, [48000, 96000]) == 96000)
check("192 onto 44.1/88.2 has no ratio, so 88.2", chosen(192000, [44100, 88200]) == 88200)

// MARK: shape of the input

check("unsorted input", chosen(192000, [96000, 44100, 88200, 48000]) == 96000)
check("zero rates are ignored", chosen(192000, [0, 96000, 0]) == 96000)
check("a single rate is always it", chosen(44100, [48000]) == 48000)
check("no rates at all", chosen(44100, []) == nil)
check("an unknown track rate falls to the maximum", chosen(0, builtIn) == 96000)
check("the top of the table matches exactly", chosen(768000, full) == 768000)

// MARK: the ratio test itself

check("2:1 is whole", AudioDevice.isIntegerRatio(96000, 192000))
check("1:2 is whole too", AudioDevice.isIntegerRatio(192000, 96000))
check("88.2/44.1 is whole despite the float", AudioDevice.isIntegerRatio(88200, 44100))
check("192/88.2 is not whole", !AudioDevice.isIntegerRatio(192000, 88200))
check("44.1/48 is not whole", !AudioDevice.isIntegerRatio(44100, 48000))
check("a zero never is", !AudioDevice.isIntegerRatio(0, 44100))

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "$WORK/probe" "$WORK/main.swift" Sources/AudioDevice.swift
"$WORK/probe"
