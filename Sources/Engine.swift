import Foundation
import AppKit
import CoreAudio

struct EngineStatus: Equatable {
    var targetName: String = "—"
    var deviceRate: Double = 0
    var wireFormat: String?
    var trackTitle: String?
    var detected: TrackFormat?
    var problem: String?
    /// False when the chosen device is configured but not plugged in. The name is still
    /// shown, so the menu can say which device is missing.
    var targetConnected: Bool = true
    /// Kept apart from `problem` because the two have different lifetimes: a device or
    /// script failure belongs to one playback attempt, while Music's volume and EQ are
    /// standing conditions that can change with no notification at all.
    var hygieneProblem: String?
    var playing: Bool = false
}

/// Watches Music, and keeps the DAC on the track's own sample rate.
final class Engine {
    static let shared = Engine()

    private let work = DispatchQueue(label: "bitperfectdx.engine")
    private let settings = Settings.shared
    private var pendingWork: DispatchWorkItem?
    private var poll: DispatchSourceTimer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Music's volume and EQ change with no notification of any kind, so the only way to
    /// keep the menu bar honest is to look. The generous leeway lets the system coalesce
    /// this with other wakeups, and the Apple Event is skipped when Music is closed.
    private static let pollInterval: DispatchTimeInterval = .seconds(15)
    private static let pollLeeway: DispatchTimeInterval = .seconds(5)
    private var suppressUntil = Date.distantPast   // ignore the notifications our own pause/play cause
    private var previousDeviceUID: String?

    private(set) var status = EngineStatus()
    var onStatusChange: ((EngineStatus) -> Void)?

    // MARK: Lifecycle

    func start() {
        let center = DistributedNotificationCenter.default()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        Log.write("engine start; version \(version) (\(build)); Music running=\(MusicBridge.isRunning)")
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            center.addObserver(self,
                               selector: #selector(playerInfoChanged(_:)),
                               name: Notification.Name(name),
                               object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        refreshStatus()
        startPolling()
        startDeviceListener()
        warmUpMediaAccess()
        // If Music is already playing when we launch, act on it right away.
        if MusicBridge.isRunning { schedule(after: 0.3) }
    }

    /// Unplugging the DAC that is playing makes macOS move the audio somewhere else
    /// immediately — usually the built-in speakers. Without this the app would not notice
    /// until the next track change, and the music would carry on out of the wrong output.
    /// The poll cannot cover it either: that refreshes what the menu shows, it does not
    /// re-route.
    private func startDeviceListener() {
        var address = CA.addr(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Log.write("device list changed")
            // A moment for the HAL to settle before asking it what is there.
            self?.refreshStatus()
            self?.schedule(after: 0.3)
        }
        deviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(CA.system, &address, work, block)
        if status != noErr { Log.write("device listener FAILED: \(status)") }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + Self.pollInterval,
                       repeating: Self.pollInterval,
                       leeway: Self.pollLeeway)
        timer.setEventHandler { [weak self] in self?.refreshStatus() }
        timer.resume()
        poll = timer
    }

    /// The first read of the Apple Music media folder by a given build costs a few seconds
    /// while macOS resolves access for that binary. Pay it here, off the critical path,
    /// instead of on the first track — where it would delay the rate switch.
    private func warmUpMediaAccess() {
        DispatchQueue.global(qos: .utility).async {
            let media = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/Music/Media.localized")
            Log.timed("warm-up") {
                _ = try? FileManager.default.contentsOfDirectory(atPath: media.path)
            }
        }
    }

    @objc private func playerInfoChanged(_ note: Notification) {
        let state = note.userInfo?["Player State"] as? String
        Log.write("notification: \(note.name.rawValue) state=\(state ?? "nil") keys=\(note.userInfo?.keys.map { "\($0)" }.sorted().joined(separator: ",") ?? "-")")
        if state == "Playing" || state == nil {
            schedule(after: 0.25)   // Music fires a burst on track change; take the last one
        } else {
            handleStopped()
        }
    }

