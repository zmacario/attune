#!/bin/bash
# What the format cache accepts, how it is keyed, and what it does under contention.
#
# Every check here corresponds to something that was once wrong, or that would be silently
# wrong if it broke: a guess getting stored and applied instantly on every later play; two
# recordings sharing a name and an artist sharing one entry; the notification and AppleScript
# spelling the same track id differently and never agreeing on a key; two writers dropping
# each other's entries.
#
# Runs against the real Settings in its own defaults domain, which it refuses to start
# without checking — the app's own cache is not a test fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let domain = ProcessInfo.processInfo.processName
precondition(domain != "com.macario.attune", "refusing: would write the app's real defaults")
UserDefaults.standard.set(2, forKey: "formatCacheVersion")

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    ok ? (passed += 1) : (failed += 1)
}

let settings = Settings.shared

// MARK: which sources are worth storing

func stores(_ source: TrackFormat.Source) -> Bool {
    let key = "id:SOURCE\(source.rawValue)"
    settings.remember(TrackFormat(sampleRate: 96000, bitDepth: 24, source: source), for: key)
    return settings.cachedFormat(for: key) != nil
}
check("stores what the player reported", stores(.player))
check("stores a plain file's own format", stores(.file))
check("refuses .movpkg, whose variant is ambiguous", !stores(.download))
check("refuses Music's metadata, which is second hand", !stores(.metadata))
check("refuses the fallback, which is a guess", !stores(.fallback))
check("refuses re-storing what it just read", !stores(.cache))

// MARK: round trip

let key = "id:ABCDEF0123456789"
settings.remember(TrackFormat(sampleRate: 96000, bitDepth: 24, source: .player), for: key)
let read = settings.cachedFormat(for: key)
check("rate and depth survive the round trip", read?.sampleRate == 96000 && read?.bitDepth == 24)
check("comes back labelled as remembered", read?.source == .cache)

settings.remember(TrackFormat(sampleRate: 44100, bitDepth: 16, source: .player), for: key)
check("a changed format overwrites", settings.cachedFormat(for: key)?.sampleRate == 44100)
check("an empty key is ignored", { settings.remember(TrackFormat(sampleRate: 48000, bitDepth: 24, source: .player), for: ""); return settings.cachedFormat(for: "") == nil }())

// MARK: the key

// Both spellings of one id, as captured from the running Music app.
let hex = "FD9BD6493A459860", decimal: Int64 = -172308550725035936
let otherHex = "11876F4793B60220", otherDecimal: Int64 = 1263100573712253472

check("notification id, negative", Settings.trackID(fromNotification: NSNumber(value: decimal)) == hex)
check("notification id, positive", Settings.trackID(fromNotification: NSNumber(value: otherDecimal)) == otherHex)
check("notification id as text", Settings.trackID(fromNotification: "\(decimal)") == hex)
check("an id already in hex", Settings.trackID(fromNotification: hex) == hex)
check("lowercase hex is accepted", Settings.trackID(fromNotification: hex.lowercased()) == hex)
check("absent id", Settings.trackID(fromNotification: nil) == nil)
check("nonsense is not an id", Settings.trackID(fromNotification: "not-an-id") == nil)

let viaNotification = Settings.cacheKey(id: Settings.trackID(fromNotification: NSNumber(value: decimal)),
                                        name: "In The Light Of Day", artist: "Lonesome Joy")
let viaAppleScript = Settings.cacheKey(id: hex, name: "In The Light Of Day", artist: "Lonesome Joy")
check("both paths agree on one key", viaNotification == viaAppleScript, viaNotification)

let download = Settings.cacheKey(id: hex, name: "In The Light Of Day", artist: "Lonesome Joy")
let stream = Settings.cacheKey(id: otherHex, name: "In The Light Of Day", artist: "Lonesome Joy")
check("same title and artist, different recordings, different keys", download != stream)
check("without an id, falls back to the text", Settings.cacheKey(id: nil, name: "X", artist: "Y") == "X|Y")

// MARK: writing

var writes = 0
final class Counter: NSObject {
    override func observeValue(forKeyPath: String?, of: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        writes += 1
    }
}
let counter = Counter()
UserDefaults.standard.addObserver(counter, forKeyPath: "formatCache", options: [], context: nil)

let steady = "id:0011223344556677"
settings.remember(TrackFormat(sampleRate: 48000, bitDepth: nil, source: .player), for: steady)
let before = writes
for _ in 0..<20 { settings.remember(TrackFormat(sampleRate: 48000, bitDepth: nil, source: .player), for: steady) }
check("hearing a known track again writes nothing", writes == before, "\(writes - before) writes")
settings.remember(TrackFormat(sampleRate: 96000, bitDepth: 24, source: .player), for: steady)
check("a changed format writes exactly once", writes == before + 1, "\(writes - before) writes")

// MARK: contention
//
// The app has one writer today, on a serial queue. This is here because the in-memory
// dictionary made a lost update easy to reach, and one writer is a fact that can change.
let group = DispatchGroup()
for worker in 0..<8 {
    DispatchQueue.global().async(group: group) {
        for i in 0..<500 {
            settings.remember(TrackFormat(sampleRate: 44100, bitDepth: 16, source: .player),
                              for: "id:W\(worker)-\(i)")
            _ = settings.cachedFormat(for: "id:W\(worker)-\(i / 2)")
        }
    }
}
check("4000 concurrent writes complete", group.wait(timeout: .now() + 120) == .success)
check("and none was lost", (0..<8).allSatisfy { worker in
    (0..<500).allSatisfy { settings.cachedFormat(for: "id:W\(worker)-\($0)")?.sampleRate == 44100 }
})

UserDefaults.standard.removeObserver(counter, forKeyPath: "formatCache")
UserDefaults.standard.removePersistentDomain(forName: domain)
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "$WORK/probe" "$WORK/main.swift" \
    Sources/Settings.swift Sources/TrackFormat.swift Sources/AudioDevice.swift \
    Sources/Localization.swift Sources/Log.swift Sources/Movpkg.swift Sources/MusicBridge.swift
"$WORK/probe"
