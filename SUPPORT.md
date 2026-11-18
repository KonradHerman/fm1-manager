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

Installing firmware is at your own risk. Most problems can be undone:

1. **An install was cut off** (the cable came out, the app closed): the FM-1 stays in update mode. Plug it in again
   and install the same firmware once more; the installer finishes the job.
2. **fm1-dock misbehaves after adding a module**: fm1-dock's own safety nets, held while switching the FM-1 on
   (see fm1-dock's README, section "Safety nets"):
   - **OCT+** at power-on: a safe start with only the built-in sine;
   - **OCT−** at power-on: the USB rescue, with only the updater running, so any install can be run again;
   - **HOME** at power-on: fm1-dock stays, even with another firmware in its boot slot.
3. **Nothing on the FM-1 answers any more**: the FM-1 Firmware Hub has a Rescue section, and M-Flasher (a computer
   tool for the chip's own download mode) can write M-VAVE's stock firmware back. Both need a computer; the chip's
   download mode cannot be reached from an iPhone.

When in doubt, stop and ask before trying more installs.
