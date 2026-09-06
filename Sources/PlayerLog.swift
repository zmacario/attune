import Foundation
import OSLog

/// What Music's CoreMedia player actually decoded, as opposed to what a file says.
struct PlayerFormat {
    let rendition: String       // Stereo, Lossless, Multichannel
    let sampleRate: Double
    let bitDepth: Int?          // reported as 0 for lossy and for Atmos
    let channels: Int?

    /// The player's identifier for this item, e.g. "I/QX.257". The message names no track,
    /// but every track gets its own token and repeated reports of one share it — which is
    /// what tells a report about this track apart from one about the last.
    let item: String
}

/// Reads the format out of Music's own log.
///
/// For a streamed track there is no file to inspect and Music reports a sample rate of
/// zero, so the app used to fall back to a configured guess — which measured wrong on 42%
/// of streamed tracks, including a 192 kHz one played at 44.1. The CoreMedia player logs
/// the variant it settled on, and that line is the only source for it.
///
/// This is a debug message internal to Apple, not an API. It can change wording or vanish
/// in any macOS update, so nothing here is load-bearing: every caller has a path that works
/// without it, and the reader switches itself off after enough empty answers rather than
/// paying for a query on every track forever.
enum PlayerLog {
    private static let marker = "ReportAudioPlaybackThroughFig"
    private static let missLimit = 5

    /// Plausible audio rates. A parse that yields anything else is a parse that went wrong.
    private static let plausibleRates: ClosedRange<Double> = 8_000...768_000

    /// Which way of reading the log actually works here.
    ///
    /// OSLogStore needs Full Disk Access, which this app does not have and cannot prompt
    /// for. /usr/bin/log carries its own entitlement, so spawning it may work where the
    /// framework does not — but TCC may equally attribute the read back to us and refuse.
    /// Rather than guess, try both once and remember which answered.
    private enum Method { case undetermined, store, tool, none }

    private static let lock = NSLock()
    private static var misses = 0
    private static var givenUp = false
    private static var store: OSLogStore?
    private static var method: Method = .undetermined

    /// A long-running `log stream`, and the last format it pushed to us.
    ///
    /// Querying with `log show` costs about 800 ms per read, all of it process launch, and
    /// that delay was the whole reason the rate settled almost a second into a track rather
    /// than at its start. A stream costs that once. It is also fresher: a query was seen
    /// returning the previous track's format because the new line was not visible to it yet.
    private static var stream: Process?
    private static var pending = Data()
    private static var latest: (format: PlayerFormat, observedAt: Date)?

