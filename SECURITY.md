# Security policy

FM-1 Manager can write firmware to a synth, so a hole that lets something do that without the person asking is the
kind of problem we most want to hear about. Thank you for looking.

## Reporting a vulnerability

**Please don't open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub: the repository's **Security** tab › **Report a vulnerability**
([direct link](https://github.com/KonradHerman/fm1-manager/security/advisories/new)). Only you and the maintainer
see it.

Please include what an attacker could do and what they need first (a page you open, a file you share to the app,
someone on your network…), the steps to reproduce it, and the app's version and build and your iOS version.

## What counts

- Anything that could make the app send MIDI to a synth that the person did not ask for, above all firmware or
  module writes.
- The allow-list of sites that get Web MIDI (`Site.midiOrigins`): a way for another site, a frame or a redirect to
  get MIDI access.
- The app's URL scheme handler (`fm1dock://app/`): reading files outside the app's own pages and library, or serving
  a page that gets MIDI it should not.
- Files opened in or shared to the app (.fwsc, .dock, rigs) that make it do something unexpected.

Not counted: problems in the installer sites themselves (report those to their makers), or attacks that need
someone who already controls your unlocked phone.

## What to expect

There is one maintainer, so these are aims rather than promises: an answer within a week, a fix for a confirmed
serious problem as soon as it can be made and shipped, and credit in the advisory unless you'd rather not.
