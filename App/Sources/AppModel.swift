// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The pages the app opens, and the origins that get Web MIDI (no other page does).
struct Site: Identifiable, Hashable {
	let id: String
	let title: String
	let detail: String
	let url: URL
	let symbol: String

	static let hub = Site(id: "hub", title: "FM-1 Firmware Hub", detail: "thefirmwarehub.com: install whole firmwares",
	                      url: URL(string: "https://thefirmwarehub.com/")!, symbol: "square.stack.3d.up")
	/// Baud Girl (FM-1+VA, by Madeline): a firmware that is not open source; its maker's own installer, live from
	/// baudgirl.com (nothing of it is in the app), in both configurations.
	static let baudGirl = Site(id: "baudgirl", title: "Baud Girl (FM-1+VA)",
	                           detail: "baudgirl.com: its maker's own installer; not open source",
	                           url: URL(string: "https://baudgirl.com/work/FM-1+VA/install")!, symbol: "waveform.path")
	#if FM1_DOCK
	static let dock = Site(id: "dock", title: "fm1-dock", detail: "Joakim Eriksson's fm1-dock firmware: install it, add and remove its modules",
	                       url: URL(string: "https://joakimeriksson.github.io/fm1-dock/")!, symbol: "puzzlepiece.extension")
	static let local = Site(id: "local", title: "Install from Library", detail: "Your .fwsc and .dock files, offline",
	                        url: URL(string: "fm1dock://app/local.html")!, symbol: "tray.full")
	static let all = [hub, dock, baudGirl, local]

	/// The hosts that open in the app (anything else goes to Safari) and get Web MIDI.
	static let hosts = ["thefirmwarehub.com", "fm1.designburgapps.com", "joakimeriksson.github.io", "baudgirl.com"]
	static let midiOrigins = hosts.map { "https://\($0)" } + ["fm1dock://app"]
	#else
	// hub-only (FM1_DOCK off): the Firmware Hub alone; fm1-dock's site and the bundled offline page are not in the app
	static let all = [hub, baudGirl]
	static let hosts = ["thefirmwarehub.com", "fm1.designburgapps.com", "baudgirl.com"]
	static let midiOrigins = hosts.map { "https://\($0)" }
	#endif
	static let scheme = "fm1dock"

	static func opensInApp(_ url: URL) -> Bool {
		#if FM1_DOCK
		if url.scheme == scheme { return true }
		#endif
		if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return true }
		guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
		return hosts.contains(host)
	}
}

extension UTType {
	static let fwsc = UTType(importedAs: "com.klhoud.fm1.fwsc")
	static let dockModule = UTType(importedAs: "com.klhoud.fm1.dock")
}

/// The app's .fwsc and .dock files: its Documents folder, which Files shows as On My iPhone > FM-1 Manager.
@MainActor @Observable
final class Library {
	let folder: URL
	private(set) var files: [URL] = []
	var lastError: String?

	init(folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
		self.folder = folder
		refresh()
	}

	func refresh() { files = LocalSchemeHandler.libraryFiles(folder) }

	/// Copies files in (from the importer, a share or "Open in"); a name already there gets a number.
	@discardableResult
	func add(_ urls: [URL]) -> [URL] {
		var added: [URL] = []
		for url in urls {
			let scoped = url.startAccessingSecurityScopedResource()
			defer { if scoped { url.stopAccessingSecurityScopedResource() } }
			if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
			let dest = freeName(url.lastPathComponent)
			do {
				try FileManager.default.copyItem(at: url, to: dest)
				added.append(dest)
			} catch { lastError = "\(url.lastPathComponent): \(error.localizedDescription)" }
		}
		cleanInbox()
		refresh()
		return added
	}

	func delete(_ url: URL) {
		do { try FileManager.default.removeItem(at: url) } catch { lastError = error.localizedDescription }
		refresh()
	}

	private func freeName(_ name: String) -> URL {
		let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
		var url = folder.appendingPathComponent(name), n = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
			n += 1
		}
		return url
	}

	/// (iOS puts files opened from other apps in Documents/Inbox: they are copied out, so it goes)
	private func cleanInbox() {
		try? FileManager.default.removeItem(at: folder.appendingPathComponent("Inbox"))
	}

	static func kind(_ url: URL) -> String {
		switch url.pathExtension.lowercased() {
		case "fwsc": "Firmware"
		case "dock", "hrbr": "fm1-dock module"
		default: "File"
		}
	}
}

/// CoreMIDI for the whole app (every page shares it) and what is plugged in.
@MainActor @Observable
final class AppModel {
	private(set) var engine: MIDIEngine?
	private(set) var endpoints: [MIDIEndpointInfo] = []
	private(set) var engineError: String?
	let library = Library()
	/// A screen asks to go somewhere from inside a sheet (FM1DockApp follows it).
	var requestedRoute: Route?
	#if FM1_DOCK
	@ObservationIgnored lazy var rigs = RigStore(documents: library.folder)
	#endif
	var packetAPI: MIDIEngine.PacketAPI {
		didSet {
			UserDefaults.standard.set(packetAPI.rawValue, forKey: "packetAPI")
			startEngine()
		}
	}
	private var observation: MIDIEngine.Observation?

	#if DEBUG
	@ObservationIgnored private var demoFilter: MIDIEngine.Filter?
	#endif

	init() {
		#if DEBUG
		demoFilter = DemoMode.prepare(documents: library.folder)
		library.refresh()
		#endif
		packetAPI = MIDIEngine.PacketAPI(rawValue: UserDefaults.standard.string(forKey: "packetAPI") ?? "") ?? .universal
		startEngine()
	}

	func startEngine() {
		// (as the unit tests' host the app opens no MIDI at all: the tests make their own, limited to their fake FM-1)
		if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { engineError = "not in tests"; return }
		observation?.cancel()
		observation = nil
		engine = nil
		do {
			// every port, as a browser shows them: the pages pick the FM-1 by its name
			var filter: MIDIEngine.Filter = { _ in true }
			#if DEBUG
			if let demo = demoFilter { filter = demo }             // (-FM1Demo: the simulated FM-1 alone)
			#endif
			let e = try MIDIEngine(clientName: "FM-1 Manager", inputAPI: packetAPI, outputAPI: packetAPI, filter: filter)
			engine = e
			engineError = nil
			observation = e.observe(endpoints: { [weak self] list in onMain { self?.endpoints = list } },
			                        messages: { _ in })
		} catch {
			engineError = "CoreMIDI did not start: \(error)"
		}
	}

	/// The names an FM-1 (or an SMK-37, or their update loaders) shows, as the installers look for them
	/// (install/ports.js LOOKS, the hub's FM1_PORT), without the generic USB-MIDI names.
	static func looksLikeFM1(_ name: String) -> Bool {
		name.range(of: #"felucca|fm1-dock|fm-?1|dinghy|smk|elite|mke-?p37|starry|m-?vave|sinco|sloop|clipper|etch|jiant|\bota\b|update|vibe fm"#,
		           options: [.regularExpression, .caseInsensitive]) != nil
	}

	/// The FM-1's port if one is plugged in (its output: where installs go).
	var fm1: MIDIEndpointInfo? { endpoints.first { $0.kind == .output && Self.looksLikeFM1($0.name) } }
	/// The other MIDI devices there are.
	var otherDevices: [String] {
		Array(Set(endpoints.filter { !Self.looksLikeFM1($0.name) }.map(\.name))).sorted()
	}
}
