# Support

FM-1 Manager is an unofficial, open-source app made in spare time. It is not affiliated with M-VAVE, the FM-1
Firmware Hub or fm1-dock, so please do not ask them about the app itself.

## Getting help

Open an issue at <https://github.com/KonradHerman/fm1-manager/issues>. Please include:

- your iPhone model and iOS version, and the app's version (Settings › About, privacy and support);
- which FM-1 you have (and, if you know, whether it has the newer flash chip) and which firmware it runs;
- what you did, what you expected, and what happened instead; a screenshot helps.

Questions about a firmware or a module itself belong to its makers (the Firmware Hub links to each one; fm1-dock's
repository is <https://github.com/joakimeriksson/fm1-dock>).

## If something goes wrong

Installing a **whole firmware** is the riskiest thing the app does: the FM-1 restarts into its update loader, and the
loader rewrites the firmware. Adding or removing fm1-dock modules, and applying rigs, do not go through this path:
they talk to fm1-dock while it runs and never touch the firmware itself. You install firmware at your own risk.

### The FM-1 shows UPDATE MODE

An install did not finish, so the FM-1 waits in its update loader (the app shows it as "in update mode"; its MIDI
port is then called something like "Felucca Update"). This is recoverable: the FM-1 stays in update mode, safely,
until an install finishes. In this order:

1. **Install the same firmware again** from the installer you used (the Firmware Hub, fm1-dock's page or Baud Girl's
   installer), with the FM-1 plugged in and the app kept open. An installer that can resume this loader finishes the
   job. Note: the Firmware Hub resumes only Felucca's and SLOOP's loaders; if the loader belongs to another firmware
   it says "foreign" and offers *Back to official V15* instead.
2. **If it stops at the same point again, or no installer will resume it, the phone cannot fix it. Use a computer:**
   - the same installer page in Chrome or Edge on a computer, which may get further or report more;
   - **M-Flasher**, a computer tool for the chip's own download mode, which writes a firmware directly to the
     chip (it has written M-VAVE's stock firmware, and other firmwares, back onto units stuck this way). The chip's
     download mode cannot be reached from an iPhone.
   - The Firmware Hub's page has a Rescue section with the steps for the computer.

What has happened so far: one whole-firmware install from a phone (Skiff 2.7 from the Firmware Hub, on an FM-1 with
the newer flash chip, from fm1-dock 0.9.0) stopped in the firmware's update loader, early in its write, and the same
happened when the install was resumed from a Mac with the reference installer. The FM-1 was recovered with
M-Flasher. The cause has not been established.

### Known problems

Firmware problems we have seen ourselves (the same list is in the app: Settings › Known problems, and from the
Firmware Hub's bar). The data is in [`App/Resources/KnownProblems.json`](App/Resources/KnownProblems.json).

- **Skiff 2.7 from the Firmware Hub, on a newer-chip FM-1 running fm1-dock 0.9.0** (2026-11, one unit): the install
  stopped in Skiff's update loader at the first write and left the FM-1 in update mode; resuming from a Mac stopped
  the same way. Recovered by writing Skiff with M-Flasher on a computer; the firmware itself runs once written.

### Newer and older flash chips

FM-1s sold from autumn 2026 (the M-VAVE logo under the screen) have a different flash chip (JEDEC id B36014) from
earlier ones (856014). Firmware written only for the older chip cannot save on a newer FM-1, and its updates can
fail. The app reads the chip from fm1-dock 0.8 or later when the FM-1 is plugged in, or asks you; on a newer FM-1 it
opens the Firmware Hub with the Hub's own "Saves on newer FM-1s" filter on. That filter rests on each firmware
author's own declaration, not on a test: Skiff above is declared as saving on newer FM-1s.

### fm1-dock misbehaves after adding a module

fm1-dock's own safety nets, held while switching the FM-1 on (fm1-dock's README, section "Safety nets"):

- **OCT+** at power-on: a safe start with only the built-in sine;
- **OCT−** at power-on: the USB rescue, with only the updater running, so any install can be run again;
- **HOME** at power-on: fm1-dock stays, even with another firmware in its boot slot.

When in doubt, stop and ask (see above) before trying more installs.
