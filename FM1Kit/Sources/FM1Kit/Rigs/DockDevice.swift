// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What an FM-1 (or SMK-37) running fm1-dock says about itself: HELLO's room, LIST's modules, the updater's identity.
/// Read only; DockLink fills it.
public struct DockDeviceState: Sendable, Codable, Hashable {
	public enum Board: String, Sendable, Codable { case fm1, smk37 }

	/// The handshake's identity ("FM-1_921"); nil when only fm1-dock's HELLO answered.
	public var identity: String?
	/// fm1-dock's version, from INFO or the log's boot line, when it said.
	public var dockVersion: String?
	public var board: Board
	public var abi: UInt32
	/// HELLO: the deploy area's free bytes in all, its largest gap, the largest module file it takes.
	public var free: Int
	public var largest: Int
	public var maxFile: Int
	/// HELLO: a deploy (BEGIN ... COMMIT) is open on the device.
	public var receiving: Bool
	/// LIST's index of the module playing.
	public var current: Int
	public var modules: [DeviceModule]
	/// INFO's flash chip JEDEC id ("B36014"), from fm1-dock 0.8 on; nil from an older one.
	public var flashID: String?

	public init(identity: String?, dockVersion: String?, board: Board, abi: UInt32, free: Int, largest: Int, maxFile: Int,
	            receiving: Bool, current: Int, modules: [DeviceModule], flashID: String? = nil) {
		self.identity = identity; self.dockVersion = dockVersion; self.board = board; self.abi = abi; self.free = free
		self.largest = largest; self.maxFile = maxFile; self.receiving = receiving; self.current = current; self.modules = modules
		self.flashID = flashID
	}

	public var currentName: String? { modules.first { $0.index == current }?.name }
	public var deployed: [DeviceModule] { modules.filter { $0.kind == .deployed } }

	/// The deploy areas in flash offsets (dock.c DP_LO..DP_HI; the SMK-37 has two around its table).
	public var areas: [Range<Int>] {
		switch board {
		case .fm1: [0x96000..<0xE0000]
		case .smk37: [0x70000..<0xB8000, 0xC2000..<0xE2000]
		}
	}
	public var capacity: Int { areas.reduce(0) { $0 + $1.count } }
}

public struct DeviceModule: Sendable, Codable, Hashable {
	public enum Kind: String, Sendable, Codable {
		case builtIn = "built in", image, deployed, boot, other
		/// What a plan may not delete: the host's sine, the firmware package's own, a boot firmware.
		public var isFixed: Bool { self != .deployed }
	}
	public var index: Int
	public var name: String
	public var kind: Kind
	public var state: String
	public var version: UInt32
	/// LIST's size: code + data (not what it takes in flash).
	public var size: UInt32
	/// LIST's address: where its header is, as the CPU sees flash (XIP).
	public var xip: UInt32

	public init(index: Int, name: String, kind: Kind, state: String = "ok", version: UInt32, size: UInt32, xip: UInt32) {
		self.index = index; self.name = name; self.kind = kind; self.state = state; self.version = version; self.size = size; self.xip = xip
	}

	/// XIP address -> flash offset (hal/fm1_xip.h: FM1_XIP(off) = 0x02000000 + off - 0x4000).
	public static func flashOffset(xip: UInt32) -> Int { Int(xip) - 0x0200_0000 + 0x4000 }
	public static func xip(flashOffset off: Int) -> UInt32 { UInt32(0x0200_0000 + off - 0x4000) }
	public var flashOffset: Int { Self.flashOffset(xip: xip) }

	/// The same module as a library file: name, version and LIST's size (the device cannot report a file's CRC:
	/// the slot's CRC is recomputed after the module is moved to its place).
	public func matches(_ f: DockModuleFile) -> Bool { name == f.name && version == f.version && size == f.listSize }
}

/// The deploy area as dock.c's dp_place sees it: modules in whole sectors, gaps between, first fit at the lowest
/// gap that is large enough. The planner's model; FakeFM1 has its own, written separately from dock.c.
public struct FlashLayout: Sendable, Hashable {
	public struct Block: Sendable, Hashable {
		public var name: String
		public var start: Int
		public var footprint: Int
		public init(name: String, start: Int, footprint: Int) { self.name = name; self.start = start; self.footprint = footprint }
		public var end: Int { start + footprint }
	}
	public let areas: [Range<Int>]
	public private(set) var blocks: [Block]

	public init(areas: [Range<Int>], blocks: [Block] = []) { self.areas = areas; self.blocks = blocks }

	private func area(of at: Int) -> Range<Int>? { areas.first { $0.contains(at) } }

	/// The free gaps, as dp_place finds them: from each area's start and each module's end to the next module or
	/// the area's end.
	public var gaps: [Range<Int>] {
		var starts = Set(areas.map(\.lowerBound))
		for b in blocks { starts.insert(b.end) }
		var out: [Range<Int>] = []
		for s in starts.sorted() {
			guard let a = area(of: s), !blocks.contains(where: { s >= $0.start && s < $0.end }) else { continue }
			let next = blocks.map(\.start).filter { $0 >= s && $0 < a.upperBound }.min() ?? a.upperBound
			if next > s { out.append(s..<next) }
		}
		return out
	}
	public var free: Int { gaps.reduce(0) { $0 + $1.count } }
	public var largest: Int { gaps.map(\.count).max() ?? 0 }

	/// Where a module of this footprint goes: the lowest gap it fits in; nil: none.
	public func place(_ footprint: Int) -> Int? { gaps.first { $0.count >= footprint }?.lowerBound }

	@discardableResult
	public mutating func add(_ name: String, footprint: Int) -> Int? {
		guard let at = place(footprint) else { return nil }
		blocks.append(Block(name: name, start: at, footprint: footprint))
		return at
	}
	public mutating func remove(_ name: String) { blocks.removeAll { $0.name == name } }
}