    /// The gap between attempts, on top of what a read itself costs — about 100 ms via the
    /// framework and about 800 ms via the tool. Kept short because the report, when it
    /// comes at all, lands within roughly a second of the track change; the number of
    /// attempts is what bounds the waste, not this.
    static var suggestedRetryInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        if stream?.isRunning == true { return 0.25 }   // reading costs nothing now
        return method == .store ? 0.3 : 0.6
    }

    /// False while the question has not been answerable yet — Music was not running.
    /// Called when the stream delivers a format the reader had not seen before. Lets a
    /// listener converge after skipping faster than the player can report.
    static var onNewFormat: (() -> Void)?

    static var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return method != .undetermined
    }

    /// Usable only once a method has been shown to work. Undetermined counts as
    /// unavailable on purpose: a caller that waits on "maybe" pays the full timeout for a
    /// permission the app may not have.
    static var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return method == .store || method == .tool
    }

    /// The most recent format reported since `date`, or nil if the player has not said yet.
    ///
    /// The last line wins: a stream starts on a lower variant and is upgraded moments
    /// later, so the first line would name the wrong one.
    /// Settles whether *Music's* log entries can be read here.
    ///
    /// The question has to name Music. Asking whether any entry at all can be read is not
    /// the same question and answers yes regardless — this app writes to the unified log
    /// too, so it would be reading itself and concluding the door is open.
    ///
    /// It is only a fair question while Music is running, which is also when it matters:
    /// Music logs thousands of lines a minute, so silence from it means refusal rather
    /// than quiet. Called again later if Music was closed the first time.
    static func probe() {
        guard MusicBridge.isRunning else { return }     // stays undetermined; asked again

        // The tool is tried first even though it costs seven times as much per read.
        // OSLogStore reads the persisted archive, and info-level entries take minutes to
        // land there — measured: an entry this process had just written was still invisible
        // to it after 30 seconds. /usr/bin/log reads the memory buffer too and sees the
        // same entry immediately. A cheap answer about a state from minutes ago is worth
        // nothing here.
        if canRead(via: .tool) {
            settle(on: .tool, "/usr/bin/log")
            startStreaming()
            return
        }
        if canRead(via: .store) { settle(on: .store, "OSLogStore"); return }
        giveUp("Music's log entries are not readable")
    }

    /// Asks for something *recent*, because the question is not only whether the log can
    /// be read but whether it can be read in time to be useful. Music logs thousands of
    /// lines a minute while playing, so a short window is still a fair question.
    private static func canRead(via method: Method) -> Bool {
        let seconds = 20.0
        let window = Date(timeIntervalSinceNow: -seconds)
        switch method {
        case .store:
            guard let store = try? OSLogStore(scope: .system) else { return false }
            lock.lock(); self.store = store; lock.unlock()
            let onlyMusic = NSPredicate(format: "process == %@", "Music")
            guard let entries = try? store.getEntries(at: store.position(date: window),
                                                      matching: onlyMusic) else { return false }
            for case _ as OSLogEntryLog in entries { return true }
            return false
        case .tool:
            let output = runLogTool(arguments: ["show", "--last", "\(Int(seconds))s",
                                                "--style", "compact",
                                                "--predicate", "process == \"Music\""])
            // `log show` prints a header even with no matches, so look for a line that
            // actually begins with a timestamp.
            return output?.split(separator: "\n").contains { $0.hasPrefix("20") } ?? false
        default:
            return false
        }
    }

    static func latestFormat(since date: Date) -> PlayerFormat? {
        lock.lock()
        let current = method
        let streaming = stream?.isRunning == true
        let buffered = latest
        lock.unlock()

        if streaming {
            // An in-memory read: nothing to pay, and never stale.
            guard let buffered, buffered.observedAt >= date else { return nil }
            return buffered.format
        }

        switch current {
        case .store: return viaStore(since: date)
        case .tool:  return viaLogTool(seconds: max(2, -date.timeIntervalSinceNow))
        default:     return nil
        }
    }

    // MARK: Streaming

    private static func startStreaming() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "compact", "--level", "debug",
                          "--predicate", "process == \"Music\" AND eventMessage CONTAINS \"\(marker)\""]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consume(data)
        }
        task.terminationHandler = { _ in
            // Falling back to per-track queries is slower but still correct.
            Log.write("player stream ended; falling back to querying per track")
        }

        guard (try? task.run()) != nil else {
            Log.write("player stream could not start; querying per track instead")
            return
        }
        lock.lock(); stream = task; lock.unlock()
        Log.write("player stream started")

        // The stream only carries what is emitted from now on, so a track already playing
        // would have nothing behind it. One query seeds the buffer with the current state.
        if let seeded = viaLogTool(seconds: 900) {
            lock.lock()
            if latest == nil { latest = (seeded, Date()) }
            lock.unlock()
        }
    }

    private static func consume(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let format = parse(line) else { continue }
            lock.lock()
            let isNewItem = latest?.format.item != format.item
            latest = (format, Date())
            lock.unlock()
            if isNewItem { onNewFormat?() }
        }
    }

    private static func settle(on chosen: Method, _ name: String) {
        lock.lock()
        let alreadySettled = method != .undetermined
        method = chosen
        lock.unlock()
        if !alreadySettled { Log.write("player log readable via \(name)") }
    }

    /// The framework path. Needs Full Disk Access; returns nothing without it, silently.
    private static func viaStore(since date: Date) -> PlayerFormat? {
        lock.lock()
        if store == nil { store = try? OSLogStore(scope: .system) }
        let store = self.store
        lock.unlock()
        guard let store else { return nil }

        let predicate = NSPredicate(format: "process == %@ AND eventMessage CONTAINS %@",
                                    "Music", marker)
        guard let entries = try? store.getEntries(at: store.position(date: date),
                                                  matching: predicate) else { return nil }
        var latest: PlayerFormat?
        for case let entry as OSLogEntryLog in entries {
            if let format = parse(entry.composedMessage) { latest = format }
        }
        return latest
    }

    /// The subprocess path: /usr/bin/log carries its own entitlement to read the log.
    private static func viaLogTool(seconds: TimeInterval) -> PlayerFormat? {
        guard let text = runLogTool(arguments: [
            "show", "--last", "\(Int(seconds.rounded(.up)))s", "--info", "--style", "compact",
            "--predicate", "process == \"Music\" AND eventMessage CONTAINS \"\(marker)\"",
        ]) else { return nil }

        var latest: PlayerFormat?
        for line in text.split(separator: "\n") {
            if let format = parse(String(line)) { latest = format }
        }
        return latest
    }

    private static func runLogTool(arguments: [String]) -> String? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        tool.arguments = arguments
        let output = Pipe()
        tool.standardOutput = output
        tool.standardError = FileHandle.nullDevice

        guard (try? tool.run()) != nil else { return nil }
        // Predicated queries return a handful of lines, so reading to the end cannot fill
        // the pipe and deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Called when a track went by without the player saying anything.
    static func noteMiss() {
        lock.lock()
        misses += 1
        let reached = misses >= missLimit
        lock.unlock()
        if reached { giveUp("\(missLimit) tracks in a row with nothing logged") }
    }

    static func noteHit() {
        lock.lock()
        misses = 0
        lock.unlock()
    }

    private static func giveUp(_ reason: String) {
        lock.lock()
        let alreadyGaveUp = givenUp
        givenUp = true
        lock.unlock()
        if !alreadyGaveUp {
            lock.lock(); method = .none; lock.unlock()
            Log.write("player log unavailable (\(reason)); streamed tracks fall back from here")
        }
    }

    // MARK: Parsing

    private static let fields = try! NSRegularExpression(
        pattern: #"\[Rendition (\w+)\].*?\[SampleRate (\d+)\].*?\[BitDepth (\d+)\]"#)
    private static let channelField = try! NSRegularExpression(pattern: #"\[AudioChannels (\d+)\]"#)
    private static let itemField = try! NSRegularExpression(pattern: #"<0x[0-9a-f]+\|([^>]+)>"#)

    static func parse(_ message: String) -> PlayerFormat? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = fields.firstMatch(in: message, range: range),
              let rendition = message.substring(match, 1),
              let rate = message.substring(match, 2).flatMap(Double.init),
              plausibleRates.contains(rate) else { return nil }

        let depth = message.substring(match, 3).flatMap(Int.init)
        let channels = channelField.firstMatch(in: message, range: range)
            .flatMap { message.substring($0, 1) }
            .flatMap(Int.init)

        let item = itemField.firstMatch(in: message, range: range)
            .flatMap { message.substring($0, 1) } ?? ""

        return PlayerFormat(rendition: rendition,
                            sampleRate: rate,
                            bitDepth: (depth ?? 0) > 0 ? depth : nil,
                            channels: channels,
                            item: item)
    }
}

private extension String {
    func substring(_ match: NSTextCheckingResult, _ group: Int) -> String? {
        guard let range = Range(match.range(at: group), in: self) else { return nil }
        return String(self[range])
    }
}
