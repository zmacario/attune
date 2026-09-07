#!/bin/bash
# The two log messages the app can read, and the counter that stands the reading down.
#
# Every sample here is verbatim from a running Music, kept as a fixture because the message
# is not public API: if a macOS update reshapes it, these strings are the record of what it
# used to look like, and the first thing to compare against.
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
func describe(_ f: PlayerFormat?) -> String {
    guard let f else { return "nil" }
    return "\(f.rendition) \(Int(f.sampleRate))Hz \(f.bitDepth.map { "\($0)bit" } ?? "no depth")"
        + " \(f.channels.map { "\($0)ch" } ?? "?") item=\"\(f.item)\""
}

// Captured from macOS 15.7.9, Music 1.5.6.
let coreMedia = "[com.apple.coremedia:player] <<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x7fe195883b00|]: <0x7fe2471f7e00|I/WR.335>: [AudioFormat qlac is  decodable] [AudioChannels 2] [Rendition Lossless] [SampleRate 96000] [BitDepth 24]"
let musicLossless = "[com.apple.Music:ampplay] play> cm>> mediaFormatinfo '<private>' , audioCapabilities: 0x0 -> 0x4, 0x0 -> 0x4, asbdFormatID = qlac, lossless, asbdNumChannels = 2, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
let musicHiRes = "[com.apple.Music:ampplay] play> cm>> mediaFormatinfo '<private>' , audioCapabilities: 0x10, 0x10, asbdFormatID = qlac, high res lossless, asbdNumChannels = 2, asbdSampleRate = 192.0 kHz, is "
let musicAtmos = "[com.apple.Music:ampplay] play> cm>> mediaFormatinfo '<private>' , songEnhanced, audioCapabilities: 0x1 -> 0x1, 0x1 -> 0x1, asbdFormatID = qc+3, sdFormatID = ec+3, Dolby Atmos, asbdNumChannels = 12, sdNumChannels = 16, sdBitRate = 768 kbps, asbdSampleRate = 48.0 kHz, is rendering spatial audio, is Atmos"

// MARK: CoreMedia, the source

let primary = PlayerLog.parse(coreMedia)
check("rate, depth and channels", primary?.sampleRate == 96000 && primary?.bitDepth == 24 && primary?.channels == 2,
      describe(primary))
check("the per-track token, which nothing else carries", primary?.item == "I/WR.335")
check("the rendition", primary?.rendition == "Lossless")

// MARK: Music's own line, the reserve

let lossless = PlayerLog.parseFallback(musicLossless)
// 44.1 * 1000 is 44100.000000000007 in binary floating point, which is in no list of rates.
check("44.1 kHz survives the multiplication", lossless?.sampleRate == 44100, describe(lossless))
check("rendition mapped onto CoreMedia's vocabulary", lossless?.rendition == "Lossless")
check("channels", lossless?.channels == 2)
check("no depth, which this message usually omits", lossless?.bitDepth == nil)
check("and no token, which is why it is only a reserve", lossless?.item == "")

check("192 kHz hi-res", PlayerLog.parseFallback(musicHiRes)?.sampleRate == 192000)

let atmos = PlayerLog.parseFallback(musicAtmos)
check("Atmos reads as multichannel at 48 kHz",
      atmos?.sampleRate == 48000 && atmos?.rendition == "Multichannel", describe(atmos))
// sdBitRate = 768 kbps sits close enough to sdBitDepth to catch a careless pattern.
check("bitrate is not mistaken for bit depth", atmos?.bitDepth == nil)

// MARK: the two must not poach each other's lines

check("the reserve ignores CoreMedia's line", PlayerLog.parseFallback(coreMedia) == nil)
check("the source ignores Music's line", PlayerLog.parse(musicLossless) == nil)

// MARK: nonsense

check("an implausible rate is refused", PlayerLog.parseFallback("asbdSampleRate = 7.3 kHz") == nil)
check("a line with no rate is refused", PlayerLog.parseFallback("asbdFormatID = qlac, lossless") == nil)
check("an empty line is refused", PlayerLog.parse("") == nil && PlayerLog.parseFallback("") == nil)

// MARK: standing the reading down

PlayerLog.forceMethodForTesting()
check("starts available", PlayerLog.isAvailable)
for _ in 1...4 { PlayerLog.noteMiss() }
check("four silent tracks are tolerated", PlayerLog.isAvailable)
PlayerLog.noteHit()
for _ in 1...4 { PlayerLog.noteMiss() }
check("a hit resets the count", PlayerLog.isAvailable)
PlayerLog.noteMiss()
check("the fifth stands the reading down", !PlayerLog.isAvailable)

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "$WORK/probe" "$WORK/main.swift" \
    Sources/PlayerLog.swift Sources/Log.swift Sources/MusicBridge.swift \
    Sources/Localization.swift Sources/AudioDevice.swift
"$WORK/probe"
