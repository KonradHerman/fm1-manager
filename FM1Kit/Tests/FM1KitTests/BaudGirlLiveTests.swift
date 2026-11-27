// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import FM1Kit
import FM1KitTestSupport
import WebKit
import XCTest

/// Baud Girl's own installer (baudgirl.com/work/FM-1+VA/install), live, with an iPhone's user agent, against a
/// FakeFM1 only: walked up to the card that offers the install, never further (nothing is installed, not even on
/// the fake). Set FM1_OFFLINE=1 to skip.
@MainActor
final class BaudGirlLiveTests: XCTestCase {
	static let url = URL(string: "https://baudgirl.com/work/FM-1+VA/install")!

	override func setUp() async throws {
		if ProcessInfo.processInfo.environment["FM1_OFFLINE"] != nil { throw XCTSkip("FM1_OFFLINE set") }
	}

	func card(_ h: WebHarness) async -> (heading: String, main: String, text: String) {
		let r = try? await h.js("""
			const c = document.getElementById('fi-card') || document.getElementById('fi');
			const b = c && c.querySelector('.fi-main');
			return [c ? (c.querySelector('.fi-panel__h, h2, h3') || {}).textContent || '' : '', b ? b.dataset.act || '' : '', c ? c.innerText : ''];
			""") as? [String]
		return (r?[0] ?? "", r?[1] ?? "", r?[2] ?? "")
	}

	func testItFindsTheSimulatedFM1AndOffersTheInstall() async throws {
		let f = try FakeFM1(identity: "FM-1_015", dockVersion: nil)      // M-VAVE's own firmware V15
		let h = try WebHarness(filter: f.filter, allowedOrigins: ["https://baudgirl.com"], userAgent: LiveSiteTests.iPhoneUA)
		defer { h.close() }
		do { try await h.load(Self.url, timeout: 40) } catch { throw XCTSkip("no network: \(error)") }
		try await h.waitFor("typeof navigator.requestMIDIAccess === 'function' && !!document.querySelector('#fi .fi-main')", timeout: 20)
		var log: [String] = []
		var c = await card(h)
		log.append("\(c.heading) [\(c.main)]")
		XCTAssertEqual(c.main, "next", "the browser card says this browser can install: \(c.text)")
		for _ in 0..<8 {
			c = await card(h)
			if c.main == "install" { break }                          // (the install itself: never pressed)
			switch c.main {
			case "next", "agree", "understood", "check", "choose", "chosen":
				try await h.js("document.querySelectorAll('#fi input[type=checkbox]').forEach((x) => { if (!x.checked) x.click(); })")
				try await h.js("const b = document.querySelector('#fi .fi-main'); if (b) b.click()")
			default:
				if c.main.isEmpty { try await Task.sleep(nanoseconds: 1_000_000_000) } else { break }
			}
			let m = try await h.js("const b = [...document.querySelectorAll('[data-act=understood]')].find((x) => x.offsetParent !== null && !x.closest('[hidden]')); if (b) { b.click(); return true } return false") as? Bool
			if m == true { log.append("(modal: understood)") }
			try await Task.sleep(nanoseconds: 1_500_000_000)
			c = await card(h)
			log.append("\(c.heading) [\(c.main)]")
		}
		print("Baud Girl's installer, card by card:\n" + log.joined(separator: "\n") + "\n--- last card:\n" + c.text)
		XCTAssertTrue(f.received.contains(FM1Protocol.handshakeQuery), "it asked the simulated FM-1 who it is")
		XCTAssertFalse(f.received.contains(FM1Protocol.upgrade), "nothing was installed")
		XCTAssertEqual(c.main, "install", "it got to offering the install: \(log)")
	}
}
#endif
