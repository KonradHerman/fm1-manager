// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import FM1KitTestSupport
import XCTest

/// The planner on made-up devices: an FM-1's deploy area (0x96000..0xE0000, 296 KiB), modules of exact sizes.
final class RigPlannerTests: XCTestCase {
	static let lo = 0x96000
	var lib: [LibraryModule] = []

	@discardableResult
	func module(_ name: String, kib: Int, version: UInt32 = 1) -> RigModule {
		let data = SyntheticDock.make(name: name, version: version, kib: kib)
		let h = try! DockModuleFile(data)
		lib.removeAll { $0.header == h }
		lib.append(LibraryModule(fileName: "\(name)-\(version).dock", header: h))
		return RigModule(h, file: "\(name)-\(version).dock")
	}

	/// A device with these deployed modules at these offsets (KiB from the area's start); free and largest as
	/// dock.c would report them.
	func device(_ placed: [(RigModule, Int)], current: String? = nil) -> DockDeviceState {
		var mods = [DeviceModule(index: 0, name: "SINE", kind: .builtIn, version: 0, size: 0, xip: 0),
		            DeviceModule(index: 1, name: "CS-1", kind: .image, version: 1, size: 50000, xip: 0x0203_1000)]
		var l = FlashLayout(areas: [Self.lo..<0xE0000])
		var blocks: [FlashLayout.Block] = []
		for (m, at) in placed {
			let off = Self.lo + at * 1024
			mods.append(DeviceModule(index: mods.count, name: m.name, kind: .deployed, version: m.version, size: m.listSize,
			                         xip: DeviceModule.xip(flashOffset: off)))
			blocks.append(.init(name: m.name, start: off, footprint: m.footprint))
		}
		l = FlashLayout(areas: [Self.lo..<0xE0000], blocks: blocks)
		let cur = mods.firstIndex { $0.name == current } ?? 0
		return DockDeviceState(identity: "FM-1_921", dockVersion: "0.9", board: .fm1, abi: 2, free: l.free, largest: l.largest,
		                       maxFile: 0x44000, receiving: false, current: cur, modules: mods)
	}

	func plan(_ rig: Rig, _ d: DockDeviceState) -> Result<RigPlan, RigPlanProblem> { RigPlanner.plan(rig: rig, device: d, library: lib) }

	func testTheXIPMappingIsDockCs() {
		// hal/fm1_xip.h: FM1_XIP(off) = 0x02000000 + off - 0x4000; the FM-1's deploy area starts at flash 0x96000
		XCTAssertEqual(DeviceModule.xip(flashOffset: 0x96000), 0x0209_2000)
		XCTAssertEqual(DeviceModule.flashOffset(xip: 0x0209_2000), 0x96000)
		XCTAssertEqual(DockDeviceState(identity: nil, dockVersion: nil, board: .fm1, abi: 2, free: 0, largest: 0, maxFile: 0,
		                               receiving: false, current: 0, modules: []).capacity, 296 * 1024)
	}

	func testFootprintOfARealModule() throws {
		try Repo.needDocs("modules/arp2600.dock")
		let url = Repo.docs.appendingPathComponent("modules/arp2600.dock")
		let f = try DockModuleFile(contentsOf: url)
		XCTAssertEqual(f.name, "ARP 2600")
		XCTAssertEqual(f.abi, 2)
		XCTAssertEqual(f.fileSize, 15640)
		XCTAssertEqual(f.footprint % 4096, 0)
		XCTAssertGreaterThanOrEqual(f.footprint, f.byteCount)
		XCTAssertLessThanOrEqual(f.byteCount, f.fileSize)
	}

	func testNoChangeNeeded() throws {
		let a = module("A", kib: 40), b = module("B", kib: 60)
		let rig = Rig(name: "r", modules: [a, b], select: "B")
		let p = try plan(rig, device([(a, 0), (b, 40)], current: "B")).get()
		XCTAssertTrue(p.changesNothing)
		XCTAssertEqual(p.kept, ["A", "B"])
	}

	func testPureAdditions() throws {
		let a = module("A", kib: 40), b = module("B", kib: 60), c = module("C", kib: 20)
		let p = try plan(Rig(name: "r", modules: [a, b, c], select: "A"), device([(a, 0)], current: "A")).get()
		XCTAssertEqual(p.deletes, [])
		XCTAssertEqual(Set(p.deploys.map(\.name)), ["B", "C"])
		XCTAssertEqual(p.steps.last, .select("A"))
		XCTAssertEqual(p.kept, ["A"])
		XCTAssertEqual(p.expected.count, p.steps.count)
		XCTAssertEqual(p.expected.last?.free, 296 * 1024 - 120 * 1024)
	}

