import Foundation
import os

/// os_log for `log stream`, plus a small ring buffer so the menu can show what just happened
/// without anyone having to open Console.
enum Log {
    static let subsystem = "com.macario.bitperfectdx"
    private static let logger = Logger(subsystem: subsystem, category: "engine")
    private static let lock = NSLock()
    private static var ring: [String] = []
    private static let capacity = 60

    static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let stamped = "\(timestamp())  \(message)"
        lock.lock()
        ring.append(stamped)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        lock.unlock()
    }

    /// Times a step and logs it only when it is slow enough to matter.
    static func timed<T>(_ label: String, threshold: TimeInterval = 0.05, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= threshold { write("\(label) took \(Int(elapsed * 1000))ms") }
        }
        return try body()
    }

    static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
