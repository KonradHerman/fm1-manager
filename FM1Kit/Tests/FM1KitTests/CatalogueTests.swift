// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import FM1Kit
import XCTest

final class CatalogueTests: XCTestCase {
	func entry(for data: Data, name: String = "ARP 2600", abi: UInt32 = 2) -> CatalogueEntry {
		CatalogueEntry(id: "arp2600", name: name, version: "1", file: "arp2600.dock",
		               sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count, abi: abi, title: nil, by: nil)
	}

	func testVerifyAcceptsThePublishedFileAndNothingElse() throws {
		try Repo.needDocs("modules/arp2600.dock")
		let data = try Data(contentsOf: Repo.docs.appendingPathComponent("modules/arp2600.dock"))
		XCTAssertEqual(try ModuleCatalogue.verify(data, entry(for: data)).name, "ARP 2600")
		var bad = data
		bad[200] ^= 1
		XCTAssertThrowsError(try ModuleCatalogue.verify(bad, entry(for: data)))          // SHA-256
		XCTAssertThrowsError(try ModuleCatalogue.verify(data, entry(for: data, name: "OTHER")))
		XCTAssertThrowsError(try ModuleCatalogue.verify(data, entry(for: data, abi: 3)))
	}

	/// The live index and one small module, checked (set FM1_OFFLINE=1 to skip).
	func testLiveCatalogue() async throws {
		if ProcessInfo.processInfo.environment["FM1_OFFLINE"] != nil { throw XCTSkip("offline") }
		let list: [CatalogueEntry]
		do { list = try await ModuleCatalogue.fetch() } catch { throw XCTSkip("no network: \(error)") }
		XCTAssertGreaterThan(list.count, 10)
		let small = try XCTUnwrap(list.min { $0.size < $1.size })
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let url = try await ModuleCatalogue.download(small, into: dir)
		XCTAssertEqual(try DockModuleFile(contentsOf: url).name, small.name)
	}
}
