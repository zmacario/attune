import AppKit
// GitHub's social preview is 1280x640, shown small and often cropped, so it has to work as
// a shape rather than as a page: the menu on the right, three lines on the left.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let size = NSSize(width: 1280, height: 640)
let image = NSImage(size: size)
image.lockFocus()

NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.098, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// The menu bar icon's orange, so the card and the app read as the same thing.
let accent = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.16, alpha: 1)

func draw(_ text: String, _ font: NSFont, _ colour: NSColor, at point: NSPoint) {
    (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: colour])
}
draw("Attune", .systemFont(ofSize: 76, weight: .bold), .white, at: NSPoint(x: 80, y: 430))
draw("Keeps your DAC on the native sample rate", .systemFont(ofSize: 30, weight: .regular),
     NSColor(white: 0.82, alpha: 1), at: NSPoint(x: 80, y: 360))
draw("of whatever Apple Music is playing.", .systemFont(ofSize: 30, weight: .regular),
     NSColor(white: 0.82, alpha: 1), at: NSPoint(x: 80, y: 318))
draw("44.1 · 48 · 96 · 192 kHz, per track, automatically",
     .monospacedSystemFont(ofSize: 22, weight: .medium), accent, at: NSPoint(x: 80, y: 232))

if let menu = NSImage(contentsOfFile: "docs/images/menu.png") {
    // Bled off the right and bottom edges: cropped previews then still show a menu rather
    // than a margin.
    let height: CGFloat = 620
    let width = height * menu.size.width / menu.size.height
    menu.draw(in: NSRect(x: 1280 - width + 90, y: -40, width: width, height: height),
              from: .zero, operation: .sourceOver, fraction: 1)
}
image.unlockFocus()

try! NSBitmapImageRep(data: image.tiffRepresentation!)!
    .representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
print("  social-preview.png 1280x640")
