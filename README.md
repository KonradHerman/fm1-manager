# FM-1 Manager

An iPhone app for the M-VAVE FM-1 synth: it runs the FM-1's web installers, which need Web MIDI that Safari on iOS
does not have, and adds a few things of its own (a library of firmware and module files, Rigs, Hands). It talks to
the FM-1 over a USB cable through iOS's CoreMIDI.

**This is an unofficial app.** It is not made by, affiliated with or endorsed by M-VAVE, the FM-1 Firmware Hub or
fm1-dock.

> [!WARNING]
> **This app writes firmware and modules to your synth.** A cut cable, a flat battery or a bug can leave the FM-1 in
> update mode or without a working firmware. Before you install anything, know how to recover:
> fm1-dock's README lists its safety nets ([Safety nets](https://github.com/joakimeriksson/fm1-dock#safety-nets):
> OCT+ at power-on for a safe start, OCT− at power-on for the USB rescue, HOME at power-on to stay in fm1-dock).
> Beyond those, M-Flasher, a computer tool for the chip's own download mode, can write M-VAVE's stock firmware back;
> that mode needs a computer and cannot be reached from an iPhone.
> You use this app at your own risk.

## What it does, and how well it is tested

Hardware so far: **one iPhone and one FM-1** (a unit with the newer flash chip, running fm1-dock 0.9.0), used by the
app's owner. Nothing has been tried on an iPad, on an FM-1 with the older flash chip, on an SMK-37, or with any other
firmware than fm1-dock and the installers below. Everything else in this list has only run against a **simulated
FM-1** (`FakeFM1`, see below) on virtual CoreMIDI endpoints, on a Mac and in the iOS simulator.

