import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Thin, typed wrapper over the CoreAudio HAL property API.

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(object, &a)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        var out = initial
        let status = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        return status == noErr ? out : nil
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<T>.stride) else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: raw.bindMemory(to: T.self, capacity: count), count: count))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ newValue: T) -> OSStatus {
        var a = address
        var v = newValue
        return withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }
}

// MARK: - Devices

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannels: Int
    let transport: String

    /// An external converter on a cable. Excludes Bluetooth and AirPlay, which resample
    /// on their own and cannot be bit-perfect anyway, and the built-in output, which is
    /// not a device anyone buys a DAC to avoid using.
    ///
    /// DisplayPort and HDMI are deliberately out: they are wired and they do carry digital
    /// audio, but they are a monitor or a TV, not something to adopt on sight. They stay
    /// selectable by hand.
    var isWiredDAC: Bool { ["USB", "Thunderbolt", "FireWire"].contains(transport) }

    static func allOutputs() -> [AudioDevice] {
        CA.array(CA.system, CA.addr(kAudioHardwarePropertyDevices), AudioDeviceID.self)
            .compactMap { AudioDevice($0) }
            .filter { $0.outputChannels > 0 }
    }

    init?(_ id: AudioDeviceID) {
        let channels = AudioDevice.outputChannelCount(id)
        guard channels > 0 else { return nil }
        self.id = id
        self.outputChannels = channels
        self.name = CA.string(id, CA.addr(kAudioObjectPropertyName)) ?? "Device \(id)"
        self.uid  = CA.string(id, CA.addr(kAudioDevicePropertyDeviceUID)) ?? "device-\(id)"
        self.transport = AudioDevice.transportName(id)
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var a = CA.addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportName(_ id: AudioDeviceID) -> String {
        guard let raw = CA.value(id, CA.addr(kAudioDevicePropertyTransportType), UInt32(0)) else { return "?" }
        switch raw {
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeBuiltIn:     return "Built-in"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:        return "HDMI"
        case kAudioDeviceTransportTypeBluetooth:   return "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
        case kAudioDeviceTransportTypeAggregate:   return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:     return "Virtual"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire:    return "FireWire"
        default:                                   return "Other"
        }
    }

    // MARK: Sample rate

    var nominalSampleRate: Double {
        CA.value(id, CA.addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    var supportedSampleRates: [Double] {
        CA.array(id, CA.addr(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self)
            .flatMap { range -> [Double] in
                // Discrete devices report min == max; a true range means the device
                // will accept anything in between (rare on USB DACs).
                range.mMinimum == range.mMaximum
                    ? [range.mMinimum]
                    : AudioDevice.standardRates.filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
            }
            .reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted()
    }

    static let standardRates: [Double] = [
        44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000
    ]

    /// Sets the device's nominal rate and waits for the HAL to actually apply it.
    @discardableResult
    func setSampleRate(_ rate: Double, timeout: TimeInterval = 2.0) -> Bool {
        if abs(nominalSampleRate - rate) < 1 { return true }
        guard CA.set(id, CA.addr(kAudioDevicePropertyNominalSampleRate), Float64(rate)) == noErr else {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if abs(nominalSampleRate - rate) < 1 { return true }
            usleep(20_000)
        }
        return abs(nominalSampleRate - rate) < 1
    }

    // MARK: Physical (wire) format

    var outputStreams: [AudioStreamID] {
        CA.array(id, CA.addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)
    }

    var currentPhysicalFormat: AudioStreamBasicDescription? {
        guard let stream = outputStreams.first else { return nil }
        return CA.value(stream, CA.addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription())
    }

    func availablePhysicalFormats() -> [AudioStreamBasicDescription] {
        guard let stream = outputStreams.first else { return [] }
        return CA.array(stream,
                        CA.addr(kAudioStreamPropertyAvailablePhysicalFormats),
                        AudioStreamRangedDescription.self)
            .map(\.mFormat)
    }

    /// Highest bit depth the device offers at `rate`, in linear PCM. Deeper is never lossy:
    /// a 24-bit sample zero-padded into a 32-bit slot arrives at the DAC unchanged.
    func bestPhysicalFormat(at rate: Double) -> AudioStreamBasicDescription? {
        availablePhysicalFormats()
            .filter { $0.mFormatID == kAudioFormatLinearPCM }
            .filter { $0.mSampleRate == 0 || abs($0.mSampleRate - rate) < 1 }
            .max { ($0.mBitsPerChannel, $0.mChannelsPerFrame) < ($1.mBitsPerChannel, $1.mChannelsPerFrame) }
            .map { fmt in
                var f = fmt
                f.mSampleRate = rate
                return f
            }
    }

    @discardableResult
    func setPhysicalFormat(_ format: AudioStreamBasicDescription, timeout: TimeInterval = 2.0) -> Bool {
        guard let stream = outputStreams.first else { return false }
        guard CA.set(stream, CA.addr(kAudioStreamPropertyPhysicalFormat), format) == noErr else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = currentPhysicalFormat,
               abs(now.mSampleRate - format.mSampleRate) < 1,
               now.mBitsPerChannel == format.mBitsPerChannel { return true }
            usleep(20_000)
        }
        return false
    }

    /// True while some app is holding the device open and rendering to it.
    var isInUse: Bool {
        (CA.value(id, CA.addr(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) != 0
    }

    // MARK: Volume

    /// True when the macOS volume slider is wired to the DAC's own hardware attenuator
    /// (or to nothing at all). False means macOS scales the samples in software.
    var hasHardwareVolumeControl: Bool {
        CA.has(id, CA.addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0))
            || !CA.has(id, CA.addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1))
    }

    // MARK: Default output

    static var defaultOutput: AudioDevice? {
        guard let id = CA.value(CA.system,
                                CA.addr(kAudioHardwarePropertyDefaultOutputDevice),
                                AudioDeviceID(0)) else { return nil }
        return AudioDevice(id)
    }

    @discardableResult
    func makeDefaultOutput() -> Bool {
        CA.set(CA.system, CA.addr(kAudioHardwarePropertyDefaultOutputDevice), id) == noErr
    }
}

// MARK: - Formatting helpers

/// "44.1 kHz", "192 kHz" — the way a DAC's front panel would say it.
/// The rate as text. Whole numbers of kHz have no decimal separator to argue about; the
/// rest do, and the two audiences want different answers.
///
/// `forDisplay` follows the reader's locale, so a Brazilian sees "44,1 kHz". The default
/// does not, because the same text goes into the log, and a log is for searching: an entry
/// reading "44,1 kHz" would not be found by anyone grepping for "44.1 kHz", and the same
/// machine would write it differently after a change of region.
func rateLabel(_ rate: Double, forDisplay: Bool = false) -> String {
    if rate.truncatingRemainder(dividingBy: 1000) == 0 { return "\(Int(rate / 1000)) kHz" }
    return forDisplay
        ? String(format: "%.1f kHz", locale: .current, rate / 1000)
        : String(format: "%.1f kHz", rate / 1000)
}

extension AudioStreamBasicDescription {
    var describedBriefly: String {
        let flags = mFormatFlags
        let kind = (flags & kAudioFormatFlagIsFloat) != 0 ? "float"
                 : (flags & kAudioFormatFlagIsSignedInteger) != 0 ? "int" : "uint"
        let packing = (flags & kAudioFormatFlagIsPacked) != 0 ? "packed" : "unpacked"
        let align = (flags & kAudioFormatFlagIsAlignedHigh) != 0 ? ", high-aligned" : ""
        return String(format: "%@ %d-bit %@ (%@%@) %dch",
                      rateLabel(mSampleRate), mBitsPerChannel, kind, packing, align, mChannelsPerFrame)
    }
}
