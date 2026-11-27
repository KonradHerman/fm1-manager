Closes #

## What changes for the person using the app

## How it was checked

- [ ] `cd FM1Kit && FM1_OFFLINE=1 swift test` passes
- [ ] The app's tests pass in the simulator (and with `FM1_DOCK=NO` if the change touches both builds)
- [ ] Anything that talks to the device has a test against the simulated FM-1; no test talks to a real synth
- [ ] Tried on a real FM-1 (say which: chip, firmware), or not
- [ ] Docs, CHANGELOG.md and SUPPORT.md updated if what a user sees or should do changed
