import AppKit
import CoreAudio

// A --list-devices mode, so you can see what the DAC advertises without opening the UI.
if CommandLine.arguments.contains("--list-devices") {
    let current = AudioDevice.defaultOutput
    for device in AudioDevice.allOutputs() {
        print("\n\(device.name) [\(device.transport)]\(device.id == current?.id ? "  ← default output" : "")\(device.isInUse ? "  · in use" : "")")
        print("  uid:   \(device.uid)")
        print("  now:   \(rateLabel(device.nominalSampleRate))"
              + (device.currentPhysicalFormat.map { " · \($0.describedBriefly)" } ?? ""))
        print("  rates: \(device.supportedSampleRates.map { rateLabel($0) }.joined(separator: ", "))")
        let depths = Set(device.availablePhysicalFormats().map { $0.mBitsPerChannel }).sorted()
        if !depths.isEmpty { print("  bits:  \(depths.map { "\($0)" }.joined(separator: ", "))") }
    }
    exit(0)
}

// --inspect <path>: what does this track actually contain?
if let index = CommandLine.arguments.firstIndex(of: "--inspect"),
   index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    print("path: \(path)")
    if Movpkg.isMovpkg(path) {
        let all = Movpkg.variants(at: path)
        print("movpkg with \(all.count) variant(s); Music lossless=\(Movpkg.losslessEnabled())")
        for v in all { print("  \(v.bitrate) bps  \(v.label)") }
        if let pick = Movpkg.preferredVariant(at: path) {
            print("  → would play: \(pick.label)")
        }
    } else if let format = TrackFormat.readingFile(at: path) {
        print("audio file: \(format.summary)")
    } else {
        print("could not read")
    }
    exit(0)
}

if CommandLine.arguments.contains("--resolve") {
    print(Settings.shared.explainResolution())
    exit(0)
}

// --watch-player: follow what the CoreMedia player reports, live. The variant is
// upgraded a moment after a stream starts, and that is only visible while it happens.
if CommandLine.arguments.contains("--watch-player") {
    // Unbuffered: a live watch has to emit as things happen, and stdout buffers whenever
    // it is not a terminal — piping it to a file would lose everything on interrupt.
    setvbuf(stdout, nil, _IONBF, 0)
    PlayerLog.probe()          // latestFormat answers nothing until the method is settled
    guard PlayerLog.isAvailable else {
        print("the system log is not readable from here")
        exit(1)
    }
    print("watching Music's player log — ^C to stop")
    var last = ""
    let started = Date()
    var first = true
    while Date().timeIntervalSince(started) < 120 {
        // A wide first look so the track already playing shows up straight away; narrow
        // ones after, because the cost of a query scales with the window.
        // The player reports on format changes, not on every track, so the last report
        // can be many minutes old and still describe what is playing now.
        let window: TimeInterval = first ? -900 : -5
        first = false
        if let format = PlayerLog.latestFormat(since: Date().addingTimeInterval(window)) {
            let depth = format.bitDepth.map { "\($0)-bit" } ?? "—"
            let channels = format.channels.map { "\($0)ch" } ?? "—"
            let line = "\(format.rendition)  \(rateLabel(format.sampleRate))  \(depth)  \(channels)  \(format.item)"
            if line != last {
                let stamp = DateFormatter()
                stamp.dateFormat = "HH:mm:ss"
                print("\(stamp.string(from: Date()))  \(line)")
                last = line
            }
        }
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
