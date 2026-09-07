# Contributing

Bug reports and patches are welcome. There is no ceremony here — no template to fill in, no
checklist to tick — but a few things make a change easy to accept.

## Reporting something

The menu's *Show recent activity…* holds the app's recent decisions in plain words, and it is
usually the whole answer. Paste it, along with:

- what you expected and what happened instead;
- the output of `"/Applications/Attune.app/Contents/MacOS/Attune" --resolve`, which says which
  device the app chose and by which of the three rules;
- your macOS version, your DAC, and whether the track was downloaded or streamed.

If a rate came out wrong, `--list-devices` and `--inspect <track.movpkg>` say what the device
accepts and what the file actually contains.

## Changing something

Read [Working on it](docs/development.md) first — it describes the layout of the source and
what each tool checks.

Two things carry more weight than style:

**Say what you measured.** Nearly every decision in this project is written down with the
number that justified it, and several were reversed when the number disagreed. A change that
says "this is faster" is harder to accept than one that says how much faster, on what.

**Run the tests, and make the new one fail first.** `tools/` holds a script per area. A test
that has never failed has proved nothing: `test-layout.sh` passed its first regression
happily, because it asked the app which way the interface read and then checked the checkmark
was on that side.

```bash
./build.sh                      # also lints the language tables and the AppleScript
tools/test-cache.sh
tools/test-player-log.sh
tools/test-movpkg.sh
tools/test-layout.sh
tools/test-locale-safety.sh
tools/test-switching.sh 8 1.2   # drives Music; needs a DAC connected
```

## Translations

Twelve languages ship, and none has been reviewed by a native speaker. Corrections to any of
them are the most useful small contribution there is —
[Adding a language](docs/development.md#adding-a-language) covers adding a new one, and the
build fails if a key is missing or a format specifier does not match English.
