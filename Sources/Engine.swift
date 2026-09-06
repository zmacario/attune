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

    private let work = DispatchQueue(label: "attune.engine")
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

    /// Identity and start time of the track being handled, so log lines can be attributed
    /// to it. The player's message names no track — only opaque pointers — so "emitted
    /// since this track started" is the only correlation available.
    private var trackKey: String?
    private var trackStartedAt = Date()
    private var missNotedForTrack = false
    private var playerAttemptsMade = 0

    /// The player item whose format was used for the previous track. A report carrying the
    /// same item belongs to that track, not this one — timing alone could not tell them
    /// apart, and skipping quickly made neighbouring tracks swap formats.
    private var lastPlayerItem: String?
    private var lastCachedKey: String?

    /// The rate change the next track will need, made before that track starts.
    ///
    /// The notification only arrives once the new track is already playing, so a change
    /// made then lands in its first second: about 0.85 s of silence, 730 ms of which is the
    /// DAC relocking its clock — a fixed cost of the hardware, measured the same in every
    /// direction. Doing it before the boundary moves that silence into the tail of the
    /// track that is ending, and the new one starts already at its own rate.
    ///
    /// The price is that the tail plays resampled. The margin is what buys the safety:
    /// the pause Apple Event has taken anywhere from 77 to 439 ms, and a switch that
    /// slipped past the boundary would land in exactly the place this avoids.
    private var preSwitchTimer: DispatchSourceTimer?
    private var preSwitchActivity: NSObjectProtocol?
    private static let preSwitchMargin: TimeInterval = 2.5

    /// The track whose successor's rate is already set on the device.
    ///
    /// Once that has happened the current track's own rate must not be applied again until
    /// the track really changes. Our own pause and play make Music emit a notification, and
    /// the track it names is still the one ending — acting on it put the device back on the
    /// old rate and cost two further changes instead of none, which is how the first
    /// version of this made things worse rather than better.
    private var preSwitchedFor: String?

    /// What the player told us about the track being played now, if anything.
    ///
    /// Without this, a second look at the same track saw the item it had already used,
    /// read that as "nothing new", and fell through to the fallback — overwriting a
    /// correct reading with a guess. No new report means the answer has not changed, not
    /// that there is no answer.
    private var playerFormatForTrack: TrackFormat?

    /// How many times to ask the player before giving up and guessing.
    ///
    /// Bounded by attempts rather than elapsed time, because the cost is per read and some
    /// tracks are never reported at all — a time budget with a short gap would spend
    /// several reads on those for nothing. Measured: the report lands within about a second
    /// of the track change when it lands at all, so three attempts cover it. The gap
    /// between them comes from PlayerLog, which knows what a read costs by the method that
    /// works here.
    private static let playerAttempts = 3

    /// How long after a track change a late report may still change the answer.
    ///
    /// Skipping faster than the player reports leaves the app describing one track while
    /// the player describes the next, and no rule reconciles two sources sampled at
    /// different moments. Re-resolving when a later report arrives converges during that
    /// scramble, while the bound keeps it from ever revisiting a track that has settled —
    /// a correction there would be a dropout in the middle of the music.
    private static let playerSettlingWindow: TimeInterval = 3

    /// How far *before* the track change a report may still belong to it. Generous,
    /// because the item identifier is what keeps the previous track's report out; this is
    /// only a sanity bound on how old an answer may be.
    private static let playerLookback: TimeInterval = 10


    private(set) var status = EngineStatus()
    var onStatusChange: ((EngineStatus) -> Void)?

    /// The device list changed. Separate from the status because the menu's device list is
    /// built from the devices themselves, not from what the engine decided about them.
    var onDevicesChanged: (() -> Void)?

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
        // Settle the log question once, so a streamed track never waits for a permission
        // the app does not have.
        work.async { [weak self] in
            self?.settings.warmFormatCache()
            Log.timed("player probe") { PlayerLog.probe() }
        }
        PlayerLog.onNewFormat = { [weak self] in self?.playerReportedNewItem() }
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
            DispatchQueue.main.async { self?.onDevicesChanged?() }
            // A moment for the HAL to settle before asking it what is there.
            self?.refreshStatus()
            self?.schedule(after: 0.3)
        }
        deviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(CA.system, &address, work, block)
        if status != noErr { Log.write("device listener FAILED: \(status)") }
    }

    /// A report for an item we have not used yet, arriving while the track is still
    /// settling. Worth another look; after the window, deliberately ignored.
    private func playerReportedNewItem() {
        work.async { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.trackStartedAt) < Self.playerSettlingWindow else { return }
            Log.write("player reported a new item while the track was settling; re-resolving")
            self.schedule(after: 0.05)
        }
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
            applyRememberedFormat(from: note.userInfo)
            schedule(after: 0.25)   // Music fires a burst on track change; take the last one
        } else {
            handleStopped()
        }
    }

    /// Applies a format learned on an earlier play, straight from the notification.
    ///
    /// Everything else waits a quarter second for the burst of notifications to settle and
    /// then spends an Apple Event asking Music what is playing. The notification already
    /// says, so a track heard before can be set before either of those — which is the whole
    /// difference between the pause landing inside the song and at its edge.
    ///
    /// The ordinary path still runs and still has the last word: if the player reports
    /// something else, it corrects within the settling window.
    private func applyRememberedFormat(from info: [AnyHashable: Any]?) {
        guard settings.matchSampleRate,
              let name = info?["Name"] as? String else { return }
        let key = Settings.cacheKey(id: Settings.trackID(fromNotification: info?["PersistentID"]),
                                    name: name, artist: info?["Artist"] as? String ?? "")
        guard key != lastCachedKey, let format = settings.cachedFormat(for: key) else { return }
        lastCachedKey = key

        work.async { [weak self] in
            guard let self, Date() >= self.suppressUntil,
                  let device = self.settings.resolveTargetDevice() else { return }
            guard abs(device.nominalSampleRate - format.sampleRate) >= 1 else { return }
            Log.write("remembered \(format.summary) for \(name); applying before asking Music")
            var status = self.status
            self.applyFormat(format, to: device, into: &status)
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
        // Suppression exists to ignore the notifications our own pause and play cause. It
        // must defer, not discard: a genuine event landing inside the window — the player
        // reporting the next track's format, say — would otherwise be dropped, and with
        // the track already settled nothing would ever ask again.
        if Date() < suppressUntil {
            Log.write("handlePlaying: deferred past our own pause/play")
            schedule(after: suppressUntil.timeIntervalSinceNow + 0.05)
            return
        }

        var next = status
        next.problem = nil
        next.playing = true

        let snapshot: (state: String, track: MusicTrack?, hygiene: MusicHygiene, upNext: UpNext?)
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
        noteTrack(snapshot.track)
        if !PlayerLog.isSettled { Log.timed("player probe") { PlayerLog.probe() } }
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
           let format = Log.timed("resolveFormat", { resolveFormat(for: track) }) {
            Log.write("resolved: \(format.summary) via \(format.source.rawValue); device at \(rateLabel(device.nominalSampleRate))")
            next.detected = format
            if preSwitchedFor == trackKey {
                Log.write("holding the rate prepared for the next track")
            } else {
                applyFormat(format, to: device, into: &next)
            }
        }

        if let track = snapshot.track {
            schedulePreSwitch(after: track, upNext: snapshot.upNext,
                              on: settings.resolveTargetDevice() ?? device)
        }

        let fresh = settings.resolveTargetDevice() ?? device
        next.deviceRate = fresh.nominalSampleRate
        next.wireFormat = fresh.currentPhysicalFormat?.describedBriefly

        // 3. Flag the two things that would quietly undo all of the above.
        next.hygieneProblem = Engine.hygieneProblem(snapshot.hygiene)

        publish(next)
    }

    /// Notices when the track changed, and where its start was. `position` is what puts
    /// the start in the right place when the app launches into a track already playing.
    private func noteTrack(_ track: MusicTrack?) {
        let key = track.map {
            Settings.cacheKey(id: $0.persistentID, name: $0.name, artist: $0.artist)
        } ?? "-"
        guard key != trackKey else { return }
        trackKey = key
        preSwitchedFor = nil
        missNotedForTrack = false
        playerAttemptsMade = 0
        playerFormatForTrack = nil
        let position = min(track?.position ?? 0, 120)   // bound the log window we ask for
        trackStartedAt = Date().addingTimeInterval(-position)
    }

    /// A streamed track has no file to read and Music reports its rate as zero, so the
    /// only honest source is the player's own log. Waiting a moment for it beats applying
    /// a guess and correcting later: a correction is a second dropout, in the middle of
    /// the music rather than at its start.
    private func resolveFormat(for track: MusicTrack) -> TrackFormat? {
        let streaming = track.path == nil

        // Asked for every track, not just streamed ones. The player reports the variant it
        // decoded either way, which is the only thing that knows whether Dolby Atmos is
        // actually playing — reading the .movpkg can see that an Atmos variant exists but
        // not whether Music chose it, and that guess used to be a setting the user had to
        // get right.
        if PlayerLog.isAvailable {
            let searchFrom = trackStartedAt.addingTimeInterval(-Self.playerLookback)
            let buffered = PlayerLog.latestFormat(since: searchFrom)
            Log.write("player check: buffered=\(buffered.map { "\($0.item) \(rateLabel($0.sampleRate))" } ?? "none")"
                      + " lastUsed=\(lastPlayerItem ?? "-") attempts=\(playerAttemptsMade)")
            // Nothing newer than what this track was already resolved from: keep it.
            if let already = playerFormatForTrack,
               buffered.map({ $0.item == lastPlayerItem }) ?? true {
                return already
            }

            if let reported = buffered,
               reported.item.isEmpty || reported.item != lastPlayerItem {
                lastPlayerItem = reported.item
                PlayerLog.noteHit()
                Log.write("player reports \(reported.rendition) \(rateLabel(reported.sampleRate))"
                          + " \(reported.bitDepth.map { "\($0)-bit" } ?? "")"
                          + " \(reported.channels.map { "\($0)ch" } ?? "")")
                let format = TrackFormat(sampleRate: reported.sampleRate,
                                         bitDepth: reported.bitDepth,
                                         source: .player)
                playerFormatForTrack = format
                settings.remember(format, for: trackKey ?? "")
                return format
            }
            // A streamed track has nothing else to go on, so it is worth waiting. A local
            // file does: resolve from it now, and let a later report correct it inside the
            // settling window if the two disagree.
            if streaming {
                playerAttemptsMade += 1
                if playerAttemptsMade < Self.playerAttempts {
                    schedule(after: PlayerLog.suggestedRetryInterval)
                    return nil
                }
            }
            if streaming, !missNotedForTrack {
                // Once per track, not once per attempt: the window expiring is re-checked
                // on every later event for the same track.
                missNotedForTrack = true
                PlayerLog.noteMiss()
            }
        }

        // What was learned before beats what would be guessed now. A cache entry is a
        // reading the player itself made on an earlier play — `remember` stores nothing
        // else — so falling straight through to the configured fallback threw a measurement
        // away in favour of an invention. Seen doing exactly that: the cache had put the
        // device on 48 kHz, the fallback pulled it to 44.1, and the player arrived two
        // seconds later to put it back. Three changes where none were due.
        //
        // A plain file still wins over the cache, being read from the track playing now, so
        // it also catches a file replaced since. A `.movpkg` does not: it can see which
        // variants exist but not which one Music chose, and the cache was told.
        let resolved = TrackFormat.resolve(track: track, fallbackRate: settings.fallbackRate)
        if resolved?.source != .file, let key = trackKey,
           let remembered = settings.cachedFormat(for: key) {
            Log.write("no player report; using what was learned before: \(remembered.summary)")
            return remembered
        }
        return resolved
    }

    /// Prepares the next track's rate while this one is still playing, when everything
    /// needed is known: what comes next, that its format was learned on an earlier play,
    /// and how long is left. Any of those missing means preparing nothing.
    private func schedulePreSwitch(after track: MusicTrack, upNext: UpNext?, on device: AudioDevice) {
        cancelPreSwitch()

        guard settings.prepareNextTrack, settings.matchSampleRate, settings.seamlessSwitch else { return }
        // Pausing is what makes this cost no audio. Without it the switch would eat about
        // 0.74 s of the tail instead of inserting silence, which is a worse trade.
        guard let upNext else { return }

        let key = Settings.cacheKey(id: upNext.persistentID, name: upNext.name, artist: upNext.artist)
        guard let format = settings.cachedFormat(for: key) else {
            Log.write("pre-switch: \(upNext.name) never heard, nothing to prepare")
            return
        }
        guard abs(device.nominalSampleRate - format.sampleRate) >= 1 else { return }
        guard device.supportedSampleRates.contains(where: { abs($0 - format.sampleRate) < 1 }) else { return }

        let remaining = track.duration - track.position
        let delay = remaining - Self.preSwitchMargin
        guard track.duration > 0, delay > 0 else {
            Log.write("pre-switch: only \(String(format: "%.1f", remaining))s left, too late to prepare")
            return
        }

        Log.write("pre-switch: \(upNext.name) needs \(rateLabel(format.sampleRate)), device at "
                  + "\(rateLabel(device.nominalSampleRate)); in \(String(format: "%.1f", delay))s")
        arm(format, name: upNext.name, duration: track.duration, after: delay)
    }

    /// A strict timer, and an activity assertion while one is pending.
    ///
    /// This is a menu bar app with no windows, and the coalescing that lets such an app
    /// sleep between wakeups is exactly what a deadline like this one cannot tolerate. The
    /// first version used a plain `asyncAfter` and the boundary went by without it ever
    /// running — it then fired inside the pause the ordinary path had already started, and
    /// returned without a word.
    private func arm(_ format: TrackFormat, name: String, duration: Double, after delay: TimeInterval) {
        let expected = trackKey
        cancelPreSwitch()

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: work)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.endPreSwitchActivity()
            self.runPreSwitch(format, name: name, duration: duration, expecting: expected)
        }
        preSwitchActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Preparing the next track's sample rate")
        preSwitchTimer = timer
        timer.resume()
    }

    private func cancelPreSwitch() {
        preSwitchTimer?.cancel()
        preSwitchTimer = nil
        endPreSwitchActivity()
    }

    private func endPreSwitchActivity() {
        guard let preSwitchActivity else { return }
        ProcessInfo.processInfo.endActivity(preSwitchActivity)
        self.preSwitchActivity = nil
    }

    private func runPreSwitch(_ format: TrackFormat, name: String, duration: Double,
                              expecting expected: String?) {
        // The boundary may already have been crossed — a manual skip, or a track shorter
        // than Music reported. Switching now would put the silence inside the new track,
        // which is the whole thing this exists to avoid.
        guard trackKey == expected else {
            Log.write("pre-switch: track already changed, standing down")
            return
        }
        guard Date() >= suppressUntil else {
            Log.write("pre-switch: fired inside our own pause window, too late — standing down")
            return
        }

        // Scrubbing the progress bar fires no notification, so the time left is worth
        // asking about rather than assuming: dragging backwards would otherwise put the
        // silence in the middle of the music.
        let position = (try? MusicBridge.position()) ?? -1
        if position >= 0, duration > 0 {
            let remaining = duration - position
            guard remaining <= Self.preSwitchMargin + 2 else {
                let delay = remaining - Self.preSwitchMargin
                Log.write("pre-switch: \(String(format: "%.1f", remaining))s left, not yet — "
                          + "waiting another \(String(format: "%.1f", delay))s")
                arm(format, name: name, duration: duration, after: delay)
                return
            }
        }

        guard let device = settings.resolveTargetDevice() else {
            Log.write("pre-switch: no target device, standing down")
            return
        }
        guard abs(device.nominalSampleRate - format.sampleRate) >= 1 else {
            Log.write("pre-switch: device already at \(rateLabel(format.sampleRate)), nothing to prepare")
            return
        }

        Log.write("pre-switch: applying \(format.summary) for \(name) before it starts")
        preSwitchedFor = trackKey
        var next = status
        applyFormat(format, to: device, into: &next)
        next.deviceRate = (settings.resolveTargetDevice() ?? device).nominalSampleRate
        publish(next)
    }

    private func applyFormat(_ format: TrackFormat, to device: AudioDevice,
                             into status: inout EngineStatus) {
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

        // Changing the rate under a live stream costs about 800 ms of reconfiguration
        // during which the audio is simply gone, and the discontinuity can click. Pausing
        // first turns that into a deliberate silence with nothing lost.
        //
        // It resumes where it paused rather than restarting the track. Rewinding made
        // sense when the change happened at the very first instant, but the rate is now
        // settled around 0.85 s in, and replaying that second is more noticeable than the
        // gap itself.
        let shouldPause = Settings.shared.seamlessSwitch

        if shouldPause {
            suppressUntil = Date().addingTimeInterval(6)
            try? Log.timed("pause") { try MusicBridge.pause() }
        }

        // Both readings sit inside the same interval, so the Apple Event each one costs
        // lands in the wall clock and in the position alike and cannot skew the comparison.
        // Only meaningful with the pause off: paused, the position obviously stands still.
        let measuring = settings.measureContinuity
        let startedAt = Date()
        let positionBefore = measuring ? try? MusicBridge.position() : nil

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
        if measuring, let positionBefore, let positionAfter = try? MusicBridge.position() {
            let wall = Date().timeIntervalSince(startedAt)
            let played = positionAfter - positionBefore
            Log.write(String(format: "continuity: wall %.2fs, playback advanced %.2fs — %@",
                             wall, played,
                             played > wall / 2 ? "audio was lost" : "Music stalled, nothing lost"))
        }

        Log.write("rate -> \(rateLabel(rate)): \(ok ? "ok" : "FAILED")")

        if shouldPause {
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
        cancelPreSwitch()
        // Cleared so that resuming this same track puts it back on its own rate: the
        // preparation only makes sense while the track is running out.
        preSwitchedFor = nil
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
