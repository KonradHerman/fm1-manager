# What's new

Builds are TestFlight builds of version 1.0. Newest first.

## Next (not yet in a build)

- **Baud Girl's installer.** A third installer on the home screen: Baud Girl (FM-1+VA), from its maker's own site.
  It is not open source and nothing of it is in the app; the app only gives the page Web MIDI.
- **Update mode, explained.** When an install stops and the FM-1 waits in its update loader, the home screen and
  the installer page say so and what to do: install the same firmware again, and if that stops too, a computer.
- **The newer flash chip.** The app reads the FM-1's flash chip from fm1-dock 0.8 or later, or asks you once. On a
  newer FM-1 the Firmware Hub opens with its own "Saves on newer FM-1s" filter on.
- **Known problems.** The firmware problems we have seen ourselves, starting with Skiff 2.7 on a newer-chip FM-1, in
  Settings and in SUPPORT.md.
- **Downloads.** A file an installer saves (Baud Girl's preset backup) goes into your library.
- **Steadier reconnects.** If the FM-1 comes back from a restart under new MIDI ids, the installer pages see the
  new ports instead of the old, dead ones. (Without this, the Firmware Hub could say "No FM-1 found" on Install
  again.)
- The recovery notes in SUPPORT.md rewritten to match what actually happened on a real FM-1.

## Build 7

- Ready for the App Store: iPhone only for 1.0, a privacy manifest, an About screen with the version, links and
  licence, and a one-time warning that the app writes to your synth.
- Rigs and Hands moved under "Experimental" on the home screen.
- A page that cannot load (no network) says so with Try again, instead of a blank screen.
- PRIVACY.md and SUPPORT.md, and the App Store listing text.
- Background work that could crash the app the same way Hands did now hops to the main thread safely.

## Build 6

- Hands no longer crashes on opening on a real iPhone. (Its tilt handler ran on the wrong thread; the simulator has
  no motion sensor, so no test had run it.)

## Build 5

- The app is called FM-1 Manager, and the repository is public.

## Build 4 and earlier

- The FM-1 Firmware Hub and fm1-dock's page with Web MIDI over CoreMIDI and USB.
- The library of .fwsc and .dock files, and Install from Library.
- Rigs and Hands, first versions.
- App icon colours.
