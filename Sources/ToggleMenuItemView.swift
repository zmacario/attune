import AppKit

/// A menu row that toggles a setting without dismissing the menu.
///
/// NSMenu closes as soon as an item is *selected*, and there is no flag to opt out. A
/// custom view takes the click itself, so the menu never sees a selection at all. The
/// cost is that a view-backed item loses everything a normal item gets for free — the
/// hover highlight, the checkmark column, the text colour while highlighted — so all of
/// that is drawn here to match.
final class ToggleMenuItemView: NSView {
    private static let rowHeight: CGFloat = 22
    private static let checkmarkX: CGFloat = 7
    private static let titleX: CGFloat = 24
    private static let trailingPadding: CGFloat = 24
    private static let highlightInset: CGFloat = 5

    private static var font: NSFont { .menuFont(ofSize: 0) }

    /// Menus size view-backed items independently, which leaves the rows ragged. Give
    /// every toggle the width of the widest one instead.
    static func width(for titles: [String]) -> CGFloat {
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return titleX + ceil(widest) + trailingPadding
    }

    private let isOn: () -> Bool
    private let action: () -> Void

    private let highlight = NSVisualEffectView()
    private let checkmark = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(title: String, width: CGFloat, isOn: @escaping () -> Bool, action: @escaping () -> Void) {
        self.isOn = isOn
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))

        // `.selection` is the material the menu itself uses, so this tracks the system
        // accent colour and both appearances without hard-coding a colour.
        highlight.material = .selection
        highlight.state = .active
        highlight.isEmphasized = true
        highlight.blendingMode = .behindWindow
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 4
        highlight.isHidden = true
        highlight.frame = NSRect(x: Self.highlightInset, y: 0,
                                 width: width - Self.highlightInset * 2, height: Self.rowHeight)
        highlight.autoresizingMask = [.width]
        addSubview(highlight)

        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let checkHeight = checkmark.image?.size.height ?? 13
        checkmark.frame = NSRect(x: Self.checkmarkX,
                                 y: ((Self.rowHeight - checkHeight) / 2).rounded(),
                                 width: 13, height: checkHeight)
        checkmark.imageScaling = .scaleNone
        addSubview(checkmark)

        label.font = Self.font
        label.stringValue = title
        label.usesSingleLineMode = true
        // Given the row's full height, NSTextField does not centre a single line inside
        // it — the text rides high against the highlight. Measure it and centre by hand.
        label.sizeToFit()
        label.frame = NSRect(x: Self.titleX,
                             y: ((Self.rowHeight - label.frame.height) / 2).rounded(),
                             width: width - Self.titleX - Self.trailingPadding,
                             height: label.frame.height)
        label.autoresizingMask = [.width]
        addSubview(label)

        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Re-reads the setting and repaints. Called after a click, and whenever the menu
    /// re-opens, so the row never shows a stale checkmark.
    func refresh() {
        let on = isOn()
        checkmark.isHidden = !on
        let highlighted = !highlight.isHidden
        let colour: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        label.textColor = colour
        checkmark.contentTintColor = colour
        setAccessibilityValue(on)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       // .activeAlways, not .activeInActiveApp: a status
                                       // menu opens without its app being frontmost, and
                                       // the highlight has to follow the mouse anyway.
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        highlight.isHidden = false
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        highlight.isHidden = true
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        action()
        refresh()
    }
}