| Feature | What it is | Tested |
| --- | --- | --- |
| **FM-1 Firmware Hub** | thefirmwarehub.com, unchanged, with Web MIDI supplied by the app: install whole firmwares | The owner reports it working on the one iPhone and FM-1 above; which installs were run there was not recorded. Automated: connects to the simulated FM-1 with an iPhone user agent. |
| **fm1-dock's page** | joakimeriksson.github.io/fm1-dock, unchanged: install fm1-dock, add and remove its modules, its console | The owner reports it working on the one iPhone and FM-1 above; which operations were run there was not recorded. Automated: its console and device panel connect to the simulated FM-1, and a module goes in through its file input. |
| **Library** | .fwsc and .dock files kept in the app (visible in Files as On My iPhone › FM-1 Manager); import from Files, Safari, Mail; hand a file to a page's file input | Simulated FM-1 and simulator only. |
| **Install from Library** | an offline page that installs a library file with fm1-dock's own installer code | Simulated FM-1 only, including a whole 610 KiB firmware install (both update stages, every byte checked). Not yet on hardware. |
| **Rigs** | named sets of fm1-dock modules kept on the phone; "Save what's on my FM-1"; Apply changes only what differs, plans around the module area's free gaps, checks the device after every step, and can Resume after a cut cable; modules from fm1-dock's published catalogue, checked against its SHA-256 | Simulated FM-1 only (its module area modelled on fm1-dock's `dock.c`). In a TestFlight build on the owner's phone, **no result reported yet**. |
| **Hands** | a performance screen: XY pad (CC 74 / 71 by default, fm1-dock's KNOB1 / KNOB2), a touch keyboard with slides, latch, scale lock and velocity by touch position, tilt to a chosen control while held, panic | MIDI logic tested against a virtual destination (no stuck notes, rate limits, ranges). The screen itself, the feel, the latency and tilt from the real motion sensor: untested. In the same TestFlight build, **no result reported yet**. |
| **App icon colours** | eight icon colours to match your FM-1, chosen in Settings | Simulator. |
| **Jam in GarageBand** | a note on using the FM-1 as GarageBand's keyboard; a link to GarageBand in the App Store | Not tested. fm1-dock's firmware declares a USB audio input, but nobody has tried recording it in GarageBand. |

Known rough edges are listed under [Contributing](#contributing).

## Building it

You need a Mac with **Xcode 26** (built with 26.6), **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew
install xcodegen`) and an Apple developer account (a free one is enough to run it on your own phone). iOS 17 or later.

```sh
git clone <this repository> fm1-manager && cd fm1-manager
xcodegen                      # writes FM1Dock.xcodeproj from project.yml (the project file is not committed)
open FM1Dock.xcodeproj
```

To sign it as yourself, change two lines in `project.yml` and run `xcodegen` again:

- `DEVELOPMENT_TEAM`: your team ID (developer.apple.com › Membership). It is set in this one place.
- `PRODUCT_BUNDLE_IDENTIFIER` of the `FM1Dock` target: a bundle id of your own (`com.klhoud.fm1` is the owner's).

The project, target, scheme and product are still called `FM1Dock` internally (the app's earlier name); what you see
on the phone is "FM-1 Manager".

### The FM1_DOCK switch

`FM1_DOCK` in `project.yml` decides whether fm1-dock's own code goes into the app:

- `YES` (the default, and what ships): fm1-dock's site, the library, Install from Library and Rigs. The app then
  carries fm1-dock's installer JavaScript (`App/Resources/web/`).
- `NO`: the hub-only app: the Firmware Hub and Hands, and none of fm1-dock's files in the bundle.

Change it in `project.yml` and run `xcodegen`, or for one build pass `FM1_DOCK=NO` to `xcodebuild`.

### Tests

The tests create their own virtual MIDI endpoints and only ever talk to those, so they are safe to run with a real
FM-1 plugged into the Mac.

```sh
# the MIDI core, Rigs and Hands on macOS (some tests load the live sites; FM1_OFFLINE=1 skips them)
cd FM1Kit && FM1_OFFLINE=1 swift test

# the app's tests in the iOS simulator, both configurations
xcodebuild -project FM1Dock.xcodeproj -scheme FM1Dock -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project FM1Dock.xcodeproj -scheme FM1Dock -destination 'platform=iOS Simulator,name=iPhone 17 Pro' FM1_DOCK=NO test
```

Debug builds may create virtual MIDI endpoints (iOS allows that only with the `audio` background mode, which
`App/Info.plist` adds for Debug alone); Release builds do not have it.

## How it works

- **Web MIDI for a web view.** `FM1Kit/Sources/FM1Kit/Resources/webmidi.js` is injected at document start into the
  pages of a few allowed origins (`Site.midiOrigins` in `App/Sources/AppModel.swift`: thefirmwarehub.com,
  fm1.designburgapps.com, joakimeriksson.github.io and the app's own `fm1dock://app` pages). It provides
  `navigator.requestMIDIAccess` with SysEx and no permission prompt; other origins get no Web MIDI at all.
  `WebMIDIBridge.swift` carries it to and from Swift.
- **CoreMIDI.** `MIDIEngine.swift` lists ports (with a filter the tests use to see only their own), connects inputs,
  sends with either the UMP or the older packet-list API (switchable in Settings), and turns whatever packets CoreMIDI
  delivers into whole messages (`MIDIStreamParser.swift`, `UMP.swift`): one event per SysEx, F0 to F7.
- **The app's own pages** are served from the bundle under `fm1dock://app/` (`LocalSchemeHandler`), with the library
  at `fm1dock://app/library/`.
- **DockLink** (`FM1Kit/Sources/FM1Kit/Rigs/DockLink.swift`) is the one place where Rigs talk to fm1-dock on the
  device. Today it runs fm1-dock's own `dock.js` in a hidden web view (`App/Resources/web/rigs.js`); a native
  implementation could replace it without touching the rest.
- **The rig planner** (`RigPlanner.swift`) is a pure function: device state + rig + library in, steps or a reason
  out. It models the module area as fm1-dock's `dock.c` does (first fit, 4 KiB sectors, 296 KiB on an FM-1) and
  checks its model against what the device reports before it plans. `RigApplier.swift` runs a plan step by step.
- **Hands** (`FM1Kit/Sources/FM1Kit/Hands.swift`, screen in `App/Sources/HandsView.swift`) sends from the touch
  handlers straight to CoreMIDI, limits each control to 200 messages a second, and lets every note go on cancel,
  on leaving the screen, on going to the background and on unplug.
- **The simulated FM-1** (`FM1Kit/Sources/FM1KitTestSupport/FakeFM1.swift`) answers on virtual endpoints as an FM-1
  running fm1-dock does: the updater's handshake and reads, and fm1-dock's commands, with its module area placed
  as `dock.c` places it.

## What fm1-dock's flash can and cannot do (found while building Rigs)

- A module cannot be read back off the FM-1: keep its file. The app marks modules that are on the device but not in
  your library, and asks separately before removing one.
- A module's settings and presets stay in the FM-1's flash when it is removed and come back when it is added again,
  unless another module needed their place meanwhile (fm1-dock keeps 8 settings records and 9 preset banks). Nothing
  over USB can copy them to the phone.

## Credits and licence

FM-1 Manager is free software under the **GNU General Public License, version 3 only** (`GPL-3.0-only`, full text
in [LICENSE](LICENSE)). Every source file carries an SPDX line saying so.

It includes, **unmodified**, files from other projects under the same licence:

- `App/Resources/web/dock.js`, `App/Resources/web/install/fm1install.js` and `App/Resources/web/install/ports.js`:
  from [fm1-dock](https://github.com/joakimeriksson/fm1-dock) by Joakim Eriksson.
- `App/Resources/web/install/fm1ota.js`: Felucca's FM-1 update protocol, Copyright (C) 2026 Leo Kuroshita
  (@kurogedelic), Hügelton Instruments, as fm1-dock carries it (with fm1-dock's additions for the SMK-37).

**Ported or derived** (written in Swift for this app from their sources):

- `FakeFM1.swift` and `FM1Protocol.swift` (test support only, not in the app): the simulated device after fm1-dock's
  `docs/demo.js`, `docs/dock.js`, `install/fm1ota.js` and `firmware/src/dock.c`.
- The port-name pattern that recognises an FM-1 (`AppModel.looksLikeFM1`): after fm1-dock's `install/ports.js` and
  the FM-1 Firmware Hub page's own list of port names.

Whether these files may be distributed through Apple's App Store is being discussed with their authors; the
`FM1_DOCK=NO` build leaves fm1-dock's files out entirely.

The FM-1 Firmware Hub and fm1-dock's pages are loaded from their own sites at run time; they are not part of this
repository.

## Contributing

Pull requests are welcome. What would help most:

- **Testing on other hardware**: FM-1 units with the older flash chip, iPads, iPhones with Lightning (through Apple's
  USB 3 camera adapter), and firmwares other than fm1-dock. Say what worked and what did not.
- **Rigs on a real FM-1**: the first check is "Save what's on my FM-1", which shows the FM-1's free space and largest
  gap next to the app's model of them. If those two ever disagree, that is a bug worth reporting.
- **Hands on a real FM-1**: latency, stuck notes, how tilt feels.

Known rough edges:

- Updating a module to another version, or moving one to make room, removes it first. That briefly frees its
  settings and preset slots for other modules.
- Rigs can only be added through Files (the Rigs folder); "Open in" for a shared rig is not wired up.
- Tilt reads side-to-side roll only, so in landscape it probably uses the wrong axis.
- The rig editor's size meter assumes an FM-1's 296 KiB; the SMK-37's two module areas are handled by the planner
  but not shown.
- The hub-only build still contains the Rigs Swift code (unused there); only fm1-dock's files are left out.
- GarageBand is linked through the App Store, because its URL scheme could not be confirmed.
- Bluetooth MIDI can be paired in Settings, but installing over Bluetooth is untested; use USB.
