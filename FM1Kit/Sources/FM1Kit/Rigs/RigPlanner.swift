// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What Apply will do to the device, step by step, and what it leaves alone.
public struct RigPlan: Sendable, Hashable {
	public enum Step: Sendable, Hashable {
		/// DELETE: its flash is freed. `restorable`: a library file can put it back.
		case delete(name: String, restorable: Bool)
		/// BEGIN, DATA..., COMMIT of a library file (first fit: dock.c places it, the plan predicts where).
		case deploy(RigModule, fileName: String)
		/// SELECT: the module that plays at the end.
		case select(String)
	}
	public var steps: [Step]
	/// The deploy area as the plan expects it after each step (same count as steps; a select changes nothing).
	public var expected: [FlashLayout]
	/// Rig modules already on the device as they should be: left alone.
	public var kept: [String]
	/// Rig modules the firmware package has built in: nothing to do.
	public var inPackage: [String]
	/// Kept modules taken off and put back on, so that the rest fits.
	public var relocated: [String]
	/// Modules the plan deletes that no library file can put back: each needs its own confirmation.
	public var unrestorable: [String]
	/// Whether the model of the deploy area matched what the device reported (free, largest) exactly.
	public var layoutExact: Bool
	public var notes: [String]

	public var changesNothing: Bool { steps.isEmpty }
	public var deletes: [String] { steps.compactMap { if case let .delete(n, _) = $0 { n } else { nil } } }
	public var deploys: [RigModule] { steps.compactMap { if case let .deploy(m, _) = $0 { m } else { nil } } }
	public var bytesToSend: Int { deploys.reduce(0) { $0 + $1.fileSize } }

	/// Time it should take: the bytes at the measured rate, plus the flash writes and the round trips.
	public func estimatedSeconds(bytesPerSecond: Double) -> Double {
		let rate = max(bytesPerSecond, 1000)
		return Double(bytesToSend) / rate + Double(deploys.count) * 1.5 + Double(deletes.count) * 0.5 + 1
	}
}

public enum RigPlanProblem: Error, Hashable, Sendable, CustomStringConvertible {
	case notFM1Dock
	case firmware(want: String, have: String?)
	case missingFiles([String])
	case changedFiles([String])
	case unusable(name: String, why: String)
	case tooMany(Int)
	case wontFit(shortfall: Int, need: Int, capacity: Int)
	case noOrder(String)
	/// The app's model of the deploy area does not add up to what the FM-1 reports, with every module known:
	/// the model is wrong (its footprint rule), so nothing is planned on it.
	case modelDisagrees(modelFree: Int, modelLargest: Int, deviceFree: Int, deviceLargest: Int)

	public var description: String {
		switch self {
		case .notFM1Dock: "The FM-1 does not run fm1-dock: a rig needs it."
		case let .firmware(want, have):
			"This rig expects the firmware \(want); the FM-1 runs \(have ?? "another one"). Install \(want) first."
		case let .missingFiles(n): "Not in your library: \(n.joined(separator: ", ")). Add them (the catalogue, or Files) first."
		case let .changedFiles(n):
			"Your library has another file of \(n.joined(separator: ", ")) than the rig was made with. Update the rig to the library's, or put the old file back."
		case let .unusable(n, why): "\(n): \(why)"
		case let .tooMany(n): "\(n) modules: fm1-dock holds 32 at most."
		case let .wontFit(short, need, cap):
			"The rig needs \(need / 1024) KiB, the FM-1 has \(cap / 1024) KiB for modules: over by \(short / 1024) KiB. Take something out."
		case let .noOrder(why): "The modules cannot be placed: \(why)"
		case let .modelDisagrees(mf, ml, df, dl):
			"The app's model of the FM-1's module area says \(mf / 1024) KiB free (largest piece \(ml / 1024) KiB); the FM-1 says \(df / 1024) KiB (\(dl / 1024) KiB). Nothing is changed while they disagree: please report this."
		}
	}
}

public enum RigPlanner {
	/// The model of the device's deploy area from LIST: each deployed module's start, its footprint from its library
	/// file when one matches, else bounded (at least its LIST size and a 256-byte header, at most up to the next
	/// module), the bounds settled against HELLO's free bytes. exact: free and largest match HELLO.
	public static func layout(of device: DockDeviceState, library: [LibraryModule]) -> (layout: FlashLayout, exact: Bool, unknown: [String]) {
		let deployed = device.deployed.sorted { $0.flashOffset < $1.flashOffset }
		var blocks: [FlashLayout.Block] = []
		var slack: [Int: Int] = [:]                               // block index -> how much it might be larger
		var unknown: [String] = []
		for (i, m) in deployed.enumerated() {
			let start = m.flashOffset
			let area = device.areas.first { $0.contains(start) }
			let next = i + 1 < deployed.count && area?.contains(deployed[i + 1].flashOffset) == true
				? deployed[i + 1].flashOffset : (area?.upperBound ?? start)
			if let f = library.first(where: { m.matches($0.header) })?.header {
				blocks.append(.init(name: m.name, start: start, footprint: f.footprint))
			} else {
				let low = min(DockModuleFile.sectors(256 + Int(m.size)), max(next - start, 0))
				blocks.append(.init(name: m.name, start: start, footprint: low))
				slack[blocks.count - 1] = max(0, next - start - low)
				unknown.append(m.name)
			}
		}
		var model = FlashLayout(areas: device.areas, blocks: blocks)
		// lower bounds leave more free than HELLO says: the difference belongs to the unknown modules. With one
		// that can take it, it is pinned; with several, which one took what is a guess (not exact)
		var excess = model.free - device.free
		let takers = slack.filter { $0.value > 0 }.count
		if excess > 0 {
			for i in slack.keys.sorted() where excess > 0 {
				let add = min(excess, slack[i]!)
				blocks[i].footprint += add
				excess -= add
			}
			model = FlashLayout(areas: device.areas, blocks: blocks)
		}
		let settled = model.free == device.free && model.largest == device.largest
		let exact = settled && (model.free - device.free == 0) && (takers <= 1 || unknown.isEmpty)
		return (model, exact, unknown)
	}

