#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# The App Store screenshots: a Debug build in an iPhone 17 Pro Max simulator (6.9-inch: 1320 x 2868), launched with
# -FM1Demo, which gives the app a simulated FM-1 (on virtual MIDI endpoints, its engine sees nothing else), example
# library files and rigs (App/Sources/DemoMode.swift). Writes ios/store/screenshots/*.png.
#   ios/scripts/screenshots.sh              # DEVICE="iPhone 17 Pro Max" by default
set -euo pipefail
cd "$(dirname "$0")/.."
device="${DEVICE:-iPhone 17 Pro Max}"
out=store/screenshots
mkdir -p "$out"
udid=$(xcrun simctl list devices available -j | /usr/bin/python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
print(next(x['udid'] for r in d.values() for x in r if x['name'] == sys.argv[1]))" "$device")
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
	--cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
/opt/homebrew/bin/xcodegen >/dev/null
xcodebuild -project FM1Dock.xcodeproj -scheme FM1Dock -configuration Debug -destination "id=$udid" \
	-derivedDataPath build/screenshots -quiet build
app=build/screenshots/Build/Products/Debug-iphonesimulator/FM1Dock.app
xcrun simctl uninstall "$udid" com.klhoud.fm1 2>/dev/null || true
xcrun simctl install "$udid" "$app"

# shot <file> <seconds to wait> [launch arguments...]
shot() {
	local name=$1 wait=$2
	shift 2
	xcrun simctl terminate "$udid" com.klhoud.fm1 2>/dev/null || true
	xcrun simctl launch "$udid" com.klhoud.fm1 -FM1Demo "$@" >/dev/null
	sleep "$wait"
	xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null
	echo "$out/$name.png"
}
shot 1-home 5
shot 2-firmware-hub 14 -FM1Open hub -FM1Click "#connect"
shot 3-fm1-dock 14 -FM1Open dock -FM1Click "#dev-connect"
shot 4-library 5 -FM1Open library
shot 5-rig-plan 12 -FM1Open plan
shot 6-icon-colours 5 -FM1ShowAppIcons
shot 7-hands 5 -FM1Open hands
xcrun simctl terminate "$udid" com.klhoud.fm1 2>/dev/null || true
xcrun simctl status_bar "$udid" clear
