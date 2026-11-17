// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

/// The MIDI core of FM-1 Manager: CoreMIDI in and out, the byte/UMP reassembly, and the Web MIDI bridge a
/// WKWebView page sees as `navigator.requestMIDIAccess`. Builds for macOS too, so `swift test` runs it on a Mac
/// against virtual CoreMIDI endpoints the tests create (never the real devices: see FakeFM1).
let package = Package(
	name: "FM1Kit",
	platforms: [.iOS(.v17), .macOS(.v14)],
	products: [
		.library(name: "FM1Kit", targets: ["FM1Kit"]),
		.library(name: "FM1KitTestSupport", targets: ["FM1KitTestSupport"]),
	],
	targets: [
		.target(name: "FM1Kit", resources: [.copy("Resources/webmidi.js")]),
		// A simulated FM-1 on virtual CoreMIDI endpoints of its own unique name, for the tests here and the app's.
		.target(name: "FM1KitTestSupport", dependencies: ["FM1Kit"]),
		.testTarget(name: "FM1KitTests", dependencies: ["FM1Kit", "FM1KitTestSupport"]),
	]
)
