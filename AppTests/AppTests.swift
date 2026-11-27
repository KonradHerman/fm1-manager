// SPDX-License-Identifier: GPL-3.0-only
import CoreMotion
import FM1Kit
import WebKit
import XCTest
@testable import FM1Dock


#if FM1_DOCK
private let fm1Dock = true
#else
private let fm1Dock = false
#endif

@MainActor
final class SiteTests: XCTestCase {
	func testWhatOpensInTheAppAndGetsMIDI() {
		XCTAssertTrue(Site.opensInApp(URL(string: "https://thefirmwarehub.com/convert/")!))
		XCTAssertFalse(Site.opensInApp(URL(string: "https://github.com/joakimeriksson/fm1-dock")!))
		XCTAssertFalse(Site.opensInApp(URL(string: "http://thefirmwarehub.com/")!))
		XCTAssertFalse(Site.opensInApp(URL(string: "https://evil.thefirmwarehub.com.example/")!))
		XCTAssertTrue(Site.opensInApp(URL(string: "https://baudgirl.com/work/FM-1+VA/install")!))
		XCTAssertFalse(Site.opensInApp(URL(string: "https://www.baudgirl.com/")!), "baudgirl.com exactly")
		#if FM1_DOCK
		XCTAssertTrue(Site.opensInApp(URL(string: "https://joakimeriksson.github.io/fm1-dock/midi.html")!))
		XCTAssertTrue(Site.opensInApp(URL(string: "fm1dock://app/local.html")!))
		XCTAssertEqual(Set(Site.midiOrigins), ["https://thefirmwarehub.com", "https://fm1.designburgapps.com",
		                                       "https://joakimeriksson.github.io", "https://baudgirl.com", "fm1dock://app"])
		XCTAssertEqual(Site.all.map(\.id), ["hub", "dock", "baudgirl", "local"])
		#else
		XCTAssertFalse(Site.opensInApp(URL(string: "https://joakimeriksson.github.io/fm1-dock/midi.html")!))
		XCTAssertFalse(Site.opensInApp(URL(string: "fm1dock://app/local.html")!))
		XCTAssertEqual(Set(Site.midiOrigins), ["https://thefirmwarehub.com", "https://fm1.designburgapps.com", "https://baudgirl.com"])
		XCTAssertEqual(Site.all.map(\.id), ["hub", "baudgirl"])
		#endif
	}

	/// Hub-only (FM1_DOCK off): none of fm1-dock's files, nor the offline page, is in the app at all.
	func testHubOnlyBundleCarriesNoFM1DockFiles() throws {
		#if FM1_DOCK
		throw XCTSkip("FM1_DOCK build: the offline page is bundled")
		#else
		XCTAssertNil(Bundle.main.url(forResource: "web", withExtension: nil))
		let all = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)!
			.compactMap { ($0 as? URL)?.lastPathComponent }
		for name in ["dock.js", "fm1install.js", "fm1ota.js", "ports.js", "local.html", "local.js", "rigs.html", "rigs.js"] {
			XCTAssertFalse(all.contains(name), name)
		}
		XCTAssertNotNil(Bundle.main.url(forResource: "GPL-3.0", withExtension: "txt"), "the app's own licence text")
		#endif
	}

	func testUpdateModeIsToldByThePortName() {
		for n in ["Felucca Update", "JIANT Update", "FM-1 Update", "OTA", "ota", "FM-1 Update Test 1A2B3C4D"] {
			XCTAssertTrue(AppModel.isUpdateLoader(n), n)
		}
		for n in ["FM-1", "Felucca", "SLOOP", "Rotary Controller", "Updated Synth"] {
			XCTAssertFalse(AppModel.isUpdateLoader(n), n)
		}
	}

	func testFM1PortNames() {
		for n in ["FM-1", "FM1", "Felucca", "Felucca Update", "fm1-dock", "SMK-37 Pro", "M-VAVE FM-1", "FM-1 Update", "SLOOP"] {
			XCTAssertTrue(AppModel.looksLikeFM1(n), n)
		}
		for n in ["IAC Driver Bus 1", "Network Session 1", "Arturia KeyStep 37", "Rotary Controller"] {
			XCTAssertFalse(AppModel.looksLikeFM1(n), n)
		}
	}
}

