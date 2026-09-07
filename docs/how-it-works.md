# How it works

How a track's rate is found, remembered, and applied — and why each of those is harder
than it sounds.

[← back to the README](../README.md)

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

This is the app's only hand-written binary reader, and the only place where a defect becomes
a crash rather than a wrong sample rate — a half-written or truncated download is an
ordinary thing to find on disk, and the answer to one has to be "I don't know", not a dead
menu bar. So it is tested against everything it should survive:

```bash
tools/test-movpkg.sh
```

Every real package in the library first, which must all still resolve — a crash fixed at the
cost of a correct answer is not fixed. Then a deterministic corpus of damaged inputs, each
run in its own process, since only a separate process can tell a crash from a `nil`.

It earned its keep on the first run, on two of the crafted cases rather than any of the
random ones. A `mdhd` box declaring size 8 carries no payload, and the version byte inside it
was read without a bounds check. And a 64-bit box size above `Int.max` trapped on conversion
instead of being rejected as the broken file it announces. Truncation at 100 lengths, a bit
flipped at every seventh byte of the header, sixty rounds of random corruption and four
thousand levels of nesting all came back clean.

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
own entries. Five tracks in a row with nothing parsed also stands the reading down.

That count advances when a track **ends** without the player ever having described it, which
is the only fair moment to ask. Counting during playback would condemn every download, since
a download resolves from its own file long before the player gets round to speaking. Judging
mid-track was why this used to be counted for streamed tracks alone — and why a library of
downloads could never stand a dead reader down at all, leaving a `log stream` running past
the point of usefulness.

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