	func testPureRemovals() throws {
		let a = module("A", kib: 40), b = module("B", kib: 60)
		let p = try plan(Rig(name: "r", modules: [a]), device([(a, 0), (b, 40)])).get()
		XCTAssertEqual(p.steps, [.delete(name: "B", restorable: true)])
		XCTAssertEqual(p.unrestorable, [])
	}

	func testAnotherVersionIsReplaced() throws {
		let old = module("A", kib: 40, version: 1)
		let new = module("A", kib: 44, version: 2)
		let p = try plan(Rig(name: "r", modules: [new]), device([(old, 0)])).get()
		XCTAssertEqual(p.deletes, ["A"])
		XCTAssertEqual(p.deploys.map(\.version), [2])
	}

	/// Two gaps, 100 and 72 KiB, between kept modules; the rig adds 72, 48 and 52 KiB. In the rig's order (and
	/// largest first) first fit puts the 72 in the first gap and the 52 then fits nowhere; 48 + 52 in the first gap
	/// and 72 in the second does it.
	func testFragmentationNaiveOrderFailsThePlanFits() throws {
		let k1 = module("K1", kib: 20), k2 = module("K2", kib: 104)
		let x = module("X", kib: 72), y = module("Y", kib: 48), z = module("Z", kib: 52)
		// K1 at 0..20, gap 20..120 (100), K2 at 120..224, gap 224..296 (72)
		let d = device([(k1, 0), (k2, 120)])
		XCTAssertEqual(d.free, 172 * 1024)
		XCTAssertEqual(d.largest, 100 * 1024)
		// the naive order, simulated as the device would place it
		var naive = RigPlanner.layout(of: d, library: lib).layout
		let placed = [x, y, z].map { naive.add($0.name, footprint: $0.footprint) }
		XCTAssertNil(placed[2], "in the rig's order the last one does not fit")
		let p = try plan(Rig(name: "r", modules: [k1, k2, x, y, z]), d).get()
		XCTAssertEqual(p.deletes, [], "nothing taken off: the order alone does it")
		XCTAssertEqual(p.deploys.count, 3)
		var check = RigPlanner.layout(of: d, library: lib).layout
		for m in p.deploys { XCTAssertNotNil(check.add(m.name, footprint: m.footprint), "\(p.deploys.map(\.name))") }
		XCTAssertEqual(check.free, 0)
	}

	/// The gaps are too small for the new module however it goes: a kept module is taken off and put back.
	func testAKeptModuleIsMovedToMakeRoom() throws {
		let k1 = module("K1", kib: 40), k2 = module("K2", kib: 40), k3 = module("K3", kib: 8), n = module("N", kib: 150)
		// K1 0..40, gap 40..100 (60), K2 100..140, gap 140..240 (100), K3 240..248, gap 248..296 (48): 208 free, 100 largest
		let d = device([(k1, 0), (k2, 100), (k3, 240)])
		let p = try plan(Rig(name: "r", modules: [k1, k2, k3, n]), d).get()
		XCTAssertFalse(p.relocated.isEmpty)
		XCTAssertEqual(p.relocated, ["K3"], "the fewest bytes moved: K3 (8 KiB) frees 100+8+48")
		var l = RigPlanner.layout(of: d, library: lib).layout
		for s in p.steps {
			switch s {
			case let .delete(name, _): l.remove(name)
			case let .deploy(m, _): XCTAssertNotNil(l.add(m.name, footprint: m.footprint))
			case .select: break
			}
		}
		XCTAssertEqual(Set(l.blocks.map(\.name)), ["K1", "K2", "K3", "N"])
	}

	func testARigThatCanNeverFitIsRefusedWithTheShortfall() {
		let a = module("A", kib: 200), b = module("B", kib: 120)
		let d = device([])
		guard case let .failure(.wontFit(short, need, cap)) = plan(Rig(name: "r", modules: [a, b]), d) else { return XCTFail() }
		XCTAssertEqual(short, 24 * 1024)
		XCTAssertEqual(need, 320 * 1024)
		XCTAssertEqual(cap, 296 * 1024)
		XCTAssertEqual(RigPlanner.shortfall(of: [a, b], capacity: cap), 24 * 1024)
	}

