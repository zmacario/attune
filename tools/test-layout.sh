#!/bin/bash
# Which side of the row the checkmark lands on.
#
# The menu rows are custom views, drawn to absorb their own clicks, so they inherit none of
# AppKit's automatic mirroring: every position is measured by hand and has to be reflected
# by hand. That reflection shipped once looking correct and doing nothing, because it asked
# NSApp.userInterfaceLayoutDirection, which for an app with no windows answers left-to-right
# whatever the localization says.
#
# So this asserts on pixels rather than on a flag. It renders a row into a bundle carrying
# the language under test and looks at which end the ink is.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/LayoutProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Every language, so a case asking for one the bundle lacks cannot fall back to English
# and quietly report a pass for the wrong thing.
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.macario.layoutprobe</string>
  <key>CFBundleName</key><string>LayoutProbe</string>
  <key>CFBundleExecutable</key><string>LayoutProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>LANGUAGE_LIST</array>
</dict></plist>
PLIST
# The plist has to name them too, or the bundle resolves only the development region.
languages=""
for lproj in Resources/*.lproj; do
    code="$(basename "$lproj" .lproj)"
    languages="$languages<string>$code</string>"
done
/usr/bin/sed -i '' "s|LANGUAGE_LIST|$languages|" "$APP/Contents/Info.plist"

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// A command-line process inherits the dark appearance, where labelColor is white — which
// renders correct layout as a blank page.
app.appearance = NSAppearance(named: .aqua)

let title = localized("menu.route")
let width = ToggleMenuItemView.width(for: [title])
let height: CGFloat = 22

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.backgroundColor = .white
let row = ToggleMenuItemView(title: title, width: width, isOn: { true }, action: {})
window.contentView = row
window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
window.orderFrontRegardless()
row.layoutSubtreeIfNeeded()
row.display()

// dataWithPDF drives drawRect through the hierarchy; cacheDisplay alone leaves a window
// that was never ordered in blank. The PDF has no background of its own, and converting
// transparency straight to a bitmap reads as black — which makes every pixel look like
// ink — so it is composited onto white first.
guard let drawn = NSImage(data: row.dataWithPDF(inside: row.bounds)) else {
    print("could not render"); exit(1)
}
let page = NSImage(size: drawn.size)
page.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: drawn.size).fill()
drawn.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
page.unlockFocus()
guard let tiff = page.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
    print("could not compose"); exit(1)
}

/// True when any pixel in the column range is darker than the white ground.
func hasInk(from x: Int, to endX: Int) -> Bool {
    for px in x..<endX where px >= 0 && px < bitmap.pixelsWide {
        for py in 0..<bitmap.pixelsHigh {
            if let colour = bitmap.colorAt(x: px, y: py), colour.brightnessComponent < 0.6 {
                return true
            }
        }
    }
    return false
}

let band = Int(Double(bitmap.pixelsWide) / Double(width) * 23)   // the checkmark's column
let leading = hasInk(from: 0, to: band)
let trailing = hasInk(from: bitmap.pixelsWide - band, to: bitmap.pixelsWide)

let language = Bundle.main.preferredLocalizations.first ?? "?"

// The expectation comes from the caller, which knows Arabic reads right to left, and never
// from interfaceIsRightToLeft. Asserting against the app's own belief about the language
// is a tautology: it passed happily while the mirroring was broken, because the same
// wrong answer decided both where the checkmark went and where it was looked for.
let wantTrailing = ProcessInfo.processInfo.environment["LAYOUT_EXPECT"] == "trailing"
let ok = wantTrailing ? (trailing && !leading) : (leading && !trailing)
print("  \(ok ? "ok  " : "FAIL") \(language): expected the checkmark \(wantTrailing ? "trailing" : "leading")"
      + ", ink leading=\(leading) trailing=\(trailing)"
      + (ok ? "" : "  [app thinks rtl=\(interfaceIsRightToLeft)]"))

if let out = ProcessInfo.processInfo.environment["LAYOUT_PNG_DIR"],
   let png = bitmap.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "\(out)/row-\(language).png"))
}
exit(ok ? 0 : 1)
SWIFT

swiftc -O -o "$APP/Contents/MacOS/LayoutProbe" "$WORK/main.swift" \
    Sources/ToggleMenuItemView.swift Sources/Localization.swift

# Language, and the side the checkmark belongs on in it. Stated here, by a caller that
# knows how these scripts read, rather than asked of the code under test.
failed=0
for pair in "en leading" "ar trailing" "he trailing" "fr leading"; do
    set -- $pair
    [ -d "Resources/$1.lproj" ] || continue
    LAYOUT_EXPECT="$2" "$APP/Contents/MacOS/LayoutProbe" -AppleLanguages "($1)" || failed=1
done
[ "$failed" -eq 0 ] && echo "layout mirrors correctly" || { echo "layout FAILED" >&2; exit 1; }