	/// How much the rig is over the device's room (0: it fits once the rest is gone), for the editor's meter.
	public static func shortfall(of modules: [RigModule], capacity: Int) -> Int {
		max(0, modules.reduce(0) { $0 + $1.footprint } - capacity)
	}

	public static func plan(rig: Rig, device: DockDeviceState, library: [LibraryModule]) -> Result<RigPlan, RigPlanProblem> {
		guard device.abi > 0 else { return .failure(.notFM1Dock) }
		if let fw = rig.firmware, let have = device.identity, have != fw.product {
			return .failure(.firmware(want: fw.product, have: have))
		}
		let fixed = Set(device.modules.filter { $0.kind.isFixed }.map(\.name))
		var seen = Set<String>()
		let rigModules = rig.modules.filter { seen.insert($0.name).inserted }
		let inPackage = rigModules.filter { fixed.contains($0.name) }.map(\.name)
		let wanted = rigModules.filter { !fixed.contains($0.name) }
		let byCRC = Dictionary(library.map { (CRC32.hex($0.header.crc32), $0) }, uniquingKeysWith: { a, _ in a })

		// what is there: kept as it is, or deleted (a module the rig does not have, or another version of one)
		var kept: [RigModule] = [], deletes: [DeviceModule] = []
		for d in device.deployed {
			if let w = wanted.first(where: { $0.name == d.name }), w.matches(d) { kept.append(w) } else { deletes.append(d) }
		}
		let keptNames = Set(kept.map(\.name))
		let toDeploy = wanted.filter { !keptNames.contains($0.name) }

		// every file it needs, before anything is touched
		var missing: [String] = [], changed: [String] = []
		var fileOf: [String: LibraryModule] = [:]
		for m in wanted {
			if let f = byCRC[m.crc32.lowercased()] { fileOf[m.name] = f; continue }
			guard toDeploy.contains(m) else { continue }             // (kept: no file needed)
			if library.contains(where: { $0.header.name == m.name }) { changed.append(m.name) } else { missing.append(m.name) }
		}
		if !missing.isEmpty { return .failure(.missingFiles(missing)) }
		if !changed.isEmpty { return .failure(.changedFiles(changed)) }
		for m in toDeploy {
			let h = fileOf[m.name]!.header
			if h.isProbe { return .failure(.unusable(name: m.name, why: "a probe, not a module")) }
			if h.isBoot { return .failure(.unusable(name: m.name, why: "a boot firmware, not a module")) }
			if h.abi != device.abi {
				return .failure(.unusable(name: m.name, why: "built for fm1-dock's ABI \(h.abi); the FM-1's speaks \(device.abi)"))
			}
			if device.maxFile > 0 && h.fileSize > device.maxFile {
				return .failure(.unusable(name: m.name, why: "\(h.fileSize / 1024) KiB; fm1-dock takes \(device.maxFile / 1024) KiB at most"))
			}
		}
		let boots = device.modules.filter { $0.kind == .boot }.count
		if wanted.count + boots > 32 { return .failure(.tooMany(wanted.count)) }

		let (model, exact, unknown) = layout(of: device, library: library)
		if !exact && unknown.isEmpty {
			return .failure(.modelDisagrees(modelFree: model.free, modelLargest: model.largest, deviceFree: device.free, deviceLargest: device.largest))
		}
		let footprintOf = { (m: RigModule) -> Int in model.blocks.first { $0.name == m.name }?.footprint ?? m.footprint }
		let need = kept.reduce(0) { $0 + footprintOf($1) } + toDeploy.reduce(0) { $0 + $1.footprint }
		if need > device.capacity { return .failure(.wontFit(shortfall: need - device.capacity, need: need, capacity: device.capacity)) }

		var base = model
		for d in deletes { base.remove(d.name) }
		var relocated: [RigModule] = []
		var order = search(base, toDeploy)
		if order == nil, exact {
			// make room: take kept modules off and put them back, the fewest bytes first
			let movable = kept.filter { fileOf[$0.name] != nil }
			if movable.count <= 12 {
				var subsets: [[RigModule]] = []
				for mask in 1..<(1 << movable.count) {
					var s: [RigModule] = []
					for (k, m) in movable.enumerated() where (mask >> k) & 1 == 1 { s.append(m) }
					subsets.append(s)
				}
				let bytes = { (s: [RigModule]) -> Int in s.reduce(0) { $0 + $1.fileSize } }
				subsets.sort { bytes($0) < bytes($1) }
				for s in subsets {
					var l = base
					for m in s { l.remove(m.name) }
					if let o = search(l, toDeploy + s) { order = o; relocated = s; base = l; break }
				}
			}
		}
		guard let order else {
			let why = exact ? "the free space is in pieces too small, even with modules moved"
				: "the free space is in pieces too small, and the device's layout is not known exactly enough to move modules around \(unknown.joined(separator: ", "))"
			return .failure(.noOrder(why))
		}

		var steps: [RigPlan.Step] = [], expected: [FlashLayout] = []
		var l = model
		let restorable = { (d: DeviceModule) in library.contains { d.matches($0.header) } }
		for d in deletes {
			l.remove(d.name); steps.append(.delete(name: d.name, restorable: restorable(d))); expected.append(l)
		}
		for m in relocated {
			l.remove(m.name); steps.append(.delete(name: m.name, restorable: true)); expected.append(l)
		}
		for m in order {
			l.add(m.name, footprint: m.footprint)
			steps.append(.deploy(m, fileName: fileOf[m.name]!.fileName)); expected.append(l)
		}
		var notes: [String] = []
		let builtIn = Set(device.modules.filter { $0.kind == .builtIn }.map(\.name))
		if let sel = rig.select {
			let there = fixed.contains(sel) || rigModules.contains { $0.name == sel }
			if builtIn.contains(sel) {
				// (dock.c D_SELECT refuses the host's own module, LIST's index 0: only the FM-1's own buttons pick it)
				if device.currentName != sel { notes.append("\(sel) is the host's own: it cannot be picked over USB. Pick it on the FM-1.") }
			} else if !there { notes.append("\(sel), to play at the end, is not in the rig: the FM-1 keeps what it picks.") }
			else if !steps.isEmpty || device.currentName != sel { steps.append(.select(sel)); expected.append(l) }
		}
		if !exact { notes.append("Where \(unknown.joined(separator: ", ")) ends on the FM-1 is not known exactly (not in your library): after each step Apply checks only that the module came or went, not where.") }
		if boots > 0 { notes.append("A boot firmware is on the FM-1: fm1-dock may refuse new modules while it is there.") }
		let unrestorable = deletes.filter { !restorable($0) }.map(\.name)
		return .success(RigPlan(steps: steps, expected: expected, kept: kept.map(\.name).filter { !relocated.map(\.name).contains($0) },
		                        inPackage: inPackage, relocated: relocated.map(\.name), unrestorable: unrestorable,
		                        layoutExact: exact, notes: notes))
	}

