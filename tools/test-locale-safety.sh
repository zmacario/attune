#!/bin/bash
# Checks that the format cache is written and read the same way in every locale.
#
# The cache stores text: "96000|24" under a key like "id:FD9BD6493A459860". Any of that
# going through a locale-aware conversion would make a German write "96.000", an Egyptian
# write "٩٦٠٠٠", and every entry unreadable to the next reader — silently, since a failed
# parse simply looks like a track that was never heard.
#
# Swift's string interpolation and Double(String) are locale-independent by design, unlike
# String(format:) — which did produce "44.1 kHz" where "44,1 kHz" was wanted, and is why
# this is worth pinning rather than assuming. Turkish is in the list for the dotless i,
# Arabic and Hindi for their own digit shapes, German and Russian for the decimal comma.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let domain = ProcessInfo.processInfo.processName
precondition(domain != "com.macario.attune", "refusing: would write the app's real defaults")
UserDefaults.standard.set(2, forKey: "formatCacheVersion")

let settings = Settings.shared
let key = Settings.cacheKey(id: Settings.trackID(fromNotification: NSNumber(value: Int64(-172308550725035936))),
                            name: "Track", artist: "Artist")
settings.remember(TrackFormat(sampleRate: 96000, bitDepth: 24, source: .player), for: key)

let stored = (UserDefaults.standard.dictionary(forKey: "formatCache") as? [String: String]) ?? [:]
let read = settings.cachedFormat(for: key)
UserDefaults.standard.removePersistentDomain(forName: domain)

let ok = stored.keys.first == "id:FD9BD6493A459860"
      && stored.values.first == "96000|24"
      && read?.sampleRate == 96000 && read?.bitDepth == 24
print("\(ok ? "ok  " : "FAIL")  \(Locale.current.identifier)"
      + "  key=\(stored.keys.first ?? "-")  value=\(stored.values.first ?? "-")"
      + "  read=\(read.map { "\(Int($0.sampleRate))/\($0.bitDepth ?? -1)" } ?? "-")")
exit(ok ? 0 : 1)
SWIFT

swiftc -O -o "$WORK/probe" "$WORK/main.swift" \
    Sources/Settings.swift Sources/TrackFormat.swift Sources/AudioDevice.swift \
    Sources/Localization.swift Sources/Log.swift Sources/Movpkg.swift Sources/MusicBridge.swift

failed=0
for locale in en_US ar_EG hi_IN tr_TR de_DE ru_RU zh_Hans_CN pt_BR; do
    "$WORK/probe" -AppleLocale "$locale" -AppleLanguages "(${locale%%_*})" || failed=1
done

if [ "$failed" -eq 0 ]; then
    echo "cache is locale-independent"
else
    echo "cache changed shape under some locale — see above" >&2
fi
exit "$failed"
