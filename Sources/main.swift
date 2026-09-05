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
        if let pick = Movpkg.preferredVariant(at: path, assumeAtmos: false) {
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
