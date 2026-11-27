// SPDX-License-Identifier: GPL-3.0-only
#if os(macOS)
import AppKit
import FM1Kit
import FM1KitTestSupport
import XCTest

/// Rigs against a FakeFM1 over virtual CoreMIDI: the app's rigs.html driving fm1-dock's own dock.js (WebDockLink),
/// the planner, the applier. The fake places modules as dock.c does (first fit, 4 KiB sectors, 296 KiB).
@MainActor
final class RigsEndToEndTests: XCTestCase {
	var library: URL!
	var window: NSWindow?

	override func setUp() async throws {
		library = FileManager.default.temporaryDirectory.appendingPathComponent("fm1-rigs-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
	}
	override func tearDown() async throws {
		window?.close(); window = nil
		try? FileManager.default.removeItem(at: library)
	}

	@discardableResult
	func add(_ name: String, kib: Int, version: UInt32 = 1) throws -> RigModule {
		let data = SyntheticDock.make(name: name, version: version, kib: kib, seed: UInt8(name.utf8.first ?? 0))
		let file = "\(name.lowercased()).dock"
		try data.write(to: library.appendingPathComponent(file))
		return RigModule(try DockModuleFile(data), file: file)
	}

	func link(_ fake: FakeFM1) throws -> WebDockLink {
		let engine = try MIDIEngine(clientName: "FM1 rigs test", filter: fake.filter)
		let l = WebDockLink(engine: engine, resolver: LocalSchemeHandler.site(root: Repo.appWeb, library: library))
		let w = NSWindow(contentRect: l.webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
		w.isReleasedWhenClosed = false
		w.contentView = l.webView
		w.orderBack(nil)
		window = w
		return l
	}

	func apply(_ rig: Rig, _ link: DockLink) async throws -> (RigPlan, RigApplyOutcome) {
		let state = try await RigApplier.readForPlanning(link)
		let lib = LibraryModule.scan(library)
		let plan = try RigPlanner.plan(rig: rig, device: state, library: lib).get()
		let out = await RigApplier(link: link, libraryFolder: library).run(plan, rig: rig, library: lib) { _ in }
		return (plan, out)
	}

	func assertFinished(_ out: RigApplyOutcome, file: StaticString = #filePath, line: UInt = #line) {
		guard case let .finished(_, issues, _) = out else { return XCTFail("\(out)", file: file, line: line) }
		XCTAssertEqual(issues, [], file: file, line: line)
	}

	func testRigAOnAnEmptyFM1ThenRigBWithTheFewestOperations() async throws {
		let a = try add("ALPHA", kib: 40), b = try add("BRAVO", kib: 60), c = try add("CHARLIE", kib: 30), d = try add("DELTA", kib: 100)
		let fake = try FakeFM1(dockVersion: "0.9")                 // (0.8 on: it answers INFO)
		let l = try link(fake)
		defer { l.close() }

		let rigA = Rig(name: "A", modules: [a, b], select: "BRAVO")
		let (_, outA) = try await apply(rigA, l)
		assertFinished(outA)
		XCTAssertEqual(Set(fake.layout.map(\.name)), ["ALPHA", "BRAVO"])
		XCTAssertEqual(fake.current, "BRAVO")
		XCTAssertEqual(fake.deployedModules.first { $0.name == "ALPHA" }?.blob,
		               [UInt8](try Data(contentsOf: library.appendingPathComponent("alpha.dock"))))

		let before = fake.commands.count
		let rigB = Rig(name: "B", modules: [b, c, d], select: "DELTA")
		let (planB, outB) = try await apply(rigB, l)
		assertFinished(outB)
		XCTAssertEqual(planB.kept, ["BRAVO"])
		let cmds = Array(fake.commands[before...])
		XCTAssertEqual(cmds.filter { $0.hasPrefix("DELETE") }, ["DELETE ALPHA"])
		XCTAssertEqual(Set(cmds.filter { $0.hasPrefix("COMMIT") }), ["COMMIT CHARLIE", "COMMIT DELTA"])
		XCTAssertFalse(cmds.contains { $0.contains("BRAVO") }, "BRAVO stays as it is: \(cmds)")
		XCTAssertEqual(cmds.last, "SELECT DELTA")
		XCTAssertEqual(Set(fake.layout.map(\.name)), ["BRAVO", "CHARLIE", "DELTA"])

		// Save what's on it: the same rig back, every module from the library
		let state = try await l.readState()
		XCTAssertEqual(state.dockVersion, "0.9", "INFO's version")
		XCTAssertEqual(state.flashID, "B36014", "INFO's flash chip")
		XCTAssertEqual(FlashChip.from(jedec: state.flashID), .newer)
		fake.flashJEDEC = 0x85_6014
		let older = try await l.readFlashID()
		XCTAssertEqual(older, "856014")
		XCTAssertEqual(FlashChip.from(jedec: older), .older)
		XCTAssertEqual(state.board, .fm1)
		XCTAssertEqual(state.identity, "FM-1_921")
		let (captured, missing) = RigCapture.rig(named: "now", from: state, library: LibraryModule.scan(library))
		XCTAssertEqual(missing, [])
		XCTAssertEqual(Set(captured.modules), Set(rigB.modules))
		XCTAssertEqual(captured.select, "DELTA")
		// and applying it again changes nothing
		let again = try RigPlanner.plan(rig: rigB, device: state, library: LibraryModule.scan(library)).get()
		XCTAssertTrue(again.changesNothing)
	}

	/// The fake's deploy area in pieces of 100 and 72 KiB between two modules; in the rig's order the third new
	/// module would not fit. The plan's order does, with nothing taken off.
	func testFragmentedAreaOnTheDevice() async throws {
		let k1 = try add("KEEP1", kib: 20), k2 = try add("KEEP2", kib: 104)
		let x = try add("XRAY", kib: 72), y = try add("YANKEE", kib: 48), z = try add("ZULU", kib: 52)
		let fake = try FakeFM1()
		let lo = FakeFM1.deployArea.lowerBound
		fake.preload(try Data(contentsOf: library.appendingPathComponent("keep1.dock")), at: lo)
		fake.preload(try Data(contentsOf: library.appendingPathComponent("keep2.dock")), at: lo + 120 * 1024)
		let l = try link(fake)
		defer { l.close() }
		let s = try await l.readState()
		XCTAssertEqual(s.free, 172 * 1024, "HELLO's free, from the fake's dp_place")
		XCTAssertEqual(s.largest, 100 * 1024)
		let model = RigPlanner.layout(of: s, library: LibraryModule.scan(library))
		XCTAssertTrue(model.exact)
		XCTAssertEqual(model.layout.free, s.free)

		let (plan, out) = try await apply(Rig(name: "F", modules: [k1, k2, x, y, z]), l)
		assertFinished(out)
		XCTAssertEqual(plan.deletes, [])
		XCTAssertNotEqual(plan.deploys.map(\.name), ["XRAY", "YANKEE", "ZULU"], "not the rig's (failing) order")
		XCTAssertEqual(Set(fake.layout.map(\.name)), ["KEEP1", "KEEP2", "XRAY", "YANKEE", "ZULU"])
		let after = try await l.readState()
		XCTAssertEqual(after.free, 0)
	}

	/// The cable pulled while a module's data goes: Apply stops and says what it got done; replugged, Resume (read,
	/// ABORT the half-received module, plan again) finishes the rest and nothing is sent twice.
	func testUnplugMidApplyThenResume() async throws {
		let a = try add("ONE", kib: 60), b = try add("TWO", kib: 80), c = try add("THREE", kib: 70)
		let fake = try FakeFM1()
		let l = try link(fake)
		defer { l.close() }
		let rig = Rig(name: "R", modules: [a, b, c], select: "ONE")
		let lib = LibraryModule.scan(library)
		let plan = try RigPlanner.plan(rig: rig, device: try await l.readState(), library: lib).get()
		let applier = RigApplier(link: l, libraryFolder: library)
		let run = Task { await applier.run(plan, rig: rig, library: lib) { _ in } }
		// pull it during the second module's data
		let end = Date().addingTimeInterval(30)
		while !(fake.commands.filter { $0.hasPrefix("COMMIT") }.count == 1 && fake.isReceiving) {
			if Date() > end { XCTFail("never reached the second deploy: \(fake.commands)"); return }
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		try await Task.sleep(nanoseconds: 150_000_000)
		fake.unplug()
		let out = await run.value
		guard case let .stopped(reason, failedStep, device, done) = out else { return XCTFail("\(out)") }
		XCTAssertEqual(failedStep, 1, reason)
		XCTAssertEqual(done.count, 1)
		XCTAssertNil(device, "unplugged: nothing could be read")
		XCTAssertTrue(fake.isReceiving, "the device still has the half-received module open")
		XCTAssertEqual(fake.layout.count, 1)

		try fake.replug()
		try await Task.sleep(nanoseconds: 300_000_000)
		let state = try await RigApplier.readForPlanning(l)
		XCTAssertTrue(fake.commands.contains("ABORT"))
		XCTAssertFalse(state.receiving)
		let rest = try RigPlanner.plan(rig: rig, device: state, library: lib).get()
		XCTAssertEqual(rest.deploys.count, 2, "only what is still missing")
		XCTAssertEqual(rest.kept.count, 1)
		let out2 = await RigApplier(link: l, libraryFolder: library).run(rest, rig: rig, library: lib) { _ in }
		assertFinished(out2)
		XCTAssertEqual(Set(fake.layout.map(\.name)), ["ONE", "TWO", "THREE"])
		XCTAssertEqual(fake.current, "ONE")
		XCTAssertEqual(fake.commands.filter { $0.hasPrefix("COMMIT") }.count, 3, "each module committed once: \(fake.commands)")
	}
}
#endif