@MainActor
final class LibraryTests: XCTestCase {
	func testAddCopiesInWithoutOverwriting() throws {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let lib = tmp.appendingPathComponent("lib"), src = tmp.appendingPathComponent("src")
		try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: tmp) }
		let a = src.appendingPathComponent("fm1-dock-0.7.fwsc")
		try Data([1, 2, 3]).write(to: a)
		let library = Library(folder: lib)
		library.add([a])
		library.add([a])
		XCTAssertEqual(library.files.map(\.lastPathComponent), ["fm1-dock-0.7 2.fwsc", "fm1-dock-0.7.fwsc"])
		XCTAssertEqual(Library.kind(library.files[0]), "Firmware")
		library.delete(library.files[0])
		XCTAssertEqual(library.files.count, 1)
	}

	/// The offline site in the app bundle keeps fm1-dock's tree (web/install/...), and the library is served beside it.
	func testTheBundledSiteAndTheLibraryAreServed() throws {
		try XCTSkipUnless(fm1Dock, "hub-only build: no offline page")
		let web = try XCTUnwrap(Bundle.main.url(forResource: "web", withExtension: nil))
		let lib = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: lib) }
		try Data("x".utf8).write(to: lib.appendingPathComponent("a.dock"))
		let resolve = LocalSchemeHandler.site(root: web, library: lib)
		for path in ["local.html", "local.js", "dock.js", "install/fm1install.js", "install/fm1ota.js", "install/ports.js", "LICENSE.txt"] {
			XCTAssertNotNil(resolve(URL(string: "fm1dock://app/\(path)")!), path)
		}
		XCTAssertEqual(resolve(URL(string: "fm1dock://app/install/fm1install.js")!)?.mimeType, "text/javascript; charset=utf-8")
		XCTAssertNil(resolve(URL(string: "fm1dock://app/../../etc/passwd")!))
		XCTAssertNil(resolve(URL(string: "fm1dock://app/library/..%2Fx")!))
		let index = try XCTUnwrap(resolve(URL(string: "fm1dock://app/library/index.json")!))
		let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: index.data) as? [[String: Any]])
		XCTAssertEqual(list.first?["name"] as? String, "a.dock")
		XCTAssertEqual(resolve(URL(string: "fm1dock://app/library/a.dock")!)?.data, Data("x".utf8))
		// every vendored file keeps its GPL-3.0 header
		for path in ["dock.js", "install/fm1install.js", "install/fm1ota.js", "install/ports.js"] {
			let text = String(decoding: resolve(URL(string: "fm1dock://app/\(path)")!)!.data, as: UTF8.self)
			XCTAssertTrue(text.hasPrefix("// SPDX-License-Identifier: GPL-3.0-only"), path)
		}
	}
}

/// In the simulator: iOS's WebKit and CoreMIDI, the app's offline page, a FakeFM1 on virtual endpoints (the
/// engine's filter admits nothing else).
@MainActor
final class SimulatorEndToEndTests: XCTestCase {
	func testOfflinePageAddsAModuleOnIOS() async throws {
		try XCTSkipUnless(fm1Dock, "hub-only build: no offline page")
		let web = try XCTUnwrap(Bundle.main.url(forResource: "web", withExtension: nil))
		let lib = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: lib) }
		let blob = SyntheticDock.make(name: "ARP 2600", kib: 16)      // (a made-up module of that name: no fm1-dock checkout needed)
		try blob.write(to: lib.appendingPathComponent("arp2600.dock"))

		let fake = try FakeFM1()
		let h = try WebHarness(filter: fake.filter, resolver: LocalSchemeHandler.site(root: web, library: lib))
		defer { h.close() }
		let t0 = Date()
		while h.engine.endpoints.count < 2 && Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 50_000_000) }
		XCTAssertEqual(h.engine.endpoints.count, 2, "the simulator's CoreMIDI shows the virtual endpoints")
		try await h.load(URL(string: "fm1dock://app/local.html")!)
		try await h.waitFor("!!document.querySelector('button[data-file=\"arp2600.dock\"]')")
		try await h.js("document.querySelector('button[data-file=\"arp2600.dock\"]').click()")
		try await h.waitFor("document.getElementById('status').textContent.startsWith('Done')", timeout: 30)
		XCTAssertEqual(fake.deployedModules.first?.blob, [UInt8](blob))
	}

	func testWebMIDIShimOnIOS() async throws {
		let fake = try FakeFM1()
		let page = "<!doctype html><script>window.go = async (n, d) => { const a = await navigator.requestMIDIAccess({ sysex: true }); const o = [...a.outputs.values()].find((p) => p.name === n); const i = [...a.inputs.values()].find((p) => p.name === n); window.got = []; i.onmidimessage = (e) => got.push(Array.from(e.data)); o.send(new Uint8Array(d)); return a.inputs.size + a.outputs.size; }</script>"
		let h = try WebHarness(filter: fake.filter, resolver: { _ in (Data(page.utf8), "text/html") })
		defer { h.close() }
		try await h.load(URL(string: "fm1dock://app/index.html")!)
		let sysex: [UInt8] = [0xF0, 0x7D] + (0..<697).map { UInt8($0 % 128) } + [0xF7]
		let t0 = Date()
		while h.engine.endpoints.count < 2 && Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 50_000_000) }
		let n = try await h.js("return await go(name, data)", ["data": sysex.map(Int.init), "name": fake.portName]) as? Int
		XCTAssertEqual(n, 2)
		let t1 = Date()
		while fake.received.isEmpty && Date().timeIntervalSince(t1) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
		XCTAssertEqual(fake.received, [sysex])
		fake.emit(packetLists: [[[0xF0, 1, 2]], [[3, 4]], [[0xF8]], [[5, 0xF7, 0x90, 60, 100]]])
		try await h.waitFor("window.got.length >= 3", timeout: 5)
		let got = try await h.js("return window.got") as? [[Int]]
		XCTAssertEqual(got, [[0xF8], [0xF0, 1, 2, 3, 4, 5, 0xF7], [0x90, 60, 100]])
	}
}

