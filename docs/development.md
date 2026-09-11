# Working on it

The shape of the source, the tests, and the two things that are generated rather than
written.

[← back to the README](../README.md)

## Layout

| File | What it does |
|---|---|
| `Sources/AudioDevice.swift` | Wrapper over CoreAudio's HAL: enumerate outputs, read/write rate and physical format |
| `Sources/MusicBridge.swift` | Apple Events to Music: current track, path, volume, EQ |
| `Sources/Movpkg.swift` | MP4/HLS parser that reads the real rate of Apple Music downloads |
| `Sources/PlayerLog.swift` | Reads from the system log the format the player decoded |
| `Sources/TrackFormat.swift` | Brings the sources together and decides the track's rate |
| `Sources/Engine.swift` | Listens to `com.apple.Music.playerInfo` and applies the changes |
| `Sources/AppDelegate.swift` | The menu bar menu and its dialogs |
| `Sources/ToggleMenuItemView.swift` | The menu item that toggles without closing the menu |
| `Sources/Settings.swift` | The options, stored in `UserDefaults` |
| `Sources/Localization.swift` | The `localized()` that reads the language tables |
| `Sources/Log.swift` | os_log plus a ring buffer for *Show recent activity* |
| `Resources/Snapshot.applescript` | The query to Music, in its own file so the build can validate it |
| `Resources/*.lproj` | Interface text, one directory per language |
| `tools/make-icon.swift` | Draws the icon; `make-icon.sh` packages it with `iconutil` |
| `tools/check-localization.py` | Fails the build on a missing translation |
| `tools/test-switching.sh` | The full verification cycle: reinstall, skip tracks, check the DAC |
| `tools/test-locale-safety.sh` | Round-trips a cache entry through eight locales and compares the bytes |
| `tools/test-movpkg.sh` | Parses every real package, then a corpus of damaged ones, each in its own process |
| `tools/make-damaged-movpkg.py` | Builds that corpus: truncations, bit flips, noise, and hand-made broken boxes |
| `tools/test-cache.sh` | What the cache accepts, how it is keyed, and what it does under contention |
| `tools/test-player-log.sh` | Both log messages, parsed from verbatim captures, and the stand-down counter |
| `tools/test-layout.sh` | Renders a menu row per language and asserts which end the checkmark is on |
| `tools/test-soak.sh` | Samples footprint, threads and descriptors over hours, looking for a trend |
| `tools/create-signing-identity.sh` | Creates the certificate that preserves the permissions |
| `tools/make-social-preview.sh` | Draws the card GitHub shows when the repository is linked |

Two things worth knowing about the build:

There is no test runner; each of these is a script that exits non-zero. `check-localization.py`
is the only one the build runs, because it is the only one that costs nothing — the rest
compile a probe of their own.

Each was written against something that had already gone wrong, and each was then checked by
putting the defect back and watching it fail. That step matters more than it sounds:
`test-layout.sh` passed its first regression happily, because it asked the app which way the
interface read and then checked the checkmark was on that side — a tautology that agreed with
itself while the mirroring was broken. It now takes the expected side from the caller.

- `build.sh` runs `osacompile` over the AppleScript before packaging. It earns its keep:
  short variable names collide with Music's terminology (`st`, for one, does not compile
  inside a `tell` block), and without that check the error only appears at runtime,
  silently.
- Without a signing certificate, each rebuild produces a new ad-hoc signature and macOS asks
  for the Media & Apple Music permission again. See
  [Why rebuilding asks again](using.md#why-rebuilding-asks-for-the-permission-again).
- `build.sh --install` refuses to run while the app is open. Quit it from the menu first,
  or you will rebuild and carry on using the old copy without noticing.

## Why the menu is built the way it is

Three decisions that are invisible while they work.

**The toggles are custom views.** An `NSMenu` closes as soon as an item is selected and there
is no way to turn that off, so the six settings rows became their own views, absorbing the
click — the menu never sees a selection at all. The real actions are ordinary items and still
close.

**The main menu is never rebuilt while open.** A rebuild tears out the row under the pointer,
and the replacement starts unhighlighted, so the highlight vanishes until the mouse moves. The
header updates its text in place instead; text changes move nothing. The device submenu is the
exception, because a submenu has its own cycle — it is rebuilt from the same CoreAudio
notification that triggers the rerouting, so a DAC plugged in with the menu already open shows
up at once.

**The header is always three rows.** The fixed count is what makes updating in place possible:
any row that appeared or vanished would push the others up or down, and a toggle would slide
out from under the cursor mid-click.

## The icon

Drawn in code, in [tools/make-icon.swift](../tools/make-icon.swift), and packaged with
`iconutil`. There is no asset catalogue because `/usr/bin/actool` is a stub that needs full
Xcode — `iconutil`, which does the same job for icons, ships with the Command Line Tools.

To change the drawing, edit the Swift and rebuild: `build.sh` regenerates the `.icns` on its
own when the source is newer than it. Regeneration is conditional because it compiles a
second binary, and the icon changes far less often than the app.

```bash
./tools/make-icon.sh    # to regenerate without rebuilding the app
```

The glyph is the same SF Symbol the menu bar uses, deliberately: the Dock icon and the menu
bar one then read as the same app.

**The menu bar icon has two versions**, and the difference between them is not obvious. The
normal one is a template image, which macOS paints itself to follow light or dark mode. The
warning one is **not** a template, with the orange baked into the image — because the menu
bar draws template images monochrome and ignores `contentTintColor`. Trying to tint the
normal version has no effect whatsoever.

### Adding a language

Copy `Resources/en.lproj` to `Resources/<code>.lproj`, translate the two `.strings` files,
and add the code to `CFBundleLocalizations` in `Info.plist`. `build.sh` runs
`tools/check-localization.py`, which fails the build if a key used in the code is missing
from any language — without it, a forgotten translation would appear in the menu as the key
itself (`menu.quit`), with no error at all.
