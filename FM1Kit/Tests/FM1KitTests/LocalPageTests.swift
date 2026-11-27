// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import FM1Kit
import FM1KitTestSupport
import WebKit
import XCTest

/// The app's offline page (ios/App/Resources/web/local.html with fm1-dock's installer JS) and its library, over
/// CoreMIDI to a FakeFM1: a module added and a whole firmware installed, every byte checked on the device's side.
@MainActor
final class LocalPageTests: XCTestCase {
	var library: URL!

	override func setUp() async throws {
		library = FileManager.default.temporaryDirectory.appendingPathComponent("fm1-library-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
	}

	override func tearDown() async throws { try? FileManager.default.removeItem(at: library) }

	func page(_ fake: FakeFM1) async throws -> WebHarness {
		let h = try WebHarness(filter: fake.filter, resolver: LocalSchemeHandler.site(root: Repo.appWeb, library: library))
		try await h.load(URL(string: "fm1dock://app/local.html")!)
		return h
	}

	func testAddsADockModuleFromTheLibrary() async throws {
		try Repo.needDocs("modules/arp2600.dock")
		let src = Repo.docs.appendingPathComponent("modules/arp2600.dock")
		try FileManager.default.copyItem(at: src, to: library.appendingPathComponent("arp2600.dock"))
		let fake = try FakeFM1()
		let h = try await page(fake)
		defer { h.close() }
		try await h.waitFor("!!document.querySelector('button[data-file=\"arp2600.dock\"]')")
		let meta = try await h.text(".meta")
		XCTAssertTrue(meta.contains("module ARP 2600"), meta)
		try await h.js("document.querySelector('button[data-file=\"arp2600.dock\"]').click()")
		try await h.waitFor("document.getElementById('status').textContent.startsWith('Done')", timeout: 30)
		XCTAssertEqual(h.dialogs, ["Add ARP 2600 to the fm1-dock on the FM-1?"])
		XCTAssertEqual(fake.deployedModules.map(\.name), ["ARP 2600"])
		XCTAssertEqual(fake.deployedModules.first?.blob, [UInt8](try Data(contentsOf: src)))
		// and the device check lists it, with a Remove that works
		try await h.js("document.getElementById('check').click()")
		try await h.waitFor("document.querySelectorAll('#dev-mods .mod button').length === 1", timeout: 20)
		let devText = try await h.text("#dev-text")
		XCTAssertTrue(devText.contains("fm1-dock 0.7"), devText)
		try await h.js("document.querySelector('#dev-mods .mod button').click()")
		try await h.waitFor("document.getElementById('status').textContent === 'ARP 2600 removed.'", timeout: 20)
		XCTAssertTrue(fake.deployedModules.isEmpty)
	}

	/// The whole update, as on the device: the running firmware reads a little and restarts as its loader (new
	/// ports), the loader reads all 610 110 bytes of the image in 512-byte requests, and the FM-1 comes back.
	func testInstallsAWholeFirmwareFromTheLibrary() async throws {
		try Repo.needDocs("fm1-dock-0.7.fwsc")
		let src = Repo.docs.appendingPathComponent("fm1-dock-0.7.fwsc")
		try FileManager.default.copyItem(at: src, to: library.appendingPathComponent("fm1-dock-0.7.fwsc"))
		let raw = [UInt8](try Data(contentsOf: src))
		var image: [UInt8] = []                                     // fm1install.js logicalImage: the 20 markers out
		for i in 0..<20 { image += raw[(i * 0x30)..<(i * 0x30 + 0x2F)] }
		image += raw[(20 * 0x30)...]
		let fake = try FakeFM1(identity: "FM-1_921", imageLength: image.count, product: "FM-1_921")
		let h = try await page(fake)
		defer { h.close() }
		try await h.waitFor("!!document.querySelector('button[data-file=\"fm1-dock-0.7.fwsc\"]')")
		let meta = try await h.text(".meta")
		XCTAssertTrue(meta.contains("firmware FM-1_921"), meta)
		let idle = await h.bridge.pageIsBusy()
		XCTAssertFalse(idle, "busy before anything runs")
		let t0 = Date()
		try await h.js("document.querySelector('button[data-file=\"fm1-dock-0.7.fwsc\"]').click()")
		// the app's busy probe (a synthetic beforeunload, once a second as WebPage does) while the install runs
		var busySeen = 0
		for _ in 0..<5 {
			try await Task.sleep(nanoseconds: 1_000_000_000)
			if await h.bridge.pageIsBusy() { busySeen += 1 }
		}
		XCTAssertEqual(busySeen, 5, "the page says busy throughout the install")
		do {
			try await h.waitFor("document.getElementById('status').textContent.startsWith('Done') || /Error|not|No /.test(document.getElementById('status').textContent) && !document.body.dataset.busy",
			                    timeout: 240, poll: 500_000_000)
		} catch { XCTFail("\(error)\n\(fake.events.suffix(10).joined(separator: "\n"))") }
		let status = try await h.text("#status")
		XCTAssertEqual(status, "Done: the FM-1 runs FM-1_921.", fake.events.joined(separator: "\n"))
		XCTAssertTrue(h.dialogs.first?.hasPrefix("Install fm1-dock-0.7.fwsc (FM-1_921) on the FM-1?") == true, "\(h.dialogs)")
		XCTAssertEqual(fake.written.count, image.count)
		XCTAssertTrue(fake.written == image, "the image the loader read differs from the package's")
		XCTAssertTrue(fake.events.contains { $0.contains("reboot as ota-FM-1_900") })
		let after = await h.bridge.pageIsBusy()
		XCTAssertFalse(after, "not busy once done")
		print("firmware install over virtual CoreMIDI took \(Int(Date().timeIntervalSince(t0))) s")
	}

	/// The loader's USB goes away 27 requests into its write (what happened with Skiff 2.7 on a newer-chip FM-1) and
	/// comes back as the same loader. The page must say so, stop being busy (the app lets the screen sleep and stops
	/// guarding links), and a second Install must finish it without restarting anything.
	func testTheLoaderVanishingMidWriteThenInstallAgain() async throws {
		try Repo.needDocs("fm1-dock-0.7.fwsc")
		let src = Repo.docs.appendingPathComponent("fm1-dock-0.7.fwsc")
		try FileManager.default.copyItem(at: src, to: library.appendingPathComponent("fm1-dock-0.7.fwsc"))
		let raw = [UInt8](try Data(contentsOf: src))
		var image: [UInt8] = []
		for i in 0..<20 { image += raw[(i * 0x30)..<(i * 0x30 + 0x2F)] }
		image += raw[(20 * 0x30)...]
		let fake = try FakeFM1(identity: "FM-1_921", imageLength: image.count, product: "FM-1_921")
		fake.dropLoaderAfter = 27
		let h = try await page(fake)
		defer { h.close() }
		let button = "document.querySelector('button[data-file=\"fm1-dock-0.7.fwsc\"]')"
		try await h.waitFor("!!\(button)")
		try await h.js("\(button).click()")
		try await h.waitFor("!document.body.dataset.busy && document.getElementById('status').className === 'bad'", timeout: 120, poll: 250_000_000)
		let first = try await h.text("#status")
		print("after the loader vanished, the page says: \(first)\n\(fake.events.suffix(6).joined(separator: "\n"))")
		XCTAssertTrue(first.contains("connection was lost"), first)
		let busy = await h.bridge.pageIsBusy()
		XCTAssertFalse(busy, "not busy after the failure: the app lets the screen sleep and stops guarding links")
		XCTAssertTrue(fake.events.contains { $0.contains("loader dropped") })
		// the loader is back (as the device did); the same page, Install again
		try await Task.sleep(nanoseconds: 2_500_000_000)
		XCTAssertTrue(fake.portName.contains("Update"), "back as the loader: \(fake.portName)")
		try await h.js("\(button).click()")
		try await h.waitFor("!document.body.dataset.busy && document.getElementById('status').textContent.startsWith('Done')", timeout: 180, poll: 500_000_000)
		XCTAssertTrue(h.dialogs.last?.hasPrefix("The FM-1 is in update mode: an install was cut off.") == true, "\(h.dialogs)")
		XCTAssertTrue(fake.written == image, "the second install wrote the whole image")
	}
}
#endif
