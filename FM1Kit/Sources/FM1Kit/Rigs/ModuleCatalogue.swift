// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// A module fm1-dock's site publishes: fw/index.json's "modules" (tools/site_packages.py), the file next to it in fw/.
public struct CatalogueEntry: Codable, Hashable, Sendable, Identifiable {
	public var id: String
	public var name: String
	public var version: String
	public var file: String
	public var sha256: String
	public var size: Int
	public var abi: UInt32
	public var title: String?
	public var by: String?

	public init(id: String, name: String, version: String, file: String, sha256: String, size: Int, abi: UInt32,
	            title: String?, by: String?) {
		self.id = id; self.name = name; self.version = version; self.file = file; self.sha256 = sha256; self.size = size
		self.abi = abi; self.title = title; self.by = by
	}
}

/// fm1-dock's published modules, fetched only when asked, each checked as the site's own page checks it
/// (install/fm1install.js loadModule): the SHA-256 the index gives, the module's header, its ABI; and its name.
public enum ModuleCatalogue {
	public static let site = URL(string: "https://joakimeriksson.github.io/fm1-dock/")!

	public struct Failure: Error, CustomStringConvertible { public let description: String }

	public static func fetch(session: URLSession = .shared) async throws -> [CatalogueEntry] {
		var req = URLRequest(url: site.appendingPathComponent("fw/index.json"))
		req.cachePolicy = .reloadRevalidatingCacheData
		let (data, resp) = try await session.data(for: req)
		guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "fw/index.json: no answer from the site") }
		return try entries(fromIndex: data)
	}

	public static func entries(fromIndex data: Data) throws -> [CatalogueEntry] {
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let mods = root["modules"] as? [String: [String: Any]] else { throw Failure(description: "fw/index.json has no modules") }
		return mods.compactMap { id, m in
			guard let name = m["name"] as? String, let file = m["file"] as? String, let sha = m["sha256"] as? String,
			      let size = (m["size"] as? NSNumber)?.intValue, let abi = (m["abi"] as? NSNumber)?.uint32Value,
			      !file.contains("/") else { return nil }
			return CatalogueEntry(id: id, name: name, version: m["version"] as? String ?? "", file: file, sha256: sha.lowercased(),
			                      size: size, abi: abi, title: m["title"] as? String, by: m["by"] as? String)
		}.sorted { ($0.title ?? $0.name).localizedStandardCompare($1.title ?? $1.name) == .orderedAscending }
	}

	/// The bytes are the entry's file: its SHA-256, a module header of its ABI and name.
	public static func verify(_ data: Data, _ e: CatalogueEntry) throws -> DockModuleFile {
		let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		guard sha == e.sha256 else { throw Failure(description: "\(e.file) is not the published file (SHA-256 differs)") }
		let h = try DockModuleFile(data)
		guard h.abi == e.abi else { throw Failure(description: "\(e.file): ABI \(h.abi), the index says \(e.abi)") }
		guard h.name == e.name else { throw Failure(description: "\(e.file) is \(h.name), the index says \(e.name)") }
		return h
	}

	/// Downloads, checks, and writes the file into the folder (under its published name, replacing one of that name).
	public static func download(_ e: CatalogueEntry, into folder: URL, session: URLSession = .shared) async throws -> URL {
		let (data, resp) = try await session.data(from: site.appendingPathComponent("fw/\(e.file)"))
		guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "\(e.file): no answer from the site") }
		_ = try verify(data, e)
		let url = folder.appendingPathComponent(e.file)
		try data.write(to: url, options: .atomic)
		return url
	}
}
