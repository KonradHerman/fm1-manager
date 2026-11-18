// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The app's pages on the web (its public repository).
enum Links {
	static let repo = URL(string: "https://github.com/KonradHerman/fm1-manager")!
	static let privacy = URL(string: "https://github.com/KonradHerman/fm1-manager/blob/main/PRIVACY.md")!
	static let support = URL(string: "https://github.com/KonradHerman/fm1-manager/blob/main/SUPPORT.md")!
	static let recovery = URL(string: "https://github.com/KonradHerman/fm1-manager/blob/main/SUPPORT.md#if-something-goes-wrong")!

	static var version: String {
		let i = Bundle.main.infoDictionary
		return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
	}
}

struct AboutView: View {
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			List {
				Section {
					LabeledContent("Version", value: Links.version)
					Text("Unofficial: not affiliated with M-VAVE, the FM-1 Firmware Hub or fm1-dock.")
					#if FM1_DOCK
					Text("FM-1 Manager gives the FM-1's web installers what Safari on iOS lacks: Web MIDI, over CoreMIDI and USB. The Firmware Hub and fm1-dock's page run as they are; nothing is sent to the FM-1 unless a page, or a rig you apply, sends it.")
						.font(.footnote).foregroundStyle(.secondary)
					#else
					Text("FM-1 Manager gives the FM-1 Firmware Hub what Safari on iOS lacks: Web MIDI, over CoreMIDI and USB. The Hub's page runs as it is; nothing is sent to the FM-1 unless the page sends it.")
						.font(.footnote).foregroundStyle(.secondary)
					#endif
				}
				Section {
					Link(destination: Links.support) { Label("Help and support", systemImage: "questionmark.circle") }
					Link(destination: Links.recovery) { Label("If an install goes wrong", systemImage: "lifepreserver") }
					Link(destination: Links.privacy) { Label("Privacy", systemImage: "hand.raised") }
					Link(destination: Links.repo) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
				} footer: {
					Text("The app collects nothing and has no account. Installing firmware is at your own risk: an install that is cut off leaves the FM-1 in update mode; install the same firmware again to finish it.")
				}
				Section("Licence") {
					#if FM1_DOCK
					Text("Free software under the GNU General Public License, version 3 only (GPL-3.0-only). It carries fm1-dock's installer (dock.js, install/fm1install.js, ports.js by Joakim Eriksson; fm1ota.js by Leo Kuroshita, Hügelton Instruments), unchanged, under that licence.")
						.font(.footnote)
					#else
					Text("Free software under the GNU General Public License, version 3 only (GPL-3.0-only).").font(.footnote)
					#endif
					if let url = Bundle.main.url(forResource: "GPL-3.0", withExtension: "txt"),
					   let text = try? String(contentsOf: url, encoding: .utf8) {
						NavigationLink("GNU General Public License v3") {
							ScrollView { Text(text).font(.caption2.monospaced()).padding() }.navigationTitle("GPL-3.0")
						}
					}
				}
			}
			.navigationTitle("About")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { Button("Done") { dismiss() } }
		}
	}
}

/// Once, the first time an installer page opens or a rig is about to be applied: this app writes to the synth.
struct WritesWarning: ViewModifier {
	@AppStorage("warned.writesFirmware") private var warned = false
	@Environment(\.openURL) private var openURL
	@State private var show = false

	func body(content: Content) -> some View {
		content
			.onAppear { if !warned { show = true } }
			.alert("This writes to your synth", isPresented: $show) {
				Button("I understand") { warned = true }
				Button("Recovery notes") { warned = true; openURL(Links.recovery) }
			} message: {
				Text("Installing firmware or modules changes what is on your FM-1. If an install is cut off or goes wrong, the FM-1 can need a recovery step, some of them on a computer. Know where the recovery notes are before you start.")
			}
	}
}

extension View {
	func warnsAboutWrites() -> some View { modifier(WritesWarning()) }
}
