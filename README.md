# Attune

A macOS menu bar app. When **Music** starts playing, it sends the audio to your DAC and puts
the DAC on the **track's own sample rate**, so macOS resamples nothing on the way.

Without it the DAC sits at one rate — usually whatever someone last set — and everything
else goes through CoreAudio's sample rate converter before it gets there.

Works with any wired DAC. It was written against a Topping DX3 Pro+, which turns up as an
example here and there, but nothing in the code knows about that device.

## Requirements

| | |
|---|---|
| macOS | 13 or later (it uses `SMAppService`) |
| Xcode Command Line Tools | `xcode-select --install` — full Xcode is not needed |
| A wired DAC | USB, Thunderbolt or FireWire. See [Which DAC it uses](#which-dac-it-uses) |
| Apple Music | The app follows Music, and does not play anything itself |

Nothing else. There is no Xcode project, no package manager, and no dependencies beyond the
system frameworks.

## Installing

There is no download. Build it yourself — four commands:

```bash
git clone https://github.com/zmacario/Attune.git
cd Attune
./tools/create-signing-identity.sh
./build.sh --install
```

Then open Attune from `/Applications` **in Finder**, and tick *Launch at login* in its menu.

A wave icon appears in the menu bar with the current rate beside it (`44.1k`, `96k`…). It
turns **orange** when something is spoiling bit-perfect playback, so you do not have to open
the menu just to check.

**Why build instead of download.** A downloaded app has to be notarized by Apple to open
without a fight, and notarization needs a paid Developer ID. An app you compiled on your own
machine is never quarantined, so none of that applies. It also means you can read what you
are about to run.

**Why the signing identity.** That script creates a self-signed certificate named
`Attune Local` in your keychain. It is optional — skip it and the build signs ad-hoc — but
without it macOS treats every rebuild as a brand new app and asks for the Media & Apple Music
permission again each time. See
[Why rebuilding asks again](#why-rebuilding-asks-for-the-permission-again). The script changes
keychain trust settings, so it will ask for your approval.

To build without installing:

```bash
./build.sh && open "build/Attune.app"
```

`--install` refuses to run while the app is open — quit it from the menu first, or you will
rebuild and carry on using the old copy.

## Permissions

On first run macOS asks for two things. Both are needed:

| Permission | What for | If you refuse |
|---|---|---|
| **Automation → Music** | Asking Music what is playing, and pausing/resuming across a rate change | The app cannot tell what is playing; an orange warning appears in the menu |
| **Media & Apple Music** | Reading the track's `.movpkg` to find its real rate | Falls back to guessing the rate |

The second is easy to miss, because the app asks for it on a background thread right at
launch — if the app seems to sit there doing nothing, there is almost certainly a dialog
waiting for an answer. Both live in **System Settings → Privacy & Security**.

**Open the app from Finder**, not from a terminal or a script. macOS attributes permissions
to the process that launched the app, so launching it from another program files the decision
under that program's name and muddles the dialog.

### Why rebuilding asks for the permission again

Ad-hoc signing (`codesign --sign -`) produces a designated requirement like this:

```
designated => cdhash H"edc7fe90…"
```

That hash is the binary's own. Change one line of code and it changes, so every rebuild is a
new app as far as macOS is concerned, and the **Media & Apple Music** permission is asked for
again. **Automation** escapes it, because TCC files client→target pairs by bundle identifier
rather than by hash.

To stop it, sign with a self-signed certificate — the requirement then anchors to the
certificate, which does not change:

```bash
./tools/create-signing-identity.sh
```

`build.sh` finds the certificate by the name `Attune Local` and uses it on its own; without
one it says in the terminal that it signed ad-hoc. You can point it at another with
`CODESIGN_IDENTITY="name" ./build.sh`.

The requirement becomes:

```
designated => identifier "com.macario.attune"
              and certificate leaf = H"b87be2ba…"
```

No cdhash. Verified in practice: rebuilding with a changed binary (different cdhash) and
relaunching produced **no** new `kTCCServiceMediaLibrary` prompt at all, against 7 across the
earlier ad-hoc rebuilds.

**If the script fails at `security import`** with "MAC verification failed": macOS ships
LibreSSL as `openssl`, and it and `security` disagree about how an empty password is encoded
in a PKCS#12 file's MAC. That is why the script generates a random throwaway password instead
of using an empty one — it only carries the private key from openssl to the keychain, and
disappears with the temporary directory.

**If it fails at `add-trusted-cert`**, which alters trust settings and asks for your
approval, you can do it through the interface instead: **Keychain Access → Certificate
Assistant → Create a Certificate**, name `Attune Local`, type *Code Signing*, self-signed.
The name has to match exactly.

## What it does for each track

1. If the system output is not the DAC, it switches.
2. It works out the track's own rate (details below).
3. It sets the DAC to that rate and raises the wire format to the deepest the device offers.
   Raising depth never makes anything worse: the extra bits arrive as zeros in the least
   significant positions.
4. It warns you if Music's internal volume or its equaliser are spoiling the result.

With *Pause during rate changes* on (the default), it pauses, reconfigures, and resumes where
it left off. Worth it, measured: without the pause, Music keeps running while the DAC
relocks, and the player position advances by exactly the wall clock — **~0.74 s of the music
is skipped** on every change. The pause costs ~0.12 s more silence and loses nothing. The two
sound alike precisely because they last about as long; only one of them keeps the music
whole.

### Setting the next track's rate in advance

On by default. It addresses one specific annoyance: the rate change lands **in the new
track's first second**.

The cause is that nobody can act sooner. Music's notification arrives once the new track is
already playing; from there it is ~0.39 s of Apple Event for the pause and **730 ms of DAC
relock** — a fixed cost, measured across 30 changes in one session at between 724 and 740 ms,
the same in every direction (44.1↔48, 44.1↔96, 48↔96). No setting shortens that.

But the cache knows a track's format without playing it, and Music says which track is next
and how long is left in the current one. With that, the app can change the rate **before the
current track ends**: when the next one starts the DAC is already right, and it logs
`already at 96 kHz, nothing to do` — the new track comes in clean from its first note.

It does not remove the silence, it **moves** it: out of the new track's opening and into the
tail of the one ending, where it interrupts something already heard. No audio is lost,
because the pause preserves everything. In exchange, the last ~2.5 s of the ending track play
resampled, already at the next one's rate. That 2.5 s margin is not arbitrary: the pause
Apple Event has taken anywhere from 77 to 439 ms, and a change that slipped past the boundary
would land in exactly the place this feature exists to avoid.

It only acts when **everything** is known, and does nothing when any piece is missing:

| condition | why |
|---|---|
| *Pause during rate changes* on | the pause is what makes this cost no audio |
| shuffle off | shuffled, the next track by index is not what plays ([why](#why-shuffle-cannot-be-supported)) |
| the next track is identifiable | radio and other sources have no playlist |
| its format is already cached | a track never heard has nothing to prepare |
| more than 2.5 s left | too late to prepare |

If the track changes before the appointed time — you skipped, or Music ran ahead — the
preparation stands down without doing anything
(`pre-switch: track already changed, standing down`).

#### Why shuffle cannot be supported

Music **does not announce** the next track. It exposes the playlist and the current track's
index, and the app adds one — a deduction from list order, not a notice. Shuffled, that
index + 1 still exists and still answers; it just is not what will play.

The real queue, the *Up Next* one, **does not exist for scripts**. Music's terminology
(`com.apple.Music.sdef`) contains no mention of *up next* at all, and the application's
property list is explicit about what there is:

```
current playlist    playlist     ← the list, in order
current track       track
shuffle enabled     boolean      ← says WHETHER it is shuffled
shuffle mode        eShM
song repeat         eRpt
```

It reports **that** it is shuffled, never **what** comes next. So this is not work waiting to
be done: the information is not exposed. Shuffled, the feature lies inert and the change goes
back to happening at the start of the new track — everything else in the app carries on
unchanged.

For the same reason, the deduction follows **list** order, not playback order. Re-sorting the
playlist view while it plays can make `index + 1` stop being what comes next. Nothing breaks
if it does: the new track starts, the ordinary path detects the real rate and corrects — one
worse transition, with the usual gap plus an extra silence in the previous tail, and the next
one is back to normal.

Two traps cost a version each, and both are recorded in the code as comments:

**The preparation undid itself.** Its own `play()` makes Music emit a notification, and the
track that notification names is still the one ending. The app looked, saw the DAC on the
"wrong" rate and put it back — three changes instead of one, worse than not having the
feature. It now holds the prepared setting until the track really turns over
(`holding the rate prepared for the next track`).

**The timer never fired.** This is a menu bar app with no windows, and the deferral macOS
applies to apps in that state swallowed an `asyncAfter` whole: it did not run at the
appointed time and ended up executing inside a pause the ordinary path had already begun. It
is now a strict `DispatchSource` with 50 ms of leeway, plus a `beginActivity` while a
preparation is pending. Measured afterwards: fired 9 and 33 ms late.

Measured on the pair that prompted all of it, *Mystical Magical* (44.1) → *In The Light Of
Day* (96):

| | before | with the feature |
|---|---|---|
| rate changes | 1, at the start of the new track | 1, at the end of the previous |
| silence | 0.85 s on the first note | 0.89 s, 2.4 s before the boundary |
| start of the new track | interrupted | intact |

## The menu

```
DX3 Pro+ · 96 kHz                                    ← device and current rate
Wire: 96 kHz 32-bit int (packed) 2ch                 ← what goes out on the wire
▶ Seven Nation Army — The White Stripes · 24-bit / 192 kHz (download)
─────────────────────────────────────────
☑ Route Music to this device
☑ Match the track's sample rate                      ← clicking does not close the menu
☑ Use the deepest bit format
☑ Pause during rate changes
☑ Set the next track's rate in advance
☐ Restore previous output when Music stops
─────────────────────────────────────────
Output device                                     ▸   ← DACs in a group, updated live
When the rate is unknown                          ▸
─────────────────────────────────────────
Re-apply now
⚠️ Check bit-perfect setup…                          ← the ⚠️ appears only when there is something to fix
Show recent activity…
Open Audio MIDI Setup
─────────────────────────────────────────
☑ Launch at login
Quit
```

Four behaviours that are not obvious from looking:

**The toggles do not close the menu.** An `NSMenu` closes as soon as an item is selected and
there is no way to turn that off, so the six of them became their own views, absorbing the
click — the menu never sees a selection at all. You can set everything in one visit. The real
actions (*Re-apply now*, *Check bit-perfect setup…*, *Quit*) still close, as expected.

**The device list follows the hardware.** Plugging or unplugging a DAC changes the submenu
immediately, even with the menu already open — it is rebuilt from the same CoreAudio
notification that triggers the rerouting. The main menu is still never rebuilt while open,
because that would tear out the row under the pointer; a submenu has its own cycle.

**The header is always three rows, and updates with the menu open.** The fixed count is what
makes updating in place possible: any row that appeared or vanished would push the others up
or down, and a toggle would slide out from under your cursor mid-click. Leave the menu open
across a track change and watch the three rows change with nothing moving.

**The warning lives in the item that resolves it.** Music's internal volume away from 100% or
the equaliser switched on mark *Check bit-perfect setup…* with a ⚠️ and turn the menu bar icon
orange. The detail is in the report, one click away — more informative than a summary line,
and the header stays purely factual.

Music's volume and EQ change without notifying anyone — see
[Periodic checking](#periodic-checking) below.

## Which DAC it uses

Three rules, in this order:

1. **The device last chosen in the app's menu**, if it is connected.
2. Otherwise, **the most recently connected DAC**.
3. Otherwise, **the built-in speakers**.

The saved device is a preference that breaks ties, not a target the app waits for: unplug it
and another DAC takes over on its own. That is why the tick in the submenu marks the device
**in use** rather than the saved one — the two diverge exactly when the preferred one is away
and another has taken over.

### What counts as a DAC

USB, Thunderbolt and FireWire. Bluetooth and AirPlay are excluded because they resample on
their own and cannot be bit-perfect. DisplayPort and HDMI are excluded from automatic
adoption too — they are wired and they carry digital audio, but they are a monitor or a TV,
not something for the app to adopt unasked. They remain choosable by hand, and a manual
choice applies to any output.

### Connection order

CoreAudio does not report how long a device has been attached, so the app keeps its own
record: a UID that appears where it was not is stamped with the time, and one that vanishes
is forgotten — unplug and replug counts as new. It is stored in the preferences, so the order
survives a relaunch with everything still connected. Devices already present on the first run
tie, and are separated by name so they do not swap places between runs.

### Plugging and unplugging

The app listens on `kAudioHardwarePropertyDevices` and reroutes after 0.3 s — the pause is to
let the HAL settle before asking what is left. It works both ways: unplugging the DAC that is
playing sends the audio to the next one rather than leaving it on the speakers, and plugging
a new DAC in brings it into play at once.

This is **not** the same as the periodic check below. That one updates what the menu shows;
it never reroutes anything. Treating the two as one problem is what left hot-plug unanswered
for a while.

## Periodic checking

The app reacts to `com.apple.Music.playerInfo`, which Music publishes on track change, pause
and resume. But **internal volume and the equaliser publish nothing** — changing either is
invisible to any app outside Music. Without checking now and then, the warning would only
appear when the setting happened to be wrong at the instant a track started, which is exactly
when you do not need it.

So a timer re-reads those two things:

| | |
|---|---|
| Interval | 15 seconds |
| Leeway | 5 seconds, so macOS can group the wakeup with others it would make anyway |
| With Music closed | sends no Apple Event at all; the process check is local |
| Measured cost | 0.0% CPU, and nothing added to the log |

Two decisions keep this from becoming waste. `EngineStatus` is comparable and `publish()`
discards identical updates — otherwise the menu would be rewritten every 15 seconds with
nothing having changed. And the two menu bar images are built once, not on every evaluation.

To change the interval, `pollInterval` and `pollLeeway` are in
[Engine.swift](Sources/Engine.swift).

## Launch at login

The **Launch at login** item registers the app through `SMAppService` (macOS 13+). What makes
this less trivial than it looks is that `SMAppService` has **four** states, not two:

| State | What the menu shows |
|---|---|
| `.enabled` | "Launch at login", ticked |
| `.requiresApproval` | "Launch at login (approve in System Settings…)" — clicking opens the panel |
| `.notRegistered` | normal; clicking registers |
| `.notFound` | disabled, with a hint to move the app to `/Applications` |

The deceptive case is `.requiresApproval`: macOS accepts the registration but requires you to
confirm it in **System Settings → General → Login Items**. Treating that as "off" — which was
the original behaviour — produced an unticked box that, when clicked, called `register()`
again and changed nothing visible. In that state the click now opens the panel instead of
repeating a registration that already succeeded.

If you register the app through System Settings rather than the menu, the menu sees it and
shows it ticked — it is the same registration.

A trap for anyone working on the code: **`SMAppService.status` blocks indefinitely** when read
outside a properly launched app, and was seen hanging that way during development. That is
why it is read in the background and the menu draws a cached value, rather than consulting it
while building the items.

## How it finds the rate

In order of preference:

| Source | Accuracy | When |
|---|---|---|
| Remembered | exact | A track heard before — applied before asking anything |
| Player log | exact | **Every** track — see below |
| Audio file | exact | AIFF, WAV, ALAC, MP3… in your library |
| `.movpkg` | exact | **Downloaded** Apple Music tracks |
| Music's metadata | approximate | When the catalogue carries a `sample rate` |
| Configurable fallback | a guess | Streaming when the log does not answer |

The interesting case is the `.movpkg`. An Apple Music download is not an audio file: it is an
HLS package with **several variants of the same track**, each with its own rate — stereo AAC,
lossless ALAC and, sometimes, Dolby Atmos. One track can hold AAC at 44.1 kHz and Atmos at
48 kHz inside the same package.

The app opens each variant's MP4 initialisation segment and reads the real rate from the
`mdhd` box's `timescale` field, the codec from the `frma` box, and the bit depth from the
ALAC magic cookie. Then it picks which variant Music will play:

- **Atmos** variants (`ec-3`) are ignored outright. Reading the package shows that an Atmos
  variant exists, but not whether Music chose it — and that used to be a manual setting in
  the menu, which asked you about a setting inside Music and failed silently when answered
  wrong. The player log says which variant was decoded, so the guess was deleted along with
  the toggle;
- among the stereo ones, it picks **ALAC** if Lossless is enabled in Music (it reads
  `losslessEnabled`), otherwise the highest-bitrate AAC.

To see what is inside a track:

```bash
"build/Attune.app/Contents/MacOS/Attune" --inspect ~/Music/Music/Media.localized/...
```

### Remembering what has been heard

Where the time goes, measured: resolving costs **3 ms**; the other ~330 are the
quarter-second debounce and the Apple Event that asks Music what is playing. A cache
consulted after that would save nothing.

But Music's notification **already carries the track**. So a track heard before is applied
straight from it, without asking anything — measured at **1 ms** after the notification,
against ~330. That is the difference between the pause starting inside the music or at its
edge.

Only exact readings are stored. Caching a guess would apply it instantly on every later play,
which is worse than guessing once. The player is one exact source; a plain audio file is
another, since it holds one format read from the container itself. A `.movpkg` is not — it
carries several variants and reading it cannot tell which one Music picked, which is where
Atmos lives. Music's own metadata and the fallback are guesses outright.

Local files matter here because **the player's log says nothing about them** — measured, not
assumed. Without storing file readings, a library of imported music would never fill the
cache, and the pre-switch, which needs a cached format to prepare, would never arm for one.

**What was learned before beats what would be guessed now.** A cache entry is a reading some
exact source made on an earlier play, so falling through to the configured fallback would
throw a measurement away in favour of an invention. It was caught doing exactly that: the
cache had put the device on 48 kHz, the fallback pulled it to 44.1, and the player arrived
two seconds later to put it back — three rate changes where none were due. A plain file still
wins over the cache, being read from the track playing now, so it also catches a file
replaced since.

**Entries are keyed on the track, not on its name.** Name and artist do not identify a
recording: a library can hold the download and the stream of one song, or the album version
and the single, under identical text and in different formats. The library this was written
against holds 37 such pairs across 75 tracks, and one of them was already sharing a cache
entry — two "In The Light Of Day" by Lonesome Joy, the download at 96 kHz/24-bit and the
stream at 48, with one stored value serving both.

Music hands out something better. The playerInfo notification carries `PersistentID` and
AppleScript carries `persistent ID` — the same 64 bits, spelled signed-decimal in one and hex
in the other, so both paths agree on one key. Verified before relying on it: 577 tracks, 577
distinct ids; the same track gave the same id on its second and fourth play; and the
colliding pair came out distinct. Anything Music will not name — a catalogue track never
added to the library — falls back to the old name-and-artist key.

This is also what keeps the cache honest when Apple changes a track's format: on the first
play after the change the old value is applied at once and the player corrects ~1.5 s later —
two transitions on that play, one on the ones after, because the entry is rewritten. Playing
a track whose format has not changed writes nothing at all.

The dictionary is held **in memory**, loaded once at startup, off the main thread. Bridging
the stored dictionary walks every entry — 2 ms at 4,000, 53 ms at 50,000 — and the lookup
happens on the main thread, from Music's notification; re-reading it per track would spend
exactly the millisecond the cache exists to save. Loaded once, a lookup is flat at any size.
The 50,000-entry ceiling is there so the plist cannot grow without bound, not to expire
anything: crossing it clears the cache entirely, and a library that size is not a real one.

A side effect of living in memory: clearing the cache from outside
(`defaults delete com.macario.attune formatCache`) only takes effect with the app **closed** —
with it open, it writes back what it holds.

### Reading the player's log

A streamed track has no file to inspect, and Music reports its rate as zero. Without this the
app would guess 44.1 kHz for all of them — silently halving a 96 kHz stream.

The log is consulted for **every** track, not only streamed ones. It is the only source that
knows which variant Music actually chose, Dolby Atmos included — reading the `.movpkg` sees
that an Atmos variant exists, not that it is playing. A download does not wait for it: if the
log has not answered yet it resolves from the file at once, and a later reading corrects it
inside the settling window. In practice the log usually arrives first — across a three-hour
session, all 13 resolutions came `via player`.

CoreMedia's player records in the system log the variant it **actually decoded**:

```
<0x7fa79005f600|I/QX.257>: [AudioFormat qlac is decodable] [AudioChannels 2]
[Rendition Lossless] [SampleRate 96000] [BitDepth 24]
```

Four decisions there are not obvious, and each cost a wrong diagnosis before it was
understood.

**A long-lived `log stream`, not a query per track.** Each `log show` spends ~800 ms just
launching the process, and it was that cost — not waiting for information — that made the
rate settle almost a second into the track. With the stream, reading becomes a memory access
and resolution drops to ~0.3 s, which puts the pause near the boundary between songs. It
costs 0.3% CPU and 5 MB.

**Not `OSLogStore` either, which would be cheaper.** It reads the persisted archive, and
info-level entries take **minutes** to arrive there: a line just written by the process itself
was still invisible to it after 30 seconds, while the command-line tool saw it immediately. A
cheap answer about a state from minutes ago is worth nothing.

**Attribution is by identity, not by time.** The message names no track, and deciding by
timestamp made neighbouring tracks swap formats when skipping quickly. But each track has its
own token (`I/QX.257` above), shared by its repeated reports — it was printed on every line,
and was being treated as hexadecimal noise.

**Correction only in the first 3 seconds.** Skipping faster than the player reports leaves the
app describing one track while the player describes another, and no rule reconciles two
sources sampled at different moments. A new report makes the app re-evaluate, but only inside
that window: after it, a correction would be a cut in the middle of the music.

If the log does not answer, the app switches the reading off, records why, and reverts to the
earlier behaviour. The check is made once, with a question that has to have an answer **and**
be about something recent: asking whether "any entry" can be read answers yes using the app's
own entries. Five streamed tracks in a row with nothing parsed also stands the reading down.

That last count only advances on streamed tracks, since a download resolves from its file
without waiting and so never learns whether the player would have spoken. A library of
downloads would therefore keep a `log stream` running past the point of usefulness — no
worse audio, just a subprocess earning nothing.

#### The two messages, and why this one

Music's playback is described twice in the system log, by two different publishers:

```
[com.apple.coremedia:player]  fpfs_ReportAudioPlaybackThroughFigLog: … <0x…|I/WR.335>:
                              [AudioChannels 2] [Rendition Lossless] [SampleRate 96000] [BitDepth 24]

[com.apple.Music:ampplay]     play> cm>> mediaFormatinfo … asbdFormatID = qlac, lossless,
                              asbdNumChannels = 2, asbdSampleRate = 44.1 kHz
```

CoreMedia's is the one read, for three reasons. It is the only one carrying the per-track
token — `I/WR.335` — without which reports can only be matched to tracks by time, the method
that made neighbouring tracks swap formats when skipping quickly. It reports what was
actually decoded, which is the only way to know whether an Atmos variant is playing rather
than merely present. And its bit depth is dependable: over one fifteen-minute stretch,
`BitDepth` appeared six times against six `SampleRate`, always paired, while Music's own
message omitted the depth entirely on most lines.

Music's is read as a **reserve**, consulted only when CoreMedia has said nothing at all for
the current track — never alongside it, because a report with no token would be taken as
belonging to whatever is playing. It also never wakes the app; it is read when asked.

The reserve is worth having because the two move independently: CoreMedia's message travels
with macOS, Music's with Music, so one changing shape need not take the other with it.
LosslessSwitcher has read the Music one since 2022, and both were still being emitted, side
by side, on the macOS 15.7.9 and Music 1.5.6 this was written against.

Two details of that line are easy to get wrong. It gives the rate in kHz with a decimal, and
`44.1 * 1000` is `44100.000000000007` in binary floating point — a value no list of plausible
rates contains, so the multiplication is rounded. And `sdBitRate = 768 kbps` sits near
`sdBitDepth` in the Atmos variant, close enough to catch a careless pattern.

**None of this varies with language.** The same query under `en_US`, `ar_EG`, `tr_TR` and
`de_DE` returns byte-identical output, timestamps included: these are developer strings
inside `os_log` format literals, not user-facing text, and `process == "Music"` matches the
executable's name, which stays `Music` though the bundle carries 42 localized ones.

#### If the log stops working

The message being read is not public API. If it changes shape in a macOS update, the app
switches itself off — and then it matters whether the track is downloaded:

| | downloaded track | streaming |
|---|---|---|
| rate and depth | **exact, read from the file** | a guess (the fallback, 44.1 kHz by default) |
| bit-perfect | kept | lost on anything that is not 44.1 |
| waiting | none | none, but the value is invented |

The `.movpkg` is read from the container — rate in `mdhd`, depth in the ALAC cookie. A public
format, with no dependency on Apple internals. It is what `--inspect` shows:

```
movpkg with 1 variant(s); Music lossless=true
  3410074 bps  alac 24-bit 96 kHz
  → would play: alac 24-bit 96 kHz
```

Having your library downloaded does not improve quality: it is the same file either way, and
with the log working both paths reach the same answer. What it buys is **independence from an
undocumented source**.

## Settings you have to change by hand

Music's AppleScript does not expose these, but every one of them breaks bit-perfect playback:

In **Music → Settings → Playback**:

- Sound Enhancer: **off**
- Sound Check: **off**
- Crossfade Songs: **off**
- Audio Quality → **Lossless** or **Hi-Res Lossless**

The menu's *Check bit-perfect setup…* runs the check and shows everything that can be
verified.

## How it compares

This app invented neither the problem nor the solution. Worth recording what already exists,
and what is different here — a comparison drawn from each project's public documentation, not
from running them side by side.

| | how it solves it | model |
|---|---|---|
| [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) | reads Apple Music's log via OSLog | free, open source |
| [BeatPerfect](https://beatperfect.strux.pro/) | learns the format by listening, applies it next time | subscription, $2.90/month |
| DACorum, MyAudioFormat | you change the rate by hand, faster than in Audio MIDI | paid, on the App Store |

**LosslessSwitcher** got there first, in 2022, and Attune's central technique — reading what
CoreMedia reports — is the same idea. There is no novelty in it.

What Attune does differently:

**It uses both techniques together.** The log answers the first play; the cache answers the
rest in a millisecond, without asking Music anything. LosslessSwitcher stores nothing and
pays for detection every time; BeatPerfect assumes a track's first play is not bit-perfect,
because it needs 5 s of playback to learn. Here the first play is already right, and the
second is right faster.

**It changes rate before the track turns over.** That is what the section above describes.
LosslessSwitcher documents that "there may be short interruptions to your audio playback"
during the change, and switches as soon as possible after the new track has begun. Here the
silence falls in the previous track's tail and the new one starts intact — measured, not
assumed.

**Bit depth at no cost.** LosslessSwitcher has the option but warns that enabling it "will
reduce detection accuracy, hence, it is not recommended". Here the depth comes exactly from
the same log and from the downloaded file's ALAC, and the wire format is raised to the
deepest the device accepts — which never makes anything worse.

**It reads the downloaded file directly.** A downloaded track is a `.movpkg`, and the app
opens the HLS variant and reads rate and depth from the container itself. No dependence on
the log, and no waiting.

**It picks the device by rule.** Three rules (your choice, else the most recently connected
DAC, else the speakers), reacting to plugging and unplugging. The others either use the
current device or leave the choice entirely to you.

**It warns about what cancels everything out.** Music's internal volume below 100% or the
equaliser switched on destroy the result silently. The app checks and flags it on the menu bar
icon.

**No subscription and no administrator access.** LosslessSwitcher asks for administrator
access and is not sandboxed; BeatPerfect is a monthly subscription.

Against that, being honest about the other end of the comparison: those apps are maintained
and used by many people, on varied hardware. This one was tested on one machine, with two
DACs, by its author — see [Where this was measured](#where-this-was-measured).

## What this app is not

- **Not exclusive mode.** Music plays through the macOS mixer, and no external app changes
  that. With the rate matching the source, volume at 100% and no DSP, the path is
  bit-transparent — the same result the original BitPerfect delivered. But if another app
  plays at the same time, the mixer sums them. For real exclusive mode (hog mode, integer
  mode, native DSD) you need a player of your own, something like Audirvana.
- **Streaming depends on an internal Apple log.** It works, and was verified at 44.1, 48 and
  96 kHz, but the message the app reads is not public API. If it changes shape in a macOS
  update, streaming reverts to the fallback — without breaking anything else.
- **No DSD.** Many DACs accept DSD over USB, but Music never sends DSD.

## What it costs to run

Measured with the app running and Music playing throughout, in the environment described in
[Where this was measured](#where-this-was-measured):

| | |
|---|---|
| memory | **16.7 MB** (peak 17.1 MB) |
| CPU at rest | **0.07–0.08%** |
| CPU since launch | 0.50% |
| threads | 5 to 9 |

The at-rest figure comes from two independent measurements that landed in the same place: a
timed 100 s window (0.080%) and the difference of the cumulative counters across 157 s
(0.070%). The 0.50% since launch is higher because it includes startup, the player-log probe
and a dozen track changes in thirteen minutes — it is not the day-to-day number.

The app sleeps between events. It wakes on Music's notification (one per track), on the 15 s
check — with generous leeway, precisely so the system can group it with other wakeups — and
when a device comes or goes.

The memory figure is the physical footprint, which is how Apple accounts for a process; `ps`
shows ~35 MB of RSS, but that counts shared pages from system frameworks that would exist
anyway. The format cache weighs almost nothing in it: 47 tracks take ~4 KB, and even full, at
50,000, it would be ~4 MB.

The thread count varies because nearly all of them are worker threads libdispatch creates and
reclaims on its own — the app declares only two queues of its own (`attune.engine` and
`attune.music`) plus the main one, and the CPU time sits almost entirely in the last.

### Where this was measured

Every number in this README — the cost above, the 730 ms of DAC relock, the Apple Event
timings, the cache latency — came from this machine. Different hardware gives different
numbers, the relock above all, which is a property of the DAC.

| | |
|---|---|
| machine | MacBook Pro (MacBookPro15,1), 8-core Intel Core i9 at 2.4 GHz, 32 GB |
| system | macOS 15.7.9 (24G830), Darwin 24.6.0 x86_64 |
| Music | 1.5.6 |
| compiler | Swift 6.1.2 (swiftlang-6.1.2.1.2, clang-1700.0.13.5), target x86_64-apple-macosx15.0 |
| tooling | Command Line Tools, no Xcode |
| app | Attune 1.4 (5), signed with a self-signed certificate |

Outputs present during the tests:

| device | transport | rates | bits |
|---|---|---|---|
| **Topping DX3 Pro+** | USB | 44.1 – 768 kHz | 24, 32 |
| **HiBy FC4** | USB | 32 – 768 kHz | 16, 24, 32 |
| MacBook Pro Speakers | built-in | 44.1 – 96 kHz | 32 |
| DP1 | DisplayPort | 32 – 48 kHz | 16, 20, 24 |

The **DX3 Pro+** was the target for most of the testing, including the 30 rate changes that
established the 724–740 ms relock, and the pre-switched transitions. The **HiBy FC4** served
to verify selection by connection order with two DACs present. The DisplayPort entry is in
the list deliberately: it is **not** adopted as a DAC, and it served to confirm that.

The test tracks came from a *Favourite Songs* playlist in Apple Music, with material at
44.1 kHz (16- and 24-bit), 48 kHz and 96 kHz/24-bit, both downloaded and streamed.

## Volume

Leave Music's internal volume at 100% — it attenuates in software, before the audio leaves
the app. The macOS volume control, when the DAC exposes one, is passed through to the
device's own attenuator, and that one you can use freely. The menu's
*Check bit-perfect setup…* says which of the two cases is yours.

## Languages

The interface follows the system language, and falls back to English when there is no
match. Twelve are shipped: English, the five most spoken languages in the world by total
speakers, the five most spoken in Europe that those did not already cover, and Portuguese.

| | | |
|---|---|---|
| `en` | English | |
| `zh-Hans` | Chinese (Simplified) | Mandarin, ~1.18 B speakers |
| `hi` | Hindi | ~609 M |
| `es` | Spanish | ~560 M |
| `ar` | Arabic | ~422 M, right to left |
| `fr` | French | ~310 M |
| `ru` | Russian | most native speakers in Europe, ~106 M |
| `de` | German | ~85 M |
| `it` | Italian | ~58 M |
| `pl` | Polish | ~38 M |
| `uk` | Ukrainian | ~33 M |
| `pt-BR` | Portuguese (Brazil) | the author's |

**These translations have not been reviewed by native speakers.** They are careful, and the
build checks that every key exists in every language and that the format specifiers match —
a `%ld` lost in translation would make `String(format:)` read an argument that was never
passed — but a wording that reads oddly to a native ear would pass both checks. Corrections
are welcome.

**Arabic reads right to left**, and the menu rows are custom views with positions measured
by hand, so they mirror explicitly: the checkmark moves to the trailing edge, the label
aligns and reverses with it, and the scrolling header starts flush right and travels the
other way. There is no automatic mirroring to inherit — a view-backed menu item draws
itself.

Numbers follow the reader too: a rate shows as `44,1 kHz` where that is the convention and
`44.1 kHz` where it is not. Log lines deliberately do not, so a search for `44.1 kHz` keeps
finding them.

**The cache is not affected by any of this**, and that is worth knowing before touching it.
An entry is text — `96000|24` under a key like `id:FD9BD6493A459860` — and everything that
produces or parses it is locale-independent by design: Swift's string interpolation of an
`Int` always writes ASCII digits with no grouping separator, `Double(String)` always expects
a dot, and a hexadecimal key has no decimal separator to disagree about. So a German never
writes `96.000`, an Egyptian never writes `٩٦٠٠٠`, and a cache filled in one language reads
back identically in another. Changing the app's language invalidates nothing.

That is a promise worth pinning rather than assuming, since `String(format:)` in the same
file did produce a decimal point where a comma belonged:

```bash
tools/test-locale-safety.sh
```

It round-trips one entry through eight locales and compares the bytes — Turkish for its
dotless i, Arabic and Hindi for their own digit shapes, German and Russian for the decimal
comma.

Only the interface is translated. Log messages stay in English deliberately — they exist for
diagnosis, and a translated log is harder to search and harder to paste into a bug report.

To see the app in another language without changing the whole system:

```bash
defaults write com.macario.attune AppleLanguages -array pt-BR
```

Quit and reopen the app. To go back to the system language:

```bash
defaults delete com.macario.attune AppleLanguages
```

The same thing exists in the interface, under **System Settings → General → Language & Region
→ Applications**.

### Adding a language

Copy `Resources/en.lproj` to `Resources/<code>.lproj`, translate the two `.strings` files,
and add the code to `CFBundleLocalizations` in `Info.plist`. `build.sh` runs
`tools/check-localization.py`, which fails the build if a key used in the code is missing
from any language — without it, a forgotten translation would appear in the menu as the key
itself (`menu.quit`), with no error at all.

## The icon

Drawn in code, in [tools/make-icon.swift](tools/make-icon.swift), and packaged with
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

## Diagnostics

To understand which device the app chose and why:

```bash
"build/Attune.app/Contents/MacOS/Attune" --resolve
```

```
DACs by recency:
    DX3 Pro+  (USB)  connected 16:54:56
    HiBy FC4  (USB)  connected 17:02:11
Chosen in app: DX3 Pro+ — connected
Rule applied: 1. the device chosen in the app
Target: DX3 Pro+
```

It says which of the three rules applied, which is hard to deduce from the result alone.

To follow what the player is reporting, live:

```bash
"build/Attune.app/Contents/MacOS/Attune" --watch-player
```

```
19:54:02  Lossless  44.1 kHz  16-bit  2ch  I/QX.257
20:06:10  Lossless  96 kHz    24-bit  2ch  I/YH.259
```

And to verify the whole cycle without doing anything by hand:

```bash
tools/test-switching.sh 8 1.2      # 8 skips, 1.2 s apart
```

It reinstalls, launches the app, skips tracks through Music and checks whether the DAC ended
on the rate the player last reported — asking the app **which device it is targeting** rather
than assuming one. Assuming was the third false negative this tool produced. The check is
about the **final state**, not about each intermediate reading: skipping faster than the
player reports produces transient mismatches that are expected, while the rate you are left
listening to can never be wrong.

It answers `INCONCLUSIVE` when the player is still talking during the measurement. Without
that it compared the DAC against the format of the track the player was already preparing,
and failed the app when the app was right.

The menu has *Show recent activity…*, which shows the app's recent decisions. From the
command line:

```bash
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.macario.attune"'
```

Steps that take more than 50 ms record themselves, so slowness shows up in the log without
changing anything. Use `/usr/bin/log` with the full path if you have a `log` function in your
shell.

```bash
"build/Attune.app/Contents/MacOS/Attune" --list-devices
```

Shows the current rate, the wire format, and everything each output accepts. You can leave
**Audio MIDI Setup** open beside it and watch the rate change by itself on each track.

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
| `tools/create-signing-identity.sh` | Creates the certificate that preserves the permissions |

Two things worth knowing about the build:

- `build.sh` runs `osacompile` over the AppleScript before packaging. It earns its keep:
  short variable names collide with Music's terminology (`st`, for one, does not compile
  inside a `tell` block), and without that check the error only appears at runtime,
  silently.
- Without a signing certificate, each rebuild produces a new ad-hoc signature and macOS asks
  for the Media & Apple Music permission again. See
  [Why rebuilding asks again](#why-rebuilding-asks-for-the-permission-again).

## License

MIT — see [LICENSE](LICENSE).
