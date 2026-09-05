// Draws the app icon and writes AppIcon.icns. Run via tools/make-icon.sh.
//
// No asset catalog here: /usr/bin/actool is a stub that needs full Xcode. iconutil,
// which does the same job for icons, ships with the Command Line Tools.
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let canvas = 1024

/// Apple's rounded-square silhouette: the art sits inside a margin, and the corner
/// radius is a fixed fraction of the shape rather than of the full canvas.
let margin = CGFloat(canvas) * 0.09
let body = CGRect(x: margin, y: margin,
                  width: CGFloat(canvas) - margin * 2,
                  height: CGFloat(canvas) - margin * 2)
let cornerRadius = body.width * 0.225

func drawIcon(into context: CGContext) {
    context.setShouldAntialias(true)

    let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)
    context.saveGState()
    shape.addClip()

    // A deep blue-black, so the waveform reads at 16pt as well as at full size.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.09, green: 0.13, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.04, blue: 0.08, alpha: 1),
    ])
    gradient?.draw(in: body, angle: -90)

    // A soft highlight along the top edge keeps it from looking flat.
    let highlight = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.16),
        NSColor(white: 1, alpha: 0),
    ])
    highlight?.draw(in: CGRect(x: body.minX, y: body.midY,
                               width: body.width, height: body.height / 2), angle: -90)
    context.restoreGState()

    // The same glyph the menu bar uses, so the two read as one app.
    let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.52, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return }

    let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.29, alpha: 1)
    let size = symbol.size
    let rect = CGRect(x: body.midX - size.width / 2,
                      y: body.midY - size.height / 2,
                      width: size.width, height: size.height)

    let tinted = NSImage(size: size)
    tinted.lockFocus()
    amber.set()
    CGRect(origin: .zero, size: size).fill()
    symbol.draw(at: .zero, from: CGRect(origin: .zero, size: size),
                operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()
    tinted.draw(in: rect)
}

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / CGFloat(canvas)
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(into: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// The names iconutil expects inside a .iconset directory.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let png = render(size: variant.pixels) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(variant.name).png")
    try? png.write(to: url)
}
print("wrote \(variants.count) sizes to \(outputDirectory)")
