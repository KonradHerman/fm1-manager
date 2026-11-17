// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A .dock module file's header (fm1-dock's hb_file_t, firmware/dock/hb_module.h): 80 bytes, then n_relocs words
/// padded with 0xFF to a 256-byte boundary, then the image (code + rodata, data, ram_text).
public struct DockModuleFile: Sendable, Hashable, Codable {
	public static let magic: UInt32 = 0x5242_5248                 // "HRBR"
	public static let probeFlag: UInt32 = 0x100, bootFlag: UInt32 = 0x200
	public static let sector = 4096

	public let name: String
	public let abi: UInt32
	public let flags: UInt32
	public let version: UInt32
	public let codeSize: UInt32, dataSize: UInt32, bssSize: UInt32, rtSize: UInt32
	public let relocs: UInt32
	/// The file's length in bytes.
	public let fileSize: Int
	/// CRC-32 of the whole file: what identifies it in the library and in a rig.
	public let crc32: UInt32

	public var isProbe: Bool { flags & Self.probeFlag != 0 }
	public var isBoot: Bool { flags & Self.bootFlag != 0 }
	/// What LIST reports as the module's size on the device: code + data (dock.c D_LIST).
	public var listSize: UInt32 { codeSize &+ dataSize }
	/// What it occupies in the deploy area: header and relocations to 256 bytes, the image, in whole 4 KiB sectors
	/// (dock.c d_commit: io + code + data + rt, rounded up).
	public var footprint: Int { Self.sectors(byteCount) }
	/// The bytes written to flash before rounding (dock.c `total`).
	public var byteCount: Int {
		let io = (80 + 4 * Int(relocs) + 255) & ~255
		return io + Int(codeSize) + Int(dataSize) + Int(rtSize)
	}

	public static func sectors(_ n: Int) -> Int { (n + sector - 1) / sector * sector }

	public enum ParseError: Error, CustomStringConvertible {
		case notAModule, cutShort
		public var description: String {
			switch self {
			case .notAModule: "not an fm1-dock module (.dock)"
			case .cutShort: "the module file is cut short"
			}
		}
	}

	public init(_ data: Data) throws {
		let b = [UInt8](data.prefix(80))
		guard b.count == 80 else { throw ParseError.notAModule }
		func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
		guard u32(0) == Self.magic else { throw ParseError.notAModule }
		abi = u32(4); flags = u32(8)
		name = String(decoding: b[12..<35].prefix { $0 != 0 }, as: UTF8.self)
		version = u32(36); codeSize = u32(40); dataSize = u32(44); bssSize = u32(48); rtSize = u32(52)
		relocs = u32(68)
		fileSize = data.count
		crc32 = CRC32.of(data)
		guard relocs <= 65536, byteCount <= data.count else { throw ParseError.cutShort }
	}

	public init(contentsOf url: URL) throws { try self.init(Data(contentsOf: url)) }
}

public enum CRC32 {
	private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
		var c = UInt32(n)
		for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
		return c
	}
	public static func of(_ data: Data) -> UInt32 {
		var c: UInt32 = 0xFFFF_FFFF
		data.withUnsafeBytes { raw in for b in raw { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
		return c ^ 0xFFFF_FFFF
	}
	public static func hex(_ v: UInt32) -> String { String(format: "%08x", v) }
}
