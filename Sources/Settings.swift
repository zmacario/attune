import Foundation

/// User-visible knobs, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private func bool(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? def
    }

    /// Make the target DAC the system output whenever Music starts playing.
    var routeToTarget: Bool {
        get { bool("routeToTarget", default: true) }
        set { defaults.set(newValue, forKey: "routeToTarget") }
    }

    /// Follow each track's native sample rate instead of leaving the DAC parked at one rate.
    var matchSampleRate: Bool {
        get { bool("matchSampleRate", default: true) }
        set { defaults.set(newValue, forKey: "matchSampleRate") }
    }

    /// Pause, switch, rewind to the top of the track, resume — avoids the click you get
    /// when the HAL restarts IO mid-stream.
    var seamlessSwitch: Bool {
        get { bool("seamlessSwitch", default: true) }
        set { defaults.set(newValue, forKey: "seamlessSwitch") }
    }

    /// Put the previous output device back when Music stops.
    var restoreOnStop: Bool {
        get { bool("restoreOnStop", default: false) }
        set { defaults.set(newValue, forKey: "restoreOnStop") }
    }

    /// Raise the wire format to the deepest the DAC offers at the chosen rate.
    var maximizeBitDepth: Bool {
        get { bool("maximizeBitDepth", default: true) }
        set { defaults.set(newValue, forKey: "maximizeBitDepth") }
    }

    /// UID of the DAC. Persisting the UID rather than the AudioDeviceID survives replugging.
    var targetDeviceUID: String? {
        get { defaults.string(forKey: "targetDeviceUID") }
        set { defaults.set(newValue, forKey: "targetDeviceUID") }
    }

    /// Rate to use when a track's native rate can't be determined (Apple Music streaming).
    /// 0 means "leave the DAC where it is".
    var fallbackRate: Double {
        get { defaults.object(forKey: "fallbackRate") as? Double ?? 44100 }
        set { defaults.set(newValue, forKey: "fallbackRate") }
    }

    /// Hidden, off by default: measures whether playback keeps running while the device
    /// reconfigures, at the cost of two Apple Events inside the very gap being measured.
    /// Enable with `defaults write com.macario.bitperfectdx measureContinuity -bool true`.
    var measureContinuity: Bool { bool("measureContinuity", default: false) }

    /// Remembered alongside the UID so an absent device can still be named in the menu —
    /// a device that is not connected cannot be looked up.
    var targetDeviceName: String? {
        get { defaults.string(forKey: "targetDeviceName") }
        set { defaults.set(newValue, forKey: "targetDeviceName") }
    }

    func setTargetDevice(_ device: AudioDevice) {
        targetDeviceUID = device.uid
        targetDeviceName = device.name
    }

    /// When each connected DAC was plugged in, by UID.
    ///
    /// CoreAudio does not report how long a device has been attached, so the app keeps its
    /// own record: a UID that turns up where it was not before is stamped now, and one
    /// that disappears is forgotten, so unplugging and replugging counts as new. Persisted
    /// so that ordering survives a relaunch with everything still attached.
    private var connectionTimes: [String: Date] {
        get { (defaults.dictionary(forKey: "connectionTimes") as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: "connectionTimes") }
    }

    /// The connected DACs, most recently plugged in first.
    func dacsByRecency(_ outputs: [AudioDevice]) -> [AudioDevice] {
        let dacs = outputs.filter(\.isWiredDAC)
        let present = Set(dacs.map(\.uid))
        var times = connectionTimes

        // One timestamp for the whole sweep: calling Date() inside the loop gave each
        // device a microsecond-apart stamp in arbitrary Set order, so devices that were
        // already attached when the app first ran came out in a random order instead of
        // tying and falling through to the name.
        let now = Date()
        var changed = false
        for uid in present where times[uid] == nil {
            times[uid] = now
            changed = true
        }
        for uid in times.keys where !present.contains(uid) {
            times.removeValue(forKey: uid)
            changed = true
        }
        if changed { connectionTimes = times }

        // Everything plugged in before the app first ran shares one timestamp; name is the
        // tie-break so the order does not shuffle between launches.
        return dacs.sorted {
            let left = times[$0.uid] ?? .distantPast
            let right = times[$1.uid] ?? .distantPast
            return left == right ? $0.name < $1.name : left > right
        }
    }

    /// What `--resolve` prints: the ordering the rules are applied to, and why one won.
    func explainResolution() -> String {
        let outputs = AudioDevice.allOutputs()
        let dacs = dacsByRecency(outputs)     // populates the record before it is read
        let times = connectionTimes
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"

        var lines = ["DACs by recency:"]
        if dacs.isEmpty { lines.append("    (none connected)") }
        for dac in dacs {
            let seen = times[dac.uid].map { stamp.string(from: $0) } ?? "?"
            lines.append("    \(dac.name)  (\(dac.transport))  connected \(seen)")
        }

        let preferred = targetDeviceName ?? "(never chosen)"
        let preferredPresent = targetDeviceUID.map { uid in outputs.contains { $0.uid == uid } } ?? false
        lines.append("Chosen in app: \(preferred)\(preferredPresent ? " — connected" : " — not connected")")

        let rule: String
        if preferredPresent { rule = "1. the device chosen in the app" }
        else if !dacs.isEmpty { rule = "2. most recently connected DAC" }
        else { rule = "3. built-in speakers" }
        lines.append("Rule applied: \(rule)")
        lines.append("Target: \(resolveTargetDevice()?.name ?? "none")")
        return lines.joined(separator: "\n")
    }

    /// Where the audio should go, in the order the user asked for:
    ///
    /// 1. the device they last chose in this app, if it is connected;
    /// 2. otherwise the most recently connected DAC;
    /// 3. otherwise the built-in speakers.
    ///
    /// The saved device is a preference rather than something the app waits around for: a
    /// DAC that turns up can take over without anyone opening a menu.
    func resolveTargetDevice() -> AudioDevice? {
        let outputs = AudioDevice.allOutputs()
        let dacs = dacsByRecency(outputs)

        if let uid = targetDeviceUID, let match = outputs.first(where: { $0.uid == uid }) {
            // Backfill the name whenever the device is present, both to migrate settings
            // written before it was recorded and to follow a device that gets renamed.
            if match.name != targetDeviceName { targetDeviceName = match.name }
            return match
        }
        if let mostRecent = dacs.first { return mostRecent }
        return outputs.first { $0.transport == "Built-in" } ?? AudioDevice.defaultOutput
    }
}