@MainActor
final class AppIconTests: XCTestCase {
	/// Every colour in Settings is an alternate icon the built app declares, and has its preview image; the app is
	/// iPhone only (1.0). (The asset compiler still writes a CFBundleIcons~ipad copy for the universal icon sets; iOS
	/// ignores it on an iPhone-only app.)
	func testTheIconChoicesMatchTheBundle() throws {
		let names = Set(AppIconChoice.all.compactMap(\.name))
		XCTAssertEqual(names.count, AppIconChoice.all.count - 1, "one primary (nil), the rest named")
		// the file itself: infoDictionary folds the ~ipad keys away on an iPhone
		let url = try XCTUnwrap(Bundle.main.url(forResource: "Info", withExtension: "plist"))
		let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
		let icons = try XCTUnwrap(plist["CFBundleIcons"] as? [String: Any])
		let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
		XCTAssertEqual(Set(alternates.keys), names)
		XCTAssertEqual(plist["UIDeviceFamily"] as? [Int], [1], "iPhone only")
		for choice in AppIconChoice.all { XCTAssertNotNil(UIImage(named: choice.preview), choice.preview) }
	}
}


/// Hands in the app, on iOS's CoreMIDI, to a virtual destination (a FakeFM1; the engine sees nothing else).
@MainActor
final class HandsAppTests: XCTestCase {
	func testHandsModelSendsToTheFM1AndLeavesNothingOn() async throws {
		let fake = try FakeFM1()
		let engine = try MIDIEngine(clientName: "hands app test", filter: fake.filter)
		let t0 = Date()
		while engine.endpoints.count < 2 && Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
		let out = try XCTUnwrap(engine.endpoints.first { $0.kind == .output })
		let model = HandsModel()
		model.connect(engine, out)                                 // (opening the screen sends nothing)
		model.hands.touchDown(1, note: 60, velocity: 100)
		model.hands.touchMoved(1, note: 62, velocity: 100)
		model.xyMoved(CGPoint(x: 1, y: 0))
		model.stop()                                              // leaving the screen with a finger down
		model.connect(engine, nil)                                // unplugged: forgotten, nothing to send
		model.hands.touchDown(2, note: 70, velocity: 100)         // (goes nowhere)
		model.connect(engine, out)                                // back: a panic again
		try await Task.sleep(nanoseconds: 300_000_000)
		let got = fake.received
		XCTAssertEqual(got.filter { $0.first == 0x90 }.map { $0[1] }, [60, 62])
		XCTAssertTrue(got.contains([0x80, 62, 0]))
		XCTAssertEqual(got.filter { $0 == [0xB0, 123, 0] }.count, 1, "a panic on the replug only")
		XCTAssertFalse(got.contains([0x90, 70, 100]), "nothing sent while unplugged")
		XCTAssertTrue(got.contains([0xB0, model.settings.x == .cc(74) ? 74 : 0, 127]) || model.settings.x != .cc(74))
	}

	/// CoreMotion calls the tilt handler on its own queue; the simulator has no device motion, so a motion manager
	/// that only keeps the handler HandsModel.start() gives it lets the test call it from a background queue, as
	/// CoreMotion would. With the handler written inside the @MainActor method (build 4's crash) this traps.
	func testTheMotionHandlerRunsOffTheMainThread() async {
		let motion = CapturingMotionManager()
		let model = HandsModel(motion: motion)
		model.start()
		guard let handler = motion.handler else { return XCTFail("start() gave CoreMotion no handler") }
		nonisolated(unsafe) let h = handler
		let done = expectation(description: "called on a background queue")
		DispatchQueue.global().async {
			XCTAssertFalse(Thread.isMainThread)
			h(nil, nil)
			done.fulfill()
		}
		await fulfillment(of: [done], timeout: 2)
	}

	func testHandsSettingsPersist() {
		let model = HandsModel()
		let before = model.settings
		defer { model.settings = before }
		model.settings.channel = 9
		model.settings.tilt = .pitchBend
		XCTAssertEqual(HandsSettings.load().channel, 9)
		XCTAssertEqual(HandsSettings.load().tilt, .pitchBend)
	}
}