	/// An order in which first fit places every module (depth first; modules of one size tried once per level).
	static func search(_ layout: FlashLayout, _ remaining: [RigModule]) -> [RigModule]? {
		var budget = 200_000
		func go(_ l: FlashLayout, _ rest: [RigModule]) -> [RigModule]? {
			if rest.isEmpty { return [] }
			budget -= 1
			if budget < 0 || rest.reduce(0, { $0 + $1.footprint }) > l.free { return nil }
			var tried = Set<Int>()
			for (i, m) in rest.enumerated().sorted(by: { $0.element.footprint > $1.element.footprint })
			where tried.insert(m.footprint).inserted {
				var next = l
				guard next.add(m.name, footprint: m.footprint) != nil else { continue }
				var r = rest
				r.remove(at: i)
				if let tail = go(next, r) { return [m] + tail }
			}
			return nil
		}
		return go(layout, remaining)
	}
}

public enum RigCapture {
	/// "Save what's on my FM-1": its deployed modules as a rig, each matched to a library file (name, version, LIST
	/// size). `notInLibrary`: on the device, but no library file can put it back (in the rig without a file: Apply
	/// keeps it while it is there, and cannot restore it once it is gone).
	public static func rig(named name: String, from device: DockDeviceState, library: [LibraryModule])
		-> (rig: Rig, notInLibrary: [String]) {
		let model = RigPlanner.layout(of: device, library: library).layout
		var modules: [RigModule] = [], missing: [String] = []
		for d in device.deployed.sorted(by: { $0.index < $1.index }) {
			if let f = library.first(where: { d.matches($0.header) }) {
				modules.append(RigModule(f.header, file: f.fileName))
			} else {
				missing.append(d.name)
				let fp = model.blocks.first { $0.name == d.name }?.footprint ?? DockModuleFile.sectors(256 + Int(d.size))
				modules.append(RigModule(name: d.name, version: d.version, crc32: "", fileSize: 0, footprint: fp, listSize: d.size, file: nil))
			}
		}
		let playing = device.modules.first { $0.index == device.current }
		let rig = Rig(name: name, modules: modules, select: playing?.kind == .builtIn ? nil : playing?.name)
		return (rig, missing)
	}
}
