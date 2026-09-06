import AppKit

/// An informational menu row of fixed width, which scrolls its text back and forth when
/// the text is too long to fit.
///
/// Plain menu items size themselves to their text, so a long track title stretched the
/// whole menu and every row jumped width as tracks changed. A view reports the width it
/// is given and clips the rest.
final class ScrollingLabelMenuItemView: NSView {
    private static let horizontalInset: CGFloat = 14
    private static let speed: CGFloat = 25          // points per second
    private static let pauseAtEnds: TimeInterval = 1.5
    private static let frameInterval: TimeInterval = 1.0 / 30

    private var text = NSAttributedString(string: "")
    private var textWidth: CGFloat = 0
    private var startedAt = Date()
    private var timer: Timer?

    init(width: CGFloat, font: NSFont) {
        super.init(frame: NSRect(x: 0, y: 0, width: width,
                                 height: ceil(font.boundingRectForFont.height) + 4))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var attributedText: NSAttributedString {
        get { text }
        set {
            guard newValue != text else { return }   // avoid restarting the scroll for nothing
            text = newValue
            textWidth = ceil(newValue.size().width)
            startedAt = Date()
            updateTimer()
            needsDisplay = true
        }
    }

    private var available: CGFloat { bounds.width - Self.horizontalInset * 2 }
    private var overflow: CGFloat { max(0, textWidth - available) }

    // MARK: Animation

    /// Menus run their own event-tracking run loop mode, in which a timer scheduled the
    /// usual way never fires. `.common` covers that mode as well as the default one.
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard overflow > 0, window != nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startedAt = Date()
        updateTimer()          // stops itself when the menu closes and the window goes away
    }

    /// Ping-pong: pause, travel, pause, travel back. Derived from elapsed time rather than
    /// stepped, so a dropped frame cannot leave the offset drifting.
    private var offset: CGFloat {
        let distance = overflow
        guard distance > 0 else { return 0 }
        let travel = TimeInterval(distance / Self.speed)
        let cycle = (Self.pauseAtEnds + travel) * 2
        let t = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: cycle)

        switch t {
        case ..<Self.pauseAtEnds:
            return 0
        case ..<(Self.pauseAtEnds + travel):
            return CGFloat(t - Self.pauseAtEnds) * Self.speed
        case ..<(Self.pauseAtEnds * 2 + travel):
            return distance
        default:
            return distance - CGFloat(t - Self.pauseAtEnds * 2 - travel) * Self.speed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSRect(x: Self.horizontalInset, y: 0, width: available, height: bounds.height)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.clip()
        let size = text.size()
        // Right to left the row reads from the other edge, and the scroll runs the other
        // way with it: the text sits flush against the trailing inset and travels right,
        // uncovering its far end exactly as the left-to-right case uncovers its own.
        let x = NSApp.userInterfaceLayoutDirection == .rightToLeft
            ? bounds.width - Self.horizontalInset - size.width + offset
            : Self.horizontalInset - offset
        text.draw(at: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()))
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
