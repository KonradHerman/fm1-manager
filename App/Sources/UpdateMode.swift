// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import SwiftUI

extension AppModel {
	/// An FM-1 waiting in its update loader: an install that did not finish. Told by the port name alone (nothing is
	/// sent to find out): Felucca-based loaders show "Felucca Update" (or "<firmware> Update", as macOS may keep an
	/// earlier name), M-VAVE's own shows "OTA" (fm1-dock's install/ports.js, the Firmware Hub's FM1_PORT).
	static func isUpdateLoader(_ name: String) -> Bool {
		name.range(of: #"\bupdate\b|\bota\b"#, options: [.regularExpression, .caseInsensitive]) != nil
	}

	/// The FM-1's port when it is in update mode.
	var fm1InUpdateMode: MIDIEndpointInfo? { fm1.flatMap { Self.isUpdateLoader($0.name) ? $0 : nil } }
}

/// What update mode means and what to do: on the home screen's device card, and over an installer page once its
/// install has stopped.
struct UpdateModeGuide: View {
	let port: String
	var compact = false
	@Environment(\.openURL) private var openURL

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Label("FM-1 in update mode", systemImage: "exclamationmark.arrow.circlepath")
				.font(compact ? .subheadline.weight(.semibold) : .headline).foregroundStyle(.orange)
			Text("An install did not finish, so the FM-1 waits in its update loader (it shows as “\(port)”). It stays there, safely, until an install finishes.")
				.font(.footnote)
			Text("1. Open the installer you used and install the same firmware again: an installer that can resume this loader finishes the job. (The Firmware Hub resumes only Felucca's and SLOOP's loaders; for another firmware's it says “foreign” and offers Back to official V15.)")
				.font(.footnote)
			Text("2. If it stops at the same point again, or no installer will resume it, the phone cannot fix it: use a computer (the installer page in Chrome, or M-Flasher for the chip's own download mode).")
				.font(.footnote)
			Button("Recovery notes") { openURL(Links.recovery) }.font(.footnote.weight(.semibold))
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
