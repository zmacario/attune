import Foundation

/// Apple Music downloads are not audio files — they are `.movpkg` bundles holding several
/// HLS variants of the same track (AAC stereo, ALAC lossless, Dolby Atmos), each with its
/// own sample rate. The rate we want is whichever variant Music will actually play, and
/// the only honest source for it is the MP4 init segment inside each variant.
struct MovpkgVariant {
    let bitrate: Int
    let codec: String          // "mp4a" (AAC), "alac" (lossless), "ec-3" (Atmos)
    let sampleRate: Double
    let bitDepth: Int?

    var isAtmos: Bool { codec == "ec-3" }
    var isLossless: Bool { codec == "alac" }

    var label: String {
        let depth = bitDepth.map { "\($0)-bit " } ?? ""
        return "\(codec) \(depth)\(rateLabel(sampleRate))"
    }
}

enum Movpkg {
    static func isMovpkg(_ path: String) -> Bool {
        path.hasSuffix(".movpkg") || path.hasSuffix(".movpkg/")
    }

    /// Music's own settings decide which variant plays, and only the lossless preference
    /// is readable. Whether Dolby Atmos is actually in use is not — so this path skips the
    /// Atmos variants entirely rather than guessing.
    ///
    /// It is a fallback: normally the player's log says which variant it decoded, Atmos
    /// included, and this runs only when that log cannot be read.
    static func losslessEnabled() -> Bool {
        UserDefaults(suiteName: "com.apple.Music")?.bool(forKey: "losslessEnabled") ?? true
    }

    static func preferredVariant(at path: String) -> MovpkgVariant? {
        let all = variants(at: path)
        let lossless = losslessEnabled()
        guard !all.isEmpty else { return nil }

        let stereo = all.filter { !$0.isAtmos }
        guard !stereo.isEmpty else { return all.max { $0.bitrate < $1.bitrate } }

        if lossless, let best = stereo.filter({ $0.isLossless }).max(by: { $0.bitrate < $1.bitrate }) {
            return best
        }
        return stereo.max { $0.bitrate < $1.bitrate }
    }


    static func variants(at path: String) -> [MovpkgVariant] {
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

        return entries.compactMap { dir -> MovpkgVariant? in
            // Variant directories are named "<index>-<bitrate>-<hash>".
            let parts = dir.lastPathComponent.split(separator: "-")
            guard parts.count >= 3, let bitrate = Int(parts[1]) else { return nil }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  let initFrag = files.first(where: { $0.pathExtension == "initfrag" }),
                  let data = try? Data(contentsOf: initFrag) else { return nil }
            return parse(initSegment: data, bitrate: bitrate)
        }
        .sorted { $0.bitrate < $1.bitrate }
    }

    // MARK: MP4 box parsing

    /// Internal rather than private so tools/test-movpkg.sh can feed it damaged bytes
    /// directly. Everything below reads attacker-shaped input in the sense that matters:
    /// a truncated or corrupt download must return nil, never bring the app down.
    static func parse(initSegment data: Data, bitrate: Int) -> MovpkgVariant? {
        var sampleRate: Double = 0
        var codec = "?"
        var bitDepth: Int?

        walk(data, from: 0, to: data.count, parent: "") { type, start, size, parent in
            let isSampleEntry = parent.hasSuffix("/stsd")
            switch type {
            case "mdhd":
                // For an audio track the media timescale is the sample rate. The version
                // byte is read through the bounds-checked path like everything else: a
                // box declaring size 8 carries no payload at all, and reading it directly
                // walked off the end of a truncated download.
                guard let version = readUInt8(data, at: start + 8) else { break }
                let offset = version == 0 ? start + 20 : start + 28
                if let value = readUInt32(data, at: offset) { sampleRate = Double(value) }

            case _ where isSampleEntry && type != "enca":
                // Unencrypted: the sample entry type is the codec itself.
                codec = type

            case "frma":
                // Encrypted (`enca`): `frma` names the codec that was wrapped.
                if let fourCC = readFourCC(data, at: start + 8) { codec = fourCC }

            case "alac" where !isSampleEntry:
                // The ALAC magic cookie — byte 17 holds the real bit depth.
                if size >= 36, let depth = readUInt8(data, at: start + 17) { bitDepth = Int(depth) }

            default:
                break
            }
        }

        guard sampleRate > 0 else { return nil }
        return MovpkgVariant(bitrate: bitrate, codec: codec, sampleRate: sampleRate, bitDepth: bitDepth)
    }

    /// Containers whose children we descend into. Sample entries carry a fixed-size header
    /// before their children, which is why they map to an offset rather than a flag.
    private static let containers: Set<String> =
        ["moov", "trak", "mdia", "minf", "stbl", "sinf", "schi", "wave"]
    private static let sampleEntryHeader = 36   // box header + AudioSampleEntry fields
    private static let stsdHeader = 16          // box header + version/flags + entry count

    private static func walk(_ data: Data, from start: Int, to end: Int, parent: String,
                             visit: (String, Int, Int, String) -> Void) {
        var offset = start
        while offset + 8 <= end {
            guard let rawSize = readUInt32(data, at: offset),
                  let type = readFourCC(data, at: offset + 4) else { return }

            var size = Int(rawSize)
            if size == 1 {
                // A 64-bit size larger than Int.max is not a box, it is a broken file —
                // and converting it would trap rather than return.
                guard let big = readUInt64(data, at: offset + 8), big <= UInt64(Int.max) else { return }
                size = Int(big)
            } else if size == 0 {
                size = end - offset
            }
            guard size >= 8, offset + size <= end else { return }

            visit(type, offset, size, parent)

            let path = parent + "/" + type
            if containers.contains(type) {
                walk(data, from: offset + 8, to: offset + size, parent: path, visit: visit)
            } else if type == "stsd" {
                walk(data, from: offset + stsdHeader, to: offset + size, parent: path, visit: visit)
            } else if parent.hasSuffix("/stsd") {
                // A sample entry (enca, mp4a, alac, ec-3…): its children sit past the header.
                if size > sampleEntryHeader {
                    walk(data, from: offset + sampleEntryHeader, to: offset + size, parent: path, visit: visit)
                }
            }
            offset += size
        }
    }

    private static func readUInt8(_ data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[offset]
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func readFourCC(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return String(bytes: data[offset..<offset + 4], encoding: .isoLatin1)
    }
}