#if FM1_DOCK
@MainActor
final class RigsAppTests: XCTestCase {
	func testRigStoreKeepsRigsAsFilesBesideTheLibrary() throws {
		let docs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: docs) }
		let store = RigStore(documents: docs)
		var rig = Rig(name: "Night", modules: [])
		store.save(rig)
		XCTAssertTrue(FileManager.default.fileExists(atPath: docs.appendingPathComponent("Rigs/Night.fm1rig.json").path))
		rig.name = "Day"
		store.save(rig)
		XCTAssertEqual(store.rigs.map(\.name), ["Day"])
		XCTAssertFalse(FileManager.default.fileExists(atPath: docs.appendingPathComponent("Rigs/Night.fm1rig.json").path))
		store.duplicate(store.rigs[0])
		XCTAssertEqual(store.rigs.map(\.name), ["Day", "Day copy"])
		XCTAssertTrue(Library(folder: docs).files.isEmpty, "the Rigs folder is not a library file")
		store.delete(store.rigs[0])
		XCTAssertEqual(store.rigs.count, 1)
	}

	/// The app's rigs.html (fm1-dock's dock.js) over iOS's WebKit and CoreMIDI: a rig put on a FakeFM1.
	/// A file a page saves (<a download>, as Baud Girl's installer saves a preset backup) lands in the library.
	func testAPageDownloadIsSavedInTheLibrary() async throws {
		let lib = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: lib) }
		let html = "<!doctype html><script>onload = () => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([new Uint8Array([1, 2, 3])])); a.download = 'presets-backup.bin'; document.body.append(a); a.click(); }</script>"
		let fake = try FakeFM1()
		let engine = try MIDIEngine(clientName: "download test", filter: fake.filter)
		let site = Site(id: "t", title: "t", detail: "",
		                url: URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!, symbol: "doc")
		let page = WebPage(site: site, engine: engine, library: lib)
		let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
		w.addSubview(page.webView)
		w.isHidden = false
		defer { page.close(); w.isHidden = true }
		let file = lib.appendingPathComponent("presets-backup.bin")
		let end = Date().addingTimeInterval(10)
		while !FileManager.default.fileExists(atPath: file.path) && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
		try await Task.sleep(nanoseconds: 300_000_000)
		XCTAssertEqual(try? Data(contentsOf: file), Data([1, 2, 3]))
		XCTAssertEqual(page.toast, "Saved presets-backup.bin in the library (Files › FM-1 Manager).")
	}

	func testApplyARigOnIOS() async throws {
		let web = try XCTUnwrap(Bundle.main.url(forResource: "web", withExtension: nil))
		let lib = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: lib) }
		var mods: [RigModule] = []
		for (n, k) in [("ECHO", 24), ("FOXTROT", 40)] {
			let d = SyntheticDock.make(name: n, kib: k)
			try d.write(to: lib.appendingPathComponent("\(n).dock"))
			mods.append(RigModule(try DockModuleFile(d), file: "\(n).dock"))
		}
		let fake = try FakeFM1()
		let engine = try MIDIEngine(clientName: "rigs app test", filter: fake.filter)
		let link = WebDockLink(engine: engine, resolver: LocalSchemeHandler.site(root: web, library: lib))
		let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
		w.addSubview(link.webView)
		w.isHidden = false
		defer { link.close(); w.isHidden = true }
		let t0 = Date()
		while engine.endpoints.count < 2 && Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
		let rig = Rig(name: "R", modules: mods, select: "ECHO")
		let state = try await RigApplier.readForPlanning(link)
		let modules = LibraryModule.scan(lib)
		let plan = try RigPlanner.plan(rig: rig, device: state, library: modules).get()
		let out = await RigApplier(link: link, libraryFolder: lib).run(plan, rig: rig, library: modules) { _ in }
		guard case let .finished(_, issues, _) = out else { return XCTFail("\(out)") }
		XCTAssertEqual(issues, [])
		XCTAssertEqual(Set(fake.layout.map(\.name)), ["ECHO", "FOXTROT"])
		XCTAssertEqual(fake.current, "ECHO")
	}
}
#endif

/// A motion manager that says it has device motion and keeps the handler instead of starting the sensor.
final class CapturingMotionManager: CMMotionManager, @unchecked Sendable {
	var handler: CMDeviceMotionHandler?
	override var isDeviceMotionAvailable: Bool { true }
	override var isDeviceMotionActive: Bool { handler != nil }
	override func startDeviceMotionUpdates(to queue: OperationQueue, withHandler handler: @escaping CMDeviceMotionHandler) {
		self.handler = handler
	}
	override func stopDeviceMotionUpdates() { handler = nil }
}