    private func schedule(after delay: TimeInterval) {
        pendingWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.handlePlaying() }
        pendingWork = item
        work.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Reacting to playback

    /// Re-apply everything on demand (menu item, or after the user changes a setting).
    func reapply() { schedule(after: 0) }

    private func handlePlaying() {
        guard Date() >= suppressUntil else {
            Log.write("handlePlaying: suppressed (our own pause/play)")
            return
        }

        var next = status
        next.problem = nil
        next.playing = true

        let snapshot: (state: String, track: MusicTrack?, hygiene: MusicHygiene)
        do {
            snapshot = try Log.timed("snapshot") { try MusicBridge.snapshot() }
        } catch {
            Log.write("snapshot FAILED: \(error)")
            next.problem = "\(error)"
            publish(next)
            return
        }
        Log.write("snapshot: state=\(snapshot.state) track=\(snapshot.track?.name ?? "-") "
                  + "metaRate=\(snapshot.track?.sampleRate ?? -1) path=\(snapshot.track?.path ?? "none") "
                  + "vol=\(snapshot.hygiene.volume) eq=\(snapshot.hygiene.eqEnabled)")

        guard snapshot.state == "playing" else { publish(next); return }
        next.trackTitle = snapshot.track.map {
            $0.artist.isEmpty ? $0.name : "\($0.name) — \($0.artist)"
        }

        guard var device = Log.timed("resolveTargetDevice", { settings.resolveTargetDevice() }) else {
            // Do nothing rather than retarget: changing some other device's sample rate
            // because the DAC was unplugged is worse than leaving everything alone.
            markTargetUnavailable(in: &next)
            Log.write("no usable target: \(next.problem ?? "-")")
            publish(next)
            return
        }
        next.targetConnected = true
        next.targetName = device.name

        // 1. Route the stream to the DAC.
        if settings.routeToTarget, Log.timed("defaultOutput", { AudioDevice.defaultOutput?.id }) != device.id {
            previousDeviceUID = AudioDevice.defaultOutput?.uid
            if device.makeDefaultOutput() {
                Log.write("default output -> \(device.name)")
                // The HAL hands out a fresh device object after a default change.
                device = settings.resolveTargetDevice() ?? device
            } else {
                Log.write("default output -> \(device.name): FAILED")
                next.problem = localized("engine.switchFailed")
            }
        }

        // 2. Put the DAC on the track's own rate.
        if settings.matchSampleRate, let track = snapshot.track,
           let format = Log.timed("resolveFormat", { TrackFormat.resolve(track: track,
                                                                         fallbackRate: settings.fallbackRate,
                                                                         assumeAtmos: settings.assumeAtmos) }) {
            Log.write("resolved: \(format.summary) via \(format.source.rawValue); device at \(rateLabel(device.nominalSampleRate))")
            next.detected = format
            applyFormat(format, to: device, trackPosition: track.position, into: &next)
        }

        let fresh = settings.resolveTargetDevice() ?? device
        next.deviceRate = fresh.nominalSampleRate
        next.wireFormat = fresh.currentPhysicalFormat?.describedBriefly

        // 3. Flag the two things that would quietly undo all of the above.
        next.hygieneProblem = Engine.hygieneProblem(snapshot.hygiene)

        publish(next)
    }