	func testBuiltInsAreLeftAlone() throws {
		let a = module("A", kib: 40)
		let cs1 = RigModule(name: "CS-1", version: 1, crc32: "00000000", fileSize: 55532, footprint: 57344, listSize: 50000, file: nil)
		let p = try plan(Rig(name: "r", modules: [cs1, a], select: "CS-1"), device([])).get()
		XCTAssertEqual(p.inPackage, ["CS-1"])
		XCTAssertFalse(p.steps.contains { if case .delete = $0 { true } else { false } })
		XCTAssertEqual(p.deploys.map(\.name), ["A"])
		XCTAssertEqual(p.steps.last, .select("CS-1"))
	}

	func testAModuleNotInTheLibraryIsMarkedUnrestorable() throws {
		let a = module("A", kib: 40)
		let ghost = RigModule(name: "GHOST", version: 9, crc32: "deadbeef", fileSize: 30000, footprint: 32768, listSize: 29000, file: nil)
		let d = device([(a, 0), (ghost, 40)])
		lib.removeAll { $0.header.name == "GHOST" }                       // (it was never in the library)
		let p = try plan(Rig(name: "r", modules: [a]), d).get()
		XCTAssertEqual(p.steps, [.delete(name: "GHOST", restorable: false)])
		XCTAssertEqual(p.unrestorable, ["GHOST"])
		XCTAssertTrue(p.layoutExact, "one unknown module, HELLO's free pins it")
	}

	func testMissingAndChangedFilesAreRefusedBeforeAnything() {
		let a = module("A", kib: 40)
		var gone = a
		gone.name = "GONE"; gone.crc32 = "12345678"
		guard case .failure(.missingFiles(["GONE"])) = plan(Rig(name: "r", modules: [a, gone]), device([])) else { return XCTFail() }
		var changed = a
		changed.crc32 = "87654321"
		guard case .failure(.changedFiles(["A"])) = plan(Rig(name: "r", modules: [changed]), device([])) else { return XCTFail() }
	}

	func testFirmwareMismatchAndProbesAreRefused() {
		let a = module("A", kib: 40)
		var rig = Rig(name: "r", modules: [a])
		rig.firmware = RigFirmware(product: "SLOOP_300")
		guard case .failure(.firmware("SLOOP_300", "FM-1_921")) = plan(rig, device([])) else { return XCTFail() }
		let probe = try! DockModuleFile(SyntheticDock.make(name: "P", kib: 8, flags: DockModuleFile.probeFlag))
		lib.append(LibraryModule(fileName: "p.dock", header: probe))
		guard case .failure(.unusable("P", _)) = plan(Rig(name: "r", modules: [RigModule(probe, file: "p.dock")]), device([])) else { return XCTFail() }
	}

	/// dock.c's SELECT refuses the host's own module (LIST index 0): no plan asks for it, and a capture while it plays
	/// does not name it.
	func testTheBuiltInSineIsNeverSelected() throws {
		let a = module("A", kib: 40)
		let d = device([(a, 0)], current: "SINE")
		let (captured, _) = RigCapture.rig(named: "now", from: d, library: lib)
		XCTAssertNil(captured.select)
		let b = module("B", kib: 20)
		let p = try plan(Rig(name: "r", modules: [a, b], select: "SINE"), d).get()
		XCTAssertFalse(p.steps.contains(.select("SINE")))
		XCTAssertEqual(p.deploys.map(\.name), ["B"])
	}

	/// Every module known, and still the model's free space is not the device's: the footprint rule is wrong for
	/// this device, so nothing is planned on it.
	func testAModelThatDisagreesWithTheDeviceIsRefused() {
		let a = module("A", kib: 40)
		var d = device([(a, 0)])
		d.free -= 4096
		guard case let .failure(.modelDisagrees(mf, _, df, _)) = plan(Rig(name: "r", modules: [a]), d) else { return XCTFail() }
		XCTAssertEqual(mf - df, 4096)
	}

	func testRigFileRoundTripAndVersioning() throws {
		let rig = Rig(name: "Night", modules: [module("A", kib: 8)], select: "A")
		let back = try Rig.decode(rig.encoded())
		XCTAssertEqual(back.name, "Night")
		XCTAssertEqual(back.modules, rig.modules)
		var future = try JSONSerialization.jsonObject(with: rig.encoded()) as! [String: Any]
		future["version"] = 2
		XCTAssertThrowsError(try Rig.decode(JSONSerialization.data(withJSONObject: future)))
		XCTAssertThrowsError(try Rig.decode(Data("{}".utf8)))
	}
}
