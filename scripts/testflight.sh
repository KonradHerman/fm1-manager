#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Archive FM-1 Manager and upload it to App Store Connect (-> TestFlight).
#   ios/scripts/testflight.sh                 # as project.yml says (FM1_DOCK: YES, the full build)
#   FM1_DOCK=NO ios/scripts/testflight.sh     # the hub-only build
# Uses the Apple ID signed in to Xcode for signing and upload (automatic signing, the team in project.yml).
# The build number (CURRENT_PROJECT_VERSION in project.yml) must rise with every upload: this bumps it.
# An app record for com.klhoud.fm1 must exist in App Store Connect before the first upload.
set -euo pipefail
cd "$(dirname "$0")/.."
current=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' project.yml)
next=$((current + 1))
team=$(sed -n 's/^ *DEVELOPMENT_TEAM: *\([A-Z0-9]*\)$/\1/p' project.yml | head -1)
[ -n "$team" ] || { echo "No DEVELOPMENT_TEAM in project.yml" >&2; exit 1; }
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$current\"/CURRENT_PROJECT_VERSION: \"$next\"/" project.yml
echo "Build number $current -> $next"
/opt/homebrew/bin/xcodegen >/dev/null
work=$(mktemp -d /tmp/fm1dock-testflight.XXXX)
cat >"$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild archive -project FM1Dock.xcodeproj -scheme FM1Dock -configuration Release \
	-destination "generic/platform=iOS" -archivePath "$work/FM1Dock.xcarchive" \
	-derivedDataPath "$work/dd" -allowProvisioningUpdates -quiet ${FM1_DOCK:+FM1_DOCK=$FM1_DOCK}
log="$work/export.log"
xcodebuild -exportArchive -archivePath "$work/FM1Dock.xcarchive" \
	-exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export" \
	-allowProvisioningUpdates >"$log" 2>&1 || true
grep -E "Upload succeeded|EXPORT (SUCCEEDED|FAILED)|error" "$log" || true
if ! grep -q "EXPORT SUCCEEDED" "$log"; then
	echo "Upload FAILED (build $next). Logs in $work. project.yml was bumped; fix and re-run." >&2
	exit 1
fi
rm -rf "$work"
echo "Uploaded build $next. Apple processes it for ~10-30 min before TestFlight shows it."
