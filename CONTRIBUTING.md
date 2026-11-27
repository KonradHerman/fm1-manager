# Contributing to FM-1 Manager

Thank you for looking. FM-1 Manager is a small app made in spare time, so every report from a real FM-1 counts for a
lot: it has been used on one iPhone and one FM-1, and almost everything else has only met a simulated one. You don't
need to write code to help.

## What helps most

1. **Trying it on hardware we haven't.** An FM-1 with the older flash chip (no logo under the screen), a Lightning
   iPhone through Apple's camera adapter, other firmwares than fm1-dock. Tell us what worked as well as what didn't:
   "Rigs applied fine on my older-chip unit" is news.
2. **Reporting exactly what happened.** A good report beats a guessed fix. See below.
3. **Whole-firmware installs**, carefully. They are the risky part. Read [SUPPORT.md](SUPPORT.md) first, and only if
   you know how you would recover (M-Flasher on a computer, or the installer in Chrome).
4. **Code**, once the above has shown what to fix. The known rough edges are in the
   [README](README.md#honest-status) and in [SUPPORT.md](SUPPORT.md#known-problems).

Ideas and questions are welcome in Discussions; issues are for things that went wrong.

## Reporting a problem well

Open an [issue](https://github.com/KonradHerman/fm1-manager/issues/new/choose); the form asks for these:

- your iPhone model and iOS version, and the app's version and build (Settings › About, privacy and support);
- your FM-1's flash chip (newer: the logo under the screen; older; not sure), and the firmware and version it ran;
- which screen or installer you used, what you did, step by step;
- what the screen said, word for word if you can, and a screenshot or a screen recording.

**If your FM-1 is stuck in update mode, or won't start, go to [SUPPORT.md](SUPPORT.md#if-something-goes-wrong)
first**, then tell us what happened.

## Building and testing

The README's [Build it yourself](README.md#build-it-yourself) has the steps. In short:

```sh
brew install xcodegen
xcodegen
cd FM1Kit && FM1_OFFLINE=1 swift test        # the core, on a Mac
cd .. && xcodebuild -project FM1Dock.xcodeproj -scheme FM1Dock \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test   # the app, then again with FM1_DOCK=NO
```

## House rules

These are the ones that matter for a project that writes to people's synths:

- **Automated tests never talk to a real synth.** Tests use only the virtual MIDI endpoints they create
  (`FakeFM1`), and the MIDI engine under test gets the fake's filter, so a real FM-1 plugged into the Mac is never
  listed, opened or sent to. Keep it that way.
- **Every change that talks to the device gets a test against the simulated FM-1.** If `FakeFM1` cannot do what
  your change needs, extend it after the firmware's own source (fm1-dock's `dock.c`, Felucca's `ota.c`) and say how
  faithful it is.
- **Nothing is sent to the FM-1 that the person did not ask for**, except the read-only questions the installers
  themselves ask (the identity handshake, fm1-dock's HELLO and INFO).
- **Say only what was seen.** In docs, commit messages and the known-problems file, write what happened, not what
  probably happened.
- **Your git identity is your choice.** Use any author name and email you like (a GitHub no-reply address works);
  we never ask for one.
- **Commit style**, as the history shows: a short subject that says what changed for the person using the app, a
  body that says why, in plain sentences. One concern per commit.
- **Licence:** contributions are under GPL-3.0-only, like the rest. Every source file starts with an SPDX line. No
  CLA.

## How a pull request gets reviewed

Open it against `main` and fill in the short template. Expect a read within a week or two; there is one maintainer.
A change that touches the device gets run against the simulated FM-1 and, when possible, a real one before it is
merged. We may ask for a test, a smaller change or clearer wording; we may also say no to a feature that doesn't fit
an app whose first job is to be safe with someone's synth. Either way you'll hear why.
