import Foundation
import AppKit

struct MusicTrack {
    var name: String
    var artist: String
    var path: String?        // nil for Apple Music streaming — nothing on disk to inspect
    var sampleRate: Int      // Music's own metadata; 0 when unknown
    var position: Double
}

struct MusicHygiene {
    var volume: Int          // Music's software volume, 0...100
    var eqEnabled: Bool
    var isClean: Bool { volume == 100 && !eqEnabled }
}

/// Everything we ask Music, over Apple Events. Requires the Automation permission
/// (System Settings → Privacy & Security → Automation).
enum MusicBridge {
    static let bundleID = "com.apple.Music"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    enum BridgeError: Error, CustomStringConvertible {
        case notRunning
        case scriptFailed(String)

        var description: String {
            switch self {
            case .notRunning: return localized("music.notRunning")
            case .scriptFailed(let m): return m
            }
        }
    }

    /// Apple Events are serialised here: NSAppleScript is not thread-safe, and the compiled
    /// script cache below is shared.
    private static let queue = DispatchQueue(label: "attune.music")
    private static var compiled: [String: NSAppleScript] = [:]

    /// Compiling a script that opens with `tell application id "com.apple.Music"` makes
    /// AppleScript load Music's whole scripting terminology — seconds, the first time.
    /// Compile once and reuse, or every pause costs that again.
    private static func script(for source: String) throws -> NSAppleScript {
        if let cached = compiled[source] { return cached }
        guard let script = NSAppleScript(source: source) else {
            throw BridgeError.scriptFailed(localized("music.scriptBroken"))
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw bridgeError(from: error)
        }
        compiled[source] = script
        return script
    }

    private static func bridgeError(from error: NSDictionary?) -> BridgeError {
        let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error?[NSAppleScript.errorMessage] as? String ?? "Apple Event failed (\(code))."
        Log.write("AppleScript error \(code): \(message)")
        // -1743 is the TCC denial; worth naming because the fix is not obvious.
        if code == -1743 {
            return .scriptFailed(localized("music.notAllowed"))
        }
        return .scriptFailed(message)
    }

    @discardableResult
    private static func run(_ source: String) throws -> String {
        guard isRunning else { throw BridgeError.notRunning }
        return try queue.sync {
            let script = try Log.timed("compile") { try self.script(for: source) }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error != nil { throw bridgeError(from: error) }
            return result.stringValue ?? ""
        }
    }

    /// The script lives in the bundle as its own file so `build.sh` can compile-check it —
    /// a syntax error here used to surface only as a silent failure at runtime.
    private static let snapshotScript: String? = {
        guard let url = Bundle.main.url(forResource: "Snapshot", withExtension: "applescript") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// One round trip for everything we need: player state, track identity, native rate,
    /// file path, plus the two settings that would silently break bit-perfect.
    static func snapshot() throws -> (state: String, track: MusicTrack?, hygiene: MusicHygiene) {
        guard let source = snapshotScript else {
            throw BridgeError.scriptFailed(localized("music.scriptMissing"))
        }
        let fields = try run(source).components(separatedBy: "\n")
        guard fields.count >= 8 else { throw BridgeError.scriptFailed(localized("music.badReply")) }

        let hygiene = MusicHygiene(volume: Int(fields[6]) ?? 100,
                                   eqEnabled: fields[7] == "true")
        let track = fields[1].isEmpty ? nil : MusicTrack(
            name: fields[1],
            artist: fields[2],
            path: fields[4].isEmpty ? nil : fields[4],
            sampleRate: Int(fields[3]) ?? 0,
            position: Double(fields[5]) ?? 0)

        return (fields[0], track, hygiene)
    }

    /// Where playback is, in seconds. Used to tell whether Music keeps running while the
    /// device reconfigures — if it does, that stretch of the music is simply lost.
    static func position() throws -> Double {
        let text = try run(#"tell application id "com.apple.Music" to get player position as text"#)
        // AppleScript formats reals with the system separator, which is not always a dot.
        return Double(text.replacingOccurrences(of: ",", with: ".")) ?? -1
    }

    static func pause() throws { try run(#"tell application id "com.apple.Music" to pause"#) }
    static func play()  throws { try run(#"tell application id "com.apple.Music" to play"#)  }

    static func seek(to seconds: Double) throws {
        try run("tell application id \"com.apple.Music\" to set player position to \(seconds)")
    }

    static func setVolumeToUnity() throws {
        try run(#"tell application id "com.apple.Music" to set sound volume to 100"#)
    }

    static func disableEQ() throws {
        try run(#"tell application id "com.apple.Music" to set EQ enabled to false"#)
    }
}
