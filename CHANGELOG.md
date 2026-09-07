# Changelog

Newest first. Each released version is a tag on `main`; the wording is the tag's own.

## Unreleased

**Twelve languages.** English, the five most spoken in the world by total speakers
(Mandarin, Hindi, Spanish, Arabic, French), the five largest in Europe those did not cover
(Russian, German, Italian, Polish, Ukrainian), and Portuguese. Arabic reads right to left,
and the menu rows are custom views that inherit no automatic mirroring, so they now reflect
by hand. Rates follow the reader too — `44,1 kHz` where that is the convention — while log
lines deliberately do not, so a search for `44.1 kHz` keeps finding them.

**The `.movpkg` parser no longer crashes on a broken download.** A `mdhd` box declaring
size 8 carries no payload, and the version byte inside it was read without a bounds check; a
64-bit box size above `Int.max` trapped on conversion rather than being rejected. Neither
needs an attacker — a half-written download is an ordinary thing to find on disk.

**Music's own log line is read as a reserve** when CoreMedia's says nothing. The two are
published by different things and move independently, so one changing shape need not take
the other with it.

**A dead log reader stands itself down on any library.** The counter that noticed only
advanced on streamed tracks, so a library of downloads could never trip it. A track is now
judged when it ends, which is the only fair moment to ask.

**Documentation in English, and an MIT license**, in preparation for the repository being
public. What the app costs to run, the machine every measurement came from, how it compares
to the apps that already existed, and why shuffle cannot be supported.

**Tests kept rather than thrown away**: what the cache accepts and how it is keyed, both log
messages parsed from verbatim captures, which end of a menu row the checkmark lands on, the
`.movpkg` parser against 334 damaged inputs, and a soak that samples footprint, threads and
descriptors over hours.

## v1.4 — 6 September 2026

The format cache is keyed on the track itself rather than its name, so two recordings
sharing a title and an artist no longer share an entry. What was learned before is preferred
to what would be guessed now. A plain audio file's format is remembered too, which is the
only way an imported library can be prepared ahead — the player's log says nothing about
local files.

Documents what the app costs to run, the machine every measurement came from, how it
compares to the apps that already existed, and why shuffle cannot be supported.

## v1.3 — 6 September 2026

The format cache lives in memory and holds up to 50000 tracks. The next track's sample rate
is set before it starts, so the silence a rate change costs falls in the tail of the track
ending instead of the new track's first note.

## v1.2 — 5 September 2026

Reads the player's log for every track, not only streamed ones, which removed the Dolby
Atmos setting rather than clarifying it: reading a `.movpkg` shows an Atmos variant exists,
not that Music chose it, and the log says which one was decoded.

A track heard before is applied straight from the notification — 1 ms after it rather than
330, since resolving was never the slow part. The pause on a rate change now starts at the
edge of the song rather than inside it.

The device list follows the hardware while the menu is open, and a DAC plugged in or
unplugged changes it at once.

`tools/test-switching.sh` asks the app which device it is steering instead of naming one.
All three false negatives this harness produced came from the test presuming something the
app decides.

## v1.1 — 5 September 2026

Streamed tracks get their real format. A stream has no file to inspect and Music reports its
rate as zero, so every one used to be pinned to a guessed 44.1 kHz; CoreMedia logs the
variant its player actually decoded, and the app reads that live. Verified on hardware at
44.1, 48, 96 and 192 kHz, up and down.

Works with any wired DAC rather than one in particular, choosing by three rules — the device
last chosen in the app, otherwise the most recently connected DAC, otherwise the built-in
speakers — and reacting to devices arriving and leaving as it happens.

The menu no longer closes when a setting is toggled, its header updates in place while open,
and a warning marks the item that resolves it. Interface in English and Portuguese, and an
icon.

`tools/test-switching.sh` drives a full verification cycle unattended.

## v1.0 — 5 September 2026

Keeps a wired DAC on the native sample rate of whatever Music is playing, so CoreAudio has
nothing to resample.

Reads the rate exactly from Apple Music downloads by parsing the MP4 init segment of each
HLS variant inside the `.movpkg` — Music reports zero for these — and picks the variant it
will actually play. Verified across a library spanning 44.1 to 192 kHz.

Chooses its device by three rules: the one last chosen in the app if connected, otherwise
the most recently connected DAC, otherwise the built-in speakers. Reacts to devices arriving
and leaving as it happens.

Interface in English and Portuguese. Signed with a self-signed certificate so rebuilding
keeps the permissions granted to it.
