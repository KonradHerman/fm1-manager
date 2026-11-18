// SPDX-License-Identifier: GPL-3.0-only
// Debug builds only: the store screenshots' demo. Launched with -FM1Demo, the app gets a simulated FM-1 (FakeFM1,
// named "FM-1", running fm1-dock 0.9 with three modules on it) on virtual CoreMIDI endpoints, and its MIDI engine
// sees those endpoints and nothing else (a real FM-1 plugged into the Mac is never listed or sent to). The library
// gets a few made-up modules and the Rigs three example rigs. ios/scripts/screenshots.sh drives it.
//   -FM1Open home|hub|dock|local|library|hands|rig|plan   the screen to open on
//   -FM1Click <CSS selector>                               clicked once the page has loaded (an installer's Connect)
//   -FM1ShowAppIcons                                       the home screen scrolled to the icon colours
#if DEBUG
import FM1Kit
import Foundation

@MainActor
enum DemoMode {
	static let args = ProcessInfo.processInfo.arguments
	static var isOn: Bool { args.contains("-FM1Demo") }
	static func value(_ flag: String) -> String? {
		guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
		return args[i + 1]
	}

	private(set) static var fake: FakeFM1?

	/// The made-up modules: name, KiB in flash, file name.
	static let modules: [(String, Int, String)] = [
		("ARP 2600", 16, "arp2600.dock"), ("AMB-1", 76, "amb.dock"), ("KEYS", 40, "keys.dock"), ("PROPHET", 120, "prophet.dock"),
		("MINIPOPS", 24, "minipops.dock"), ("EMINENT", 32, "eminent.dock"), ("FMINI-1", 64, "fmini.dock"), ("ENSEMBLE", 48, "ensemble.dock"),
	]
	static func blob(_ name: String, _ kib: Int) -> Data { SyntheticDock.make(name: name, version: 3, kib: kib, seed: UInt8(name.count)) }

	/// Before the engine starts: the fake, the library, the rigs. Returns the engine's filter (the fake's endpoints).
	static func prepare(documents: URL) -> MIDIEngine.Filter? {
		guard isOn else { return nil }
		UserDefaults.standard.set(true, forKey: "warned.writesFirmware")
		guard let f = try? FakeFM1(identity: "FM-1_921", dockVersion: "0.9", product: "FM-1_921", name: "FM-1") else { return { _ in false } }
		var at = FakeFM1.deployArea.lowerBound
		for (name, kib, _) in modules where ["ARP 2600", "AMB-1", "KEYS"].contains(name) {
			f.preload(blob(name, kib), at: at)
			at += kib * 1024
		}
		fake = f
		for (name, kib, file) in modules { try? blob(name, kib).write(to: documents.appendingPathComponent(file)) }
		let rigs = documents.appendingPathComponent("Rigs")
		try? FileManager.default.createDirectory(at: rigs, withIntermediateDirectories: true)
		func module(_ n: String) -> RigModule {
			let m = modules.first { $0.0 == n }!
			return RigModule(try! DockModuleFile(blob(m.0, m.1)), file: m.2)
		}
		let examples = [
			Rig(name: "Analog night", color: "orange", symbol: "moon.stars", modules: ["ARP 2600", "PROPHET", "MINIPOPS"].map(module), select: "PROPHET"),
			Rig(name: "Ambient", color: "teal", symbol: "cloud", modules: ["AMB-1", "EMINENT", "ENSEMBLE"].map(module), select: "AMB-1"),
			Rig(name: "Keys", color: "blue", symbol: "pianokeys", modules: ["KEYS", "FMINI-1", "ARP 2600"].map(module), select: "KEYS"),
		]
		for r in examples { try? r.encoded().write(to: rigs.appendingPathComponent(r.name + Rig.fileSuffix)) }
		return f.idFilter
	}
}
#endif
