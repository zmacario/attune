# What to expect

What this does that other apps do not, what it deliberately does not do, and what it
costs to leave running.

[← back to the README](../README.md)

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

Over 45 minutes of continuous playback the footprint moved from 16 MB to 17, the thread count
oscillated between 5 and 7, and the open descriptors sat at 38 in all sixteen samples without
a single one added — which is the number to watch, since the log reader holds a subprocess and
its pipes.

One thing that reading showed and no threshold would have: while the menu is **open**, the app
spends around 1.7% CPU rather than 0.07%, because the scrolling header redraws at 30 frames a
second. It stops the moment the menu closes — the sample straight after went back to the idle
rate — so it is a cost while you are looking at it, not a leak. `tools/test-soak.sh` reports
CPU per window rather than cumulative for exactly this reason: cumulative hid the shape, and
it took subtracting rows by hand to see it at all.

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
