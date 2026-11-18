# App Store listing: FM-1 Manager 1.0

Ready-to-paste text. Lengths are checked against the App Store limits (in brackets).

## Name (30)

FM-1 Manager

## Subtitle (30)

Unofficial companion for FM-1

## Promotional text (170)

Install firmware and fm1-dock modules on your M-VAVE FM-1 from your iPhone, over a USB cable: the FM-1 Firmware Hub and fm1-dock in an app with Web MIDI.

## Description (4000)

FM-1 Manager installs firmware and modules on the M-VAVE FM-1 synthesizer from your iPhone.

The FM-1's community installers are web pages that talk to the synth over Web MIDI, which Safari on the iPhone does not have. FM-1 Manager opens those pages, the FM-1 Firmware Hub and fm1-dock's page, unchanged, and connects them to your FM-1 over a USB cable. Everything they can do on a computer with Chrome, they can do here: choose a firmware and install it, install fm1-dock, add and remove its modules.

What you need: an M-VAVE FM-1 and a USB cable that carries data (USB-C to USB-C on a USB-C iPhone; on a Lightning iPhone, Apple's Lightning to USB 3 Camera Adapter with power).

Also in the app:
• A library: keep .fwsc firmware and .dock module files on the phone (in the Files app, or shared from Safari or Mail) and install them without a network connection.
• App icon colours to match your FM-1.

Experimental (new, and may change or misbehave):
• Rigs: save the set of fm1-dock modules on your FM-1, keep several sets on the phone, and put one back on in one go. Only what differs is removed or added, and the FM-1 is checked after every step.
• Hands: an unfinished touch keyboard, XY pad and tilt control that play the FM-1.

Please read before you install anything: this app writes firmware and modules to your synth. A cut cable or a bug can leave the FM-1 in update mode; that is usually fixed by installing the same firmware again, and the support page lists the recovery steps, some of which need a computer. You use it at your own risk.

FM-1 Manager is unofficial: it is not made by, affiliated with or endorsed by M-VAVE, the FM-1 Firmware Hub or fm1-dock. It is open source under the GPL-3.0 licence, and it collects no data: no account, no analytics, no tracking.

## Keywords (100)

fm-1,m-vave,synth,synthesizer,firmware,midi,sysex,usb midi,modules,installer,web midi,patch

## What's new in 1.0 (4000)

First release: the FM-1 Firmware Hub and fm1-dock's page with Web MIDI over USB, a library of firmware and module files with an offline installer, and two experimental features, Rigs and Hands.

## URLs

- Support URL: https://github.com/KonradHerman/fm1-manager/blob/main/SUPPORT.md
- Privacy policy URL: https://github.com/KonradHerman/fm1-manager/blob/main/PRIVACY.md
- Marketing URL: https://github.com/KonradHerman/fm1-manager

## Category

- Primary: Music
- Secondary: Utilities

## Age rating answers

Every content question (violence, sexual content, profanity, drugs, gambling, horror, medical, contests and so on): **None**.

- **Unrestricted web access: No.** The app shows web pages only from an allow-list (thefirmwarehub.com,
  fm1.designburgapps.com, joakimeriksson.github.io, and its own built-in pages; `Site.opensInApp` in
  App/Sources/AppModel.swift). There is no address bar; any other link, including links inside those sites, opens in
  Safari, outside the app. Note for the owner: the allowed sites are third-party and could change their content; if
  Apple sees it differently, answering Yes only raises the rating to 17+.
- Messaging and chat, user-generated content shown by the app, gambling, contests, loot boxes: No.
- Made for kids: No.

## App Privacy questionnaire

**Data Not Collected.**

Reasoning:
- The app has no server, no account, no analytics, advertising or crash-reporting SDK, and no third-party code
  besides fm1-dock's installer JavaScript, which runs locally and talks only to the FM-1.
- Its own network requests (the module catalogue) only download public files; nothing about the user is sent.
- Library files, rigs and settings stay on the device (see PRIVACY.md).
- Tracking: No (the privacy manifest declares NSPrivacyTracking false and no tracking domains).
- The two installer sites are third-party websites shown in a web view; what they collect follows their own
  policies, and the developer receives none of it. Note for the owner: the Firmware Hub page includes its own
  statistics script (Matomo-style `_paq`) and optional sign-in. Apple's definition counts data collected by
  "third-party partners whose code you integrate"; a third-party website you display is usually not that, but this is
  the judgment call to be aware of.

## App Review notes

FM-1 Manager is a companion app for a hardware synthesizer, the M-VAVE FM-1, which connects to the iPhone as a
class-compliant USB MIDI device (USB-C cable, or Apple's camera adapter on Lightning iPhones). It is unofficial and
open source (GPL-3.0): https://github.com/KonradHerman/fm1-manager. No account or sign-in is needed.

Its main purpose: the FM-1's firmware installers are web pages that need Web MIDI, which iOS browsers lack. The app
shows two of them (thefirmwarehub.com and joakimeriksson.github.io/fm1-dock) and gives them Web MIDI through
CoreMIDI. It shows only those sites; other links open in Safari.

Without an FM-1 you can:
- see the home screen, which says "No FM-1 connected" and explains how to connect one;
- open both installer sites; they load and their own Connect buttons report that no FM-1 was found (the first time,
  the app shows a one-time warning that it writes to the synth);
- open "Install from Library" and the Library, and import a file with the + button (any .dock or .fwsc file);
- in the Experimental section: create and edit a rig, and download a module from fm1-dock's public catalogue
  ("Get modules from fm1-dock's catalogue"); applying a rig and "Save what's on my FM-1" need an FM-1 and are
  disabled without one;
- open Hands, which shows its keyboard, XY pad and tilt control dimmed under "No FM-1 connected";
- in Settings: change the app icon colour, open Bluetooth MIDI pairing, open About (version, links, licence).

With an FM-1, the installer pages install firmware and modules on it over USB. A video of the app used with a real
FM-1 can be provided on request. [Owner: consider attaching one; hardware-dependent apps are often asked for it.]

Bluetooth is used only when the user opens Bluetooth MIDI pairing in Settings; motion only on the Hands screen while
its tilt pad is held.

## Screenshots

`store/screenshots/` (1320 x 2868, iPhone 17 Pro Max simulator, made by `scripts/screenshots.sh` with a simulated
FM-1):

1. `1-home.png`: home, FM-1 connected
2. `2-firmware-hub.png`: the Firmware Hub, connected
3. `3-fm1-dock.png`: fm1-dock's page, connected
4. `4-library.png`: the library
5. `5-rig-plan.png`: a rig's plan before Apply
6. `6-icon-colours.png`: Settings with the icon colours
7. `7-hands.png`: Hands (shows "No motion sensor": the simulator has none; on a phone it reads "Hold to tilt")