    private func applyFormat(_ format: TrackFormat, to device: AudioDevice,
                             trackPosition: Double, into status: inout EngineStatus) {
        let supported = device.supportedSampleRates
        Log.write("applyFormat: want \(rateLabel(format.sampleRate)), device supports \(supported.map { rateLabel($0) }.joined(separator: "/"))")
        guard let rate = supported.first(where: { abs($0 - format.sampleRate) < 1 }) else {
            status.problem = localized("engine.rateUnsupported", device.name, rateLabel(format.sampleRate))
            return
        }
        guard abs(device.nominalSampleRate - rate) >= 1 else {
            Log.write("applyFormat: already at \(rateLabel(rate)), nothing to do")
            return
        }

        // Changing the rate under a live stream clicks. Pausing first, then restarting the
        // track from the top, gives a clean transition — but only rewind if we're still
        // near the start, so a manual seek isn't thrown away.
        let shouldPause = Settings.shared.seamlessSwitch
        let rewind = shouldPause && trackPosition < 8

        if shouldPause {
            suppressUntil = Date().addingTimeInterval(6)
            try? Log.timed("pause") { try MusicBridge.pause() }
        }

        // The physical format carries the sample rate, so setting it alone reconfigures the
        // device once rather than twice — the DAC relocks its clock on each change, and that
        // relock is most of the silence the listener hears.
        var ok = false
        if Settings.shared.maximizeBitDepth, let best = device.bestPhysicalFormat(at: rate) {
            ok = Log.timed("setPhysicalFormat") { device.setPhysicalFormat(best) }
        }
        // Fall back to the nominal rate if the device refused the format, or accepted it
        // without following through on the rate.
        if !ok || abs(device.nominalSampleRate - rate) >= 1 {
            ok = Log.timed("setSampleRate") { device.setSampleRate(rate) }
        }
        Log.write("rate -> \(rateLabel(rate)): \(ok ? "ok" : "FAILED")")

        if shouldPause {
            if rewind { try? MusicBridge.seek(to: 0) }
            try? Log.timed("play") { try MusicBridge.play() }
            suppressUntil = Date().addingTimeInterval(1.0)
        }

        if !ok { status.problem = localized("engine.setRateFailed", rateLabel(rate)) }
    }

    /// Nothing to act on. Not a fault: listening through the built-in speakers or a
    /// Bluetooth headset is a normal thing to be doing, and a DAC plugged in later is
    /// picked up on its own.
    private func markTargetUnavailable(in status: inout EngineStatus) {
        status.targetConnected = false
        status.deviceRate = 0
        status.wireFormat = nil
        status.targetName = localized("menu.noDAC")
        status.problem = nil
    }

    private func handleStopped() {
        guard Date() >= suppressUntil else { return }
        work.async { [weak self] in
            guard let self else { return }
            var next = self.status
            next.playing = false
            if self.settings.restoreOnStop, let uid = self.previousDeviceUID,
               let previous = AudioDevice.allOutputs().first(where: { $0.uid == uid }) {
                previous.makeDefaultOutput()
                Log.write("default output restored -> \(previous.name)")
                self.previousDeviceUID = nil
            }
            self.publish(next)
        }
    }

    // MARK: Status

    /// Music's volume and EQ change without any notification, so they have to be read
    /// again rather than remembered from the last track change — otherwise the warning
    /// only ever appears if the setting was already wrong when a track happened to start.
    private static func hygieneProblem(_ hygiene: MusicHygiene) -> String? {
        guard !hygiene.isClean else { return nil }
        var issues: [String] = []
        if hygiene.volume != 100 { issues.append(localized("engine.volumeProblem", hygiene.volume)) }
        if hygiene.eqEnabled { issues.append(localized("engine.eqProblem")) }
        return issues.joined(separator: ", ")
    }

    func refreshStatus() {
        work.async { [weak self] in
            guard let self else { return }
            var next = self.status
            if let device = self.settings.resolveTargetDevice() {
                next.targetConnected = true
                next.targetName = device.name
                next.deviceRate = device.nominalSampleRate
                next.wireFormat = device.currentPhysicalFormat?.describedBriefly
            } else {
                self.markTargetUnavailable(in: &next)
            }
            // Costs one Apple Event per menu open, off the main thread; the header fills
            // in a moment after the menu appears.
            next.hygieneProblem = MusicBridge.isRunning
                ? (try? MusicBridge.snapshot()).map { Engine.hygieneProblem($0.hygiene) } ?? nil
                : nil
            self.publish(next)
        }
    }

    private func publish(_ new: EngineStatus) {
        // Polling would otherwise repaint the menu every fifteen seconds for nothing.
        guard new != status else { return }
        status = new
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStatusChange?(new)
        }
    }
}
