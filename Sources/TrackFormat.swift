import Foundation
import AudioToolbox

/// The native format of the track Music is playing, and where we learned it.
struct TrackFormat: Equatable {
    enum Source: String {
        case file      = "file"        // a plain audio file, read off disk — exact
        case download  = "download"    // an Apple Music .movpkg — exact, read from the HLS variant
        case metadata  = "Music"       // Music's own `sample rate` — usually right
        case fallback  = "fallback"    // nothing known, using the configured default

        /// `rawValue` stays English, because the log is a diagnostic; this is the menu's.
        var label: String {
            switch self {
            case .file:     return localized("source.file")
            case .download: return localized("source.download")
            case .metadata: return localized("source.metadata")
            case .fallback: return localized("source.fallback")
            }
        }
    }

    var sampleRate: Double
    var bitDepth: Int?
    var source: Source

    var summary: String {
        let rate = rateLabel(sampleRate)
        guard let bitDepth, bitDepth > 0 else { return rate }
        return "\(bitDepth)-bit / \(rate)"
    }

    /// Reads the real format out of a local library file. Lossless m4a (ALAC) reports
    /// mBitsPerChannel == 0, so the true depth comes from the source-bit-depth property.
    static func readingFile(at path: String) -> TrackFormat? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr,
              let fileID else { return nil }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &asbd) == noErr,
              asbd.mSampleRate > 0 else { return nil }

        var bits = Int(asbd.mBitsPerChannel)
        if bits == 0 {
            var depth: UInt32 = 0
            var depthSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileGetProperty(fileID, kAudioFilePropertySourceBitDepth, &depthSize, &depth) == noErr {
                bits = Int(depth)
            }
        }
        return TrackFormat(sampleRate: asbd.mSampleRate, bitDepth: bits > 0 ? bits : nil, source: .file)
    }

    static func resolve(track: MusicTrack, fallbackRate: Double, assumeAtmos: Bool) -> TrackFormat? {
        if let path = track.path {
            // Apple Music downloads are bundles of HLS variants, not audio files.
            if Movpkg.isMovpkg(path) {
                if let variant = Movpkg.preferredVariant(at: path, assumeAtmos: assumeAtmos) {
                    return TrackFormat(sampleRate: variant.sampleRate,
                                       bitDepth: variant.bitDepth,
                                       source: .download)
                }
            } else if let fromFile = readingFile(at: path) {
                return fromFile
            }
        }
        if track.sampleRate > 0 {
            return TrackFormat(sampleRate: Double(track.sampleRate), bitDepth: nil, source: .metadata)
        }
        guard fallbackRate > 0 else { return nil }
        return TrackFormat(sampleRate: fallbackRate, bitDepth: nil, source: .fallback)
    }
}
