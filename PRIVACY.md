# Privacy

FM-1 Manager is an unofficial, open-source app for the M-VAVE FM-1 synthesizer. This page says exactly what it does
with your data. In short: **it collects nothing, has no account, contains no analytics or advertising code, and
sends nothing about you anywhere.**

## What the app connects to

The app's own code makes no network connection except these, and only when you use the feature:

- **The FM-1 Firmware Hub** (`thefirmwarehub.com`; `fm1.designburgapps.com` redirects there), when you open it from
  the home screen.
- **fm1-dock's page** (`joakimeriksson.github.io/fm1-dock`), when you open it from the home screen.
- **Baud Girl's installer** (`baudgirl.com`), when you open "Baud Girl (FM-1+VA)" from the home screen.
- **fm1-dock's module catalogue** (`joakimeriksson.github.io/fm1-dock/fw/index.json` and the module files next to
  it), only when you open "Get modules from fm1-dock's catalogue" and when you tap Get on a module.

Links to anything else (GitHub, the App Store page for GarageBand, links inside the websites) open in Safari or the
App Store, outside the app.

### The websites are third-party sites

The installer sites are run by other people, not by this app's developer. The app shows them as they are, the
way Safari would, and adds only a way for them to talk MIDI to your FM-1 over the USB cable. What those sites load,
count or store (for example their own statistics, Baud Girl's installer's own reports of how an install went, or the
Firmware Hub's own sign-in and favourites if you use them)
is up to them and follows their own privacy practices. The app does not read or receive anything from them except
the MIDI messages they send to your FM-1. Cookies and site storage they set stay in the app on your phone, as they
would in Safari. A file such a page saves (Baud Girl's installer saves a backup of your presets) goes into your
library on the phone.

## What stays on your phone

- **Your library**: the firmware (.fwsc) and module (.dock) files you add. They are in the app's Documents folder,
  visible in the Files app as On My iPhone › FM-1 Manager, and included in your iPhone backups.
- **Your rigs**: one small file each in the Rigs folder of the same Documents folder.
- **Settings**: the app's own settings (the MIDI API choice, Hands' settings, whether you have
  seen the first-use warning, the measured transfer speed for rig time estimates). The app icon colour you pick is
  kept by iOS.

None of this is sent anywhere by the app. Deleting the app deletes it.

## Bluetooth and motion

- **Bluetooth** is used only if you open Bluetooth MIDI in Settings to pair a MIDI device.
- **Motion** (the phone's tilt) is read only on the Hands screen while you hold its tilt pad, and is turned into MIDI
  for your FM-1 at once. It is not recorded or sent anywhere else.

## Your synth

Everything the app sends over the USB cable goes to the FM-1 you plugged in: the installer pages' messages and the
modules you choose to put on it. Nothing is read back from the FM-1 except what those operations need (which
firmware and modules it runs, and its free space).

## Questions

Open an issue at <https://github.com/KonradHerman/fm1-manager/issues>. This policy describes version 1.0 and will be
updated in this repository if the app changes.
