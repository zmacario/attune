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

    /// Music plays the Dolby Atmos variant only when Atmos is forced on; on "Automatic"
    /// — the default — a stereo USB DAC gets the stereo stream instead. Off unless the
    /// user has actually set Atmos to Always On.
    var assumeAtmos: Bool {
        get { bool("assumeAtmos", default: false) }
        set { defaults.set(newValue, forKey: "assumeAtmos") }
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

    /// First-run device pick: the DAC by name, else any USB output, else the current default.
    func resolveTargetDevice() -> AudioDevice? {
        let outputs = AudioDevice.allOutputs()
        if let uid = targetDeviceUID, let match = outputs.first(where: { $0.uid == uid }) { return match }
        if let dx3 = outputs.first(where: { $0.name.localizedCaseInsensitiveContains("DX3") }) { return dx3 }
        if let usb = outputs.first(where: { $0.isUSB }) { return usb }
        return AudioDevice.defaultOutput
    }
}
