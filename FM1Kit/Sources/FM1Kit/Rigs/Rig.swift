// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A rig: a set of fm1-dock modules the phone keeps and puts on the FM-1 in one go.
///
/// Stored as JSON, one file per rig, in the app's Documents/Rigs/ (`<name>.fm1rig.json`). Format, version 1:
///
///     {
///       "format": "fm1-dock-rig",          // always this
///       "version": 1,                       // the format's version; a reader refuses a higher one
///       "id": "UUID",                       // stable across renames
///       "name": "Analog night",
///       "color": "orange",                  // one of Rig.colors
///       "symbol": "pianokeys",              // an SF Symbol name
///       "modules": [                        // in the order they are put on
///         { "name": "ARP 2600",             // its name on the device (the .dock header's, 23 bytes at most)
///           "version": 3,                   // the header's version
///           "crc32": "1a2b3c4d",            // CRC-32 of the whole .dock file: which library file it is
///           "fileSize": 15640,              // bytes
///           "footprint": 16384,             // what it takes in the deploy area (whole 4 KiB sectors)
///           "listSize": 15000,              // code + data: what the device's LIST reports for it
///           "file": "arp2600.dock" }        // the library file it came from (a hint; crc32 decides)
///       ],
///       "select": "ARP 2600",               // the module playing at the end (null: whatever the device picks)
///       "firmware": null,                   // or { "product": "FM-1_921", "file": "fm1-dock-0.9.fwsc" }: the
///                                           // firmware the rig expects (nothing is installed by Apply)
///       "created": "2026-11-17T10:00:00Z", "modified": "..."
///     }
///
/// Unknown keys are ignored, so a later version 1 writer may add some.
public struct Rig: Codable, Identifiable, Hashable, Sendable {
	public static let formatName = "fm1-dock-rig"
	public static let currentVersion = 1
	public static let colors = ["orange", "red", "pink", "purple", "blue", "teal", "green", "yellow", "gray"]
	public static let fileSuffix = ".fm1rig.json"

	public var format = Rig.formatName
	public var version = Rig.currentVersion
	public var id: UUID
	public var name: String
	public var color: String
	public var symbol: String
	public var modules: [RigModule]
	public var select: String?
	public var firmware: RigFirmware?
	public var created: Date
	public var modified: Date

	public init(id: UUID = UUID(), name: String, color: String = "orange", symbol: String = "pianokeys",
	            modules: [RigModule] = [], select: String? = nil, firmware: RigFirmware? = nil, now: Date = Date()) {
		self.id = id; self.name = name; self.color = color; self.symbol = symbol; self.modules = modules
		self.select = select; self.firmware = firmware; created = now; modified = now
	}

	/// What its modules take in the deploy area, in all.
	public var footprint: Int { modules.reduce(0) { $0 + $1.footprint } }

	public enum FormatError: Error, CustomStringConvertible {
		case notARig, tooNew(Int)
		public var description: String {
			switch self {
			case .notARig: "not a rig file"
			case let .tooNew(v): "a rig of format version \(v): this app reads up to \(Rig.currentVersion)"
			}
		}
	}

	public static func decode(_ data: Data) throws -> Rig {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		let rig: Rig
		do { rig = try d.decode(Rig.self, from: data) } catch { throw FormatError.notARig }
		guard rig.format == formatName else { throw FormatError.notARig }
		guard rig.version <= currentVersion else { throw FormatError.tooNew(rig.version) }
		return rig
	}

	public func encoded() throws -> Data {
		let e = JSONEncoder()
		e.dateEncodingStrategy = .iso8601
		e.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try e.encode(self)
	}
}

public struct RigModule: Codable, Hashable, Sendable {
	public var name: String
	public var version: UInt32
	public var crc32: String
	public var fileSize: Int
	public var footprint: Int
	public var listSize: UInt32
	public var file: String?

	public init(name: String, version: UInt32, crc32: String, fileSize: Int, footprint: Int, listSize: UInt32, file: String?) {
		self.name = name; self.version = version; self.crc32 = crc32; self.fileSize = fileSize; self.footprint = footprint
		self.listSize = listSize; self.file = file
	}

	public init(_ f: DockModuleFile, file: String?) {
		self.init(name: f.name, version: f.version, crc32: CRC32.hex(f.crc32), fileSize: f.fileSize, footprint: f.footprint,
		          listSize: f.listSize, file: file)
	}

	public func matches(_ m: DeviceModule) -> Bool { m.name == name && m.version == version && m.size == listSize }
}

public struct RigFirmware: Codable, Hashable, Sendable {
	public var product: String
	public var file: String?
	public init(product: String, file: String? = nil) { self.product = product; self.file = file }
}

/// A .dock file in the library, read.
public struct LibraryModule: Hashable, Sendable {
	public let fileName: String
	public let header: DockModuleFile
	public init(fileName: String, header: DockModuleFile) { self.fileName = fileName; self.header = header }

	/// Every .dock (and .hrbr) in a folder that reads as a module; others are left out.
	public static func scan(_ folder: URL) -> [LibraryModule] {
		LocalSchemeHandler.libraryFiles(folder).compactMap { url in
			guard ["dock", "hrbr"].contains(url.pathExtension.lowercased()),
			      let h = try? DockModuleFile(contentsOf: url) else { return nil }
			return LibraryModule(fileName: url.lastPathComponent, header: h)
		}
	}
}
