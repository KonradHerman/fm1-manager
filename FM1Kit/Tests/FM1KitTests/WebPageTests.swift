// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import CoreMIDI
import FM1Kit
import FM1KitTestSupport
import WebKit
import XCTest

/// Files the tests read. The app's own (App/Resources/web) are in this repository, four folders up from here.
/// fm1-dock's published site (its docs/ folder: index.html, modules/*.dock, fm1-dock-*.fwsc) is not: tests that load
/// it look in FM1_DOCK_DOCS, else in ../vendor/fm1-dock/docs beside this repository, and are skipped without it
/// (`git clone https://github.com/joakimeriksson/fm1-dock` and point FM1_DOCK_DOCS at its docs folder).
enum Repo {
	static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
		.deletingLastPathComponent().deletingLastPathComponent()
	static let appWeb = root.appendingPathComponent("App/Resources/web")
	static let docs: URL = ProcessInfo.processInfo.environment["FM1_DOCK_DOCS"].map { URL(fileURLWithPath: $0) }
		?? root.deletingLastPathComponent().appendingPathComponent("vendor/fm1-dock/docs")

	/// Skips the test when fm1-dock's docs/ is not there.
	static func needDocs(_ file: String = "index.html") throws {
		guard FileManager.default.fileExists(atPath: docs.appendingPathComponent(file).path) else {
			throw XCTSkip("needs fm1-dock's docs/ (\(file)): set FM1_DOCK_DOCS to a checkout's docs folder")
		}
	}
}

/// The shim in a real WKWebView, over CoreMIDI to a FakeFM1 (the engine sees nothing else).
/// On a CI runner CoreMIDI's server sometimes refuses new clients for the rest of the process (GitHub's macOS
/// runners: MIDIClientCreate -2 from this suite on, on every run so far). There, and only there, the suite is
/// skipped with the reason rather than failed; on a developer's Mac a refusal still fails the tests.
func skipWhenCoreMIDIRefusesClientsOnCI() throws {
	guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
	var client = MIDIClientRef()
	let st = MIDIClientCreateWithBlock("FM1Kit probe" as CFString, &client, nil)
	if st == noErr { MIDIClientDispose(client); return }
	throw XCTSkip("CoreMIDI refuses new clients on this runner (MIDIClientCreate \(st)): skipped on CI only")
}

@MainActor
final class WebMIDIShimTests: XCTestCase {
	override func setUp() async throws { try skipWhenCoreMIDIRefusesClientsOnCI() }

	static let page = """
	<!doctype html><meta charset="utf-8"><title>shim test</title>
	<script>
	window.T = {
	  async setup(name) {
	    const a = await navigator.requestMIDIAccess({ sysex: true });
	    T.a = a; T.events = []; T.listened = []; T.states = [];
	    a.onstatechange = (e) => T.states.push([e.port.type, e.port.state, e.port.connection, e instanceof MIDIConnectionEvent]);
	    const fromForEach = []; a.inputs.forEach((p, k) => fromForEach.push([k, p.name]));
	    T.inp = [...a.inputs.values()].find((p) => p.name === name);
	    T.out = [...a.outputs.values()].find((p) => p.name === name);
	    const before = T.inp.connection;
	    T.inp.onmidimessage = (e) => T.events.push({ data: Array.from(e.data), u8: e.data instanceof Uint8Array, ev: e instanceof MIDIMessageEvent, target: e.target === T.inp });
	    T.inp.addEventListener("midimessage", (e) => T.listened.push(Array.from(e.data)));
	    const opened = await T.out.open();
	    return { sysex: a.sysexEnabled, isMap: a.inputs instanceof Map, forEach: fromForEach.length, nIn: a.inputs.size, nOut: a.outputs.size,
	      inState: T.inp.state, before, after: T.inp.connection, inId: T.inp.id, outId: T.out.id, type: T.inp.type + "/" + T.out.type,
	      manufacturer: typeof T.inp.manufacturer, openResolves: opened === T.out, same: (await navigator.requestMIDIAccess()) === a,
	      keyIsId: a.inputs.get(T.inp.id) === T.inp };
	  },
	  got() { return { events: T.events, listened: T.listened, states: T.states, inState: T.inp.state }; },
	  trySend(d) { try { T.out.send(d); return "sent"; } catch (e) { return e.name; } },
	};
	</script>
	"""

	func testShimAgainstAFakeFM1() async throws {
		let f = try FakeFM1(sourceAPI: .legacy, destinationAPI: .universal)
		let h = try WebHarness(filter: f.filter, resolver: { _ in (Data(Self.page.utf8), "text/html") })
		defer { h.close() }
		try await h.load(URL(string: "fm1dock://app/index.html")!)
		let r0 = try await h.js("return await T.setup(n)", ["n": f.portName])
		let r = try XCTUnwrap(r0 as? [String: Any])
		XCTAssertEqual(r["sysex"] as? Bool, true)
		XCTAssertEqual(r["isMap"] as? Bool, true)
		XCTAssertEqual(r["nIn"] as? Int, 1, "only the fake's ports: \(r)")
		XCTAssertEqual(r["nOut"] as? Int, 1)
		XCTAssertEqual(r["forEach"] as? Int, 1)
		XCTAssertEqual(r["inState"] as? String, "connected")
		XCTAssertEqual(r["before"] as? String, "closed")
		XCTAssertEqual(r["after"] as? String, "open", "onmidimessage opens the input")
		XCTAssertEqual(r["type"] as? String, "input/output")
		XCTAssertEqual(r["openResolves"] as? Bool, true)
		XCTAssertEqual(r["same"] as? Bool, true)
		XCTAssertEqual(r["keyIsId"] as? Bool, true)

		// page -> device: a 700-byte SysEx as a Uint8Array, then an Array, then two notes in one send
		let sysex = VirtualEndpointTests.sysex700
		XCTAssertEqual(sysex.count, 700)
		let v1 = try await h.js("return T.trySend(new Uint8Array(d))", ["d": sysex.map(Int.init)]) as? String
		XCTAssertEqual(v1, "sent")
		let v2 = try await h.js("return T.trySend(d)", ["d": sysex.reversed().map { Int($0 == 0xF0 ? 0xF7 : $0 == 0xF7 ? 0xF0 : $0) }]) as? String
		XCTAssertEqual(v2, "sent")
		let v3 = try await h.js("return T.trySend([0x90, 60, 100, 0x80, 60, 0])") as? String
		XCTAssertEqual(v3, "sent")
		let v4 = try await h.js("return T.trySend([0x90, 300, 1])") as? String
		XCTAssertEqual(v4, "TypeError")
		let rev: [UInt8] = sysex.reversed().map { $0 == 0xF0 ? 0xF7 : $0 == 0xF7 ? 0xF0 : $0 }
		let end = Date().addingTimeInterval(5)
		while f.received.count < 4 && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
		XCTAssertEqual(f.received, [sysex, rev, [0x90, 60, 100], [0x80, 60, 0]])

		// device -> page: the awkward packets become exactly the right events, for the handler and the listener
		f.emit(packetLists: Awkward.coreMIDIPackets.map { [$0] })
		try await h.waitFor("T.events.length >= \(Awkward.events.count) && T.listened.length >= \(Awkward.events.count)", timeout: 5)
		try await Task.sleep(nanoseconds: 200_000_000)
		let got0 = try await h.js("return T.got()")
		let got = try XCTUnwrap(got0 as? [String: Any])
		let events = try XCTUnwrap(got["events"] as? [[String: Any]])
		XCTAssertEqual(events.map { ($0["data"] as? [Int] ?? []).map(UInt8.init) }, Awkward.events)
		XCTAssertTrue(events.allSatisfy { $0["u8"] as? Bool == true && $0["ev"] as? Bool == true && $0["target"] as? Bool == true })
		XCTAssertEqual((got["listened"] as? [[Int]])?.map { $0.map(UInt8.init) }, Awkward.events)

		// a reply cut into 16-byte packets, as a device's long SysEx comes over USB
		f.chunkSize = 16
		let long: [UInt8] = [0xF0, 0x7D] + (0..<300).map { UInt8($0 % 128) } + [0xF7]
		f.emit(packetLists: stride(from: 0, to: long.count, by: 16).map { [Array(long[$0..<min($0 + 16, long.count)])] })
		try await h.waitFor("T.events.length >= \(Awkward.events.count + 1)", timeout: 5)
		let last = try await h.js("return T.events[T.events.length - 1].data") as? [Int]
		XCTAssertEqual(last?.map(UInt8.init), long)

		// unplugged: the port stays in its map, disconnected; send throws at once; statechange told the page
		f.unplug()
		try await h.waitFor("T.inp.state === 'disconnected' && T.out.state === 'disconnected'", timeout: 5)
		let v5 = try await h.js("return T.trySend([0x90, 60, 1])") as? String
		XCTAssertEqual(v5, "InvalidStateError")
		let v6 = try await h.js("return T.a.inputs.size") as? Int
		XCTAssertEqual(v6, 1)
		// back under new ids (a virtual endpoint always is): the dead ports of its name give way to the new ones
		try f.replug()
		try await h.waitFor("[...T.a.inputs.values()].some((p) => p.state === 'connected')", timeout: 5)
		let names = try await h.js("return [[...T.a.inputs.values()].map((p) => p.name + ':' + p.state), [...T.a.outputs.values()].map((p) => p.name + ':' + p.state)]") as? [[String]]
		XCTAssertEqual(names, [["\(f.portName):connected"], ["\(f.portName):connected"]])
		let states0 = try await h.js("return T.states")
		let states = try XCTUnwrap(states0 as? [[Any]])
		XCTAssertTrue(states.contains { $0[0] as? String == "input" && $0[1] as? String == "disconnected" && $0[3] as? Bool == true }, "\(states)")
	}

	/// The engine's callbacks on a queue that is not the main one: the bridge must hop to the main actor itself
	/// (with MainActor.assumeIsolated alone this test traps, as a main-actor closure run off the main thread does).
	func testTheBridgeCopesWithCallbacksOffTheMainQueue() async throws {
		let f = try FakeFM1()
		let page = "<!doctype html><script>window.go = async (n) => { const a = await navigator.requestMIDIAccess({ sysex: true }); const i = [...a.inputs.values()].find((p) => p.name === n); window.got = []; i.onmidimessage = (e) => got.push(Array.from(e.data)); return a.inputs.size; }</script>"
		let h = try WebHarness(filter: f.filter, resolver: { _ in (Data(page.utf8), "text/html") },
		                       callbackQueue: DispatchQueue(label: "not main"))
		defer { h.close() }
		try await h.load(URL(string: "fm1dock://app/index.html")!)
		try await h.waitFor("true")
		let end = Date().addingTimeInterval(5)
		while h.engine.endpoints.count < 2 && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
		let n = try await h.js("return await go(n)", ["n": f.portName]) as? Int
		XCTAssertEqual(n, 1)
		f.emit(packetLists: [[[0xF0, 1, 2, 0xF7]], [[0x90, 60, 1]]])
		try await h.waitFor("window.got.length >= 2", timeout: 5)
		let got = try await h.js("return window.got") as? [[Int]]
		XCTAssertEqual(got, [[0xF0, 1, 2, 0xF7], [0x90, 60, 1]])
	}

	/// A hidden about:blank frame of the page's own (Baud Girl's "fresh look") gets the same, live MIDIAccess.
	func testASameOriginFrameGetsTheSameAccess() async throws {
		let f = try FakeFM1()
		let page = "<!doctype html><body><script>window.go = async (n) => { const a = await navigator.requestMIDIAccess({ sysex: true }); const fr = document.createElement('iframe'); fr.hidden = true; document.body.append(fr); const b = await fr.contentWindow.navigator.requestMIDIAccess({ sysex: true }); return [a === b, [...b.inputs.values()].some((p) => p.name === n)]; }</script>"
		let h = try WebHarness(filter: f.filter, resolver: { _ in (Data(page.utf8), "text/html") })
		defer { h.close() }
		try await h.load(URL(string: "fm1dock://app/index.html")!)
		let end = Date().addingTimeInterval(5)
		while h.engine.endpoints.count < 2 && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
		let r = try await h.js("return await go(n)", ["n": f.portName]) as? [Bool]
		XCTAssertEqual(r, [true, true])
	}

	func testOnMainFromAnyThread() async {
		let done = expectation(description: "ran on the main actor")
		DispatchQueue.global().async { onMain { XCTAssertTrue(Thread.isMainThread); done.fulfill() } }
		await fulfillment(of: [done], timeout: 2)
	}

	/// A page of an origin the app does not allow gets no Web MIDI.
	func testOtherOriginsGetNoMIDI() async throws {
		let f = try FakeFM1()
		let h = try WebHarness(filter: f.filter, resolver: { _ in (Data("<!doctype html><p>x".utf8), "text/html") },
		                       allowedOrigins: ["https://thefirmwarehub.com"])
		defer { h.close() }
		try await h.load(URL(string: "fm1dock://app/index.html")!)
		let v7 = try await h.js("return typeof navigator.requestMIDIAccess") as? String
		XCTAssertEqual(v7, "undefined")
		// and the handler refuses a post from it
		let r = try? await h.js("return await window.webkit.messageHandlers.fm1midi.postMessage({ op: 'access' })")
		XCTAssertNil(r)
	}
}

/// fm1-dock's own page (vendor/fm1-dock/docs/index.html: dock.js, hub.js, console.js, install/*), unchanged, served
/// from the vendored copy, against a FakeFM1.
@MainActor
final class DockPageTests: XCTestCase {
	func testConsoleAndDeviceConnectAndAModuleDeploysFromAFileInput() async throws {
		try Repo.needDocs()
		try Repo.needDocs("modules/arp2600.dock")
		let f = try FakeFM1()
		let h = try WebHarness(filter: f.filter, resolver: LocalSchemeHandler.directory(Repo.docs))
		defer { h.close() }
		try await h.load(URL(string: "fm1dock://app/index.html")!)
		try await h.waitFor("typeof navigator.requestMIDIAccess === 'function'")
		let v8 = try await h.js("return document.getElementById('nomidi').hidden") as? Bool
		XCTAssertEqual(v8, true, "the page's no-WebMIDI notice")

		// the console: Connect -> HELLO, LIST -> "connected: <port>"
		try await h.js("document.getElementById('c-connect').click()")
		do { try await h.waitFor("document.getElementById('c-state').textContent.startsWith('connected:')", timeout: 20) } catch {
			let state = (try? await h.text("#c-state")) ?? "?"
			let ports = (try? await h.js("const a = await navigator.requestMIDIAccess(); return [...a.inputs.values(), ...a.outputs.values()].map((p) => p.type + ':' + p.name + ':' + p.state).join(', ')")) ?? "?"
			XCTFail("console not connected: c-state '\(state)'; ports \(ports); engine \(h.engine.endpoints.map(\.name)); fake got \(f.received.count) messages; events \(f.events.suffix(5))")
			throw error
		}
		let v9 = try await h.text("#c-state")
		XCTAssertEqual(v9, "connected: \(f.portName)")

		// "Your device": the updater's handshake, then HELLO, LIST, INFO, LOG
		try await h.js("document.getElementById('dev-connect').click()")
		try await h.waitFor("document.getElementById('dev-pill').textContent === 'FM-1 · fm1-dock'", timeout: 20)
		XCTAssertTrue(f.received.contains(FM1Protocol.handshakeQuery))

		// a .dock handed to the console's file input, as the app's library does: deployed, every byte
		let blob = try Data(contentsOf: Repo.docs.appendingPathComponent("modules/arp2600.dock"))
		let input = try await h.js(PageScripts.giveFile, ["name": "arp2600.dock", "base64": blob.base64EncodedString()]) as? String
		XCTAssertEqual(input, "c-deploy-file")
		try await h.waitFor("/in flash at/.test(document.getElementById('c-deploy-msg').textContent)", timeout: 30)
		XCTAssertTrue(h.dialogs.contains { $0.hasPrefix("Deploy ARP 2600") }, "\(h.dialogs)")
		XCTAssertEqual(f.deployedModules.first?.name, "ARP 2600")
		XCTAssertEqual(f.deployedModules.first?.blob, [UInt8](blob))
	}
}

/// The live sites, over the network, with an iPhone's user agent, against a FakeFM1 only (set FM1_OFFLINE=1 to skip).
@MainActor
final class LiveSiteTests: XCTestCase {
	static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

	override func setUp() async throws {
		if ProcessInfo.processInfo.environment["FM1_OFFLINE"] != nil { throw XCTSkip("FM1_OFFLINE set") }
	}

	func testFirmwareHubConnectsWithAnIPhoneUserAgent() async throws {
		let f = try FakeFM1()
		let h = try WebHarness(filter: f.filter, allowedOrigins: ["https://thefirmwarehub.com"], userAgent: Self.iPhoneUA)
		defer { h.close() }
		do { try await h.load(URL(string: "https://thefirmwarehub.com/")!, timeout: 40) } catch { throw XCTSkip("no network: \(error)") }
		try await h.waitFor("typeof navigator.requestMIDIAccess === 'function' && !!document.getElementById('connect')")
		let v10 = try await h.js("return !!(window.hubApp && window.hubApp.ios)") as? Bool
		XCTAssertEqual(v10, true, "the hub sees an iPhone")
		for _ in 0..<3 { let b = await h.bridge.pageIsBusy(); XCTAssertFalse(b, "the hub at rest is not busy") }
		try await h.js("document.getElementById('connect').click()")
		try await h.waitFor("/On your FM-1/.test(document.getElementById('now').textContent)", timeout: 20)
		XCTAssertTrue(f.received.contains(FM1Protocol.handshakeQuery))
		// what is shown (innerText: not the scripts' text) never says installing does not work here
		let shown = try await h.js("return document.body.innerText") as? String ?? ""
		XCTAssertFalse(shown.contains("doesn't work on iPhone"), "the hub's iOS notice is shown")
		XCTAssertFalse(shown.contains("No FM-1 found"))
	}

	/// The case seen on a real FM-1 (Skiff 2.7 from the Hub, the loader gone 27 requests into its write), replayed on
	/// the live Hub against the simulated FM-1: running fm1-dock (FM-1_921), its loader Skiff's own (ota-FM-1_727),
	/// which drops its USB 27 requests into the write and comes back. Records what the Hub says the first time and
	/// on Install again. Only the fake is ever written to (and the fake's write is cut short by design).
	func testFirmwareHubWhenTheLoaderVanishesMidWrite() async throws {
		let f = try FakeFM1(identity: "FM-1_921", dockVersion: "0.9", imageLength: 0x10000, product: "FM-1_727")
		f.loaderVersion = "727"
		f.dropLoaderAfter = 27
		let h = try WebHarness(filter: f.filter, allowedOrigins: ["https://thefirmwarehub.com"], userAgent: Self.iPhoneUA)
		defer { h.close() }
		do { try await h.load(URL(string: "https://thefirmwarehub.com/")!, timeout: 40) } catch { throw XCTSkip("no network: \(error)") }
		let card = ".fw[data-id=\"skiff\"]"
		try await h.waitFor("!!document.querySelector('\(card) button.go')", timeout: 20)
		func attempt() async throws -> String {
			try await h.js("document.querySelector('\(card) button.go').click()")
			do { try await h.waitFor("(() => { const d = document.getElementById('askdlg'); return !!(d && d.open) })()", timeout: 30) } catch {
				XCTFail("no install question; the card says: \((try? await h.text("\(card) .msg")) ?? "?"); device: \(f.events.suffix(4))")
				throw error
			}
			try await h.js("document.querySelector('#askdlg .yes').click()")
			try await h.waitFor("(() => { const m = document.querySelector('\(card) .msg').textContent; return /:/.test(m) && !/Writing|Looking|Loading|starts|reads/.test(m) && !document.querySelector('\(card) button.go').disabled })()",
			                    timeout: 150, poll: 500_000_000)
			return try await h.text("\(card) .msg")
		}
		let first = try await attempt()
		let busyAfter = await h.bridge.pageIsBusy()
		try await Task.sleep(nanoseconds: 3_000_000_000)                  // (the loader is back)
		let second = try await attempt()
		print("The Hub, the loader gone mid-write:\n first: \(first)\n busy after: \(busyAfter)\n Install again: \(second)\n device: \(f.events.suffix(8).joined(separator: " | "))")
		XCTAssertTrue(first.hasPrefix("lost:"), first)
		XCTAssertFalse(busyAfter, "the Hub's page is not busy after the failure")
		XCTAssertTrue(second.hasPrefix("foreign:"), "the Hub does not resume another firmware's loader: \(second)")
		XCTAssertEqual(f.received.filter { $0 == FM1Protocol.upgrade }.count, 2, "nothing more was written on Install again")
	}

	/// The Hub's own "Saves on newer FM-1s" filter, as the app uses it: the page opened at #newchip has it on (only
	/// cards flagged new or any shown), and its own checkbox turns it off again.
	func testFirmwareHubNewerChipFilter() async throws {
		let f = try FakeFM1()
		let h = try WebHarness(filter: f.filter, allowedOrigins: ["https://thefirmwarehub.com"], userAgent: Self.iPhoneUA)
		defer { h.close() }
		let url = HubFilter.startURL(URL(string: "https://thefirmwarehub.com/")!, .filtered)
		do { try await h.load(url, timeout: 40) } catch { throw XCTSkip("no network: \(error)") }
		let visible = "[...document.querySelectorAll('#grid .fw')].filter((e) => !e.hidden && e.offsetParent !== null).map((e) => e.dataset.id)"
		try await h.waitFor("document.querySelectorAll('#grid .fw').length > 20 && !!document.querySelector('#fpanel input[value=newchip]')", timeout: 30)
		let on = try await h.js(HubFilter.isOnJS) as? Bool
		XCTAssertEqual(on, true, "the page took #newchip")
		let shownFiltered = try await h.js("return \(visible)") as? [String] ?? []
		let catalog = try await h.js("return (await (await fetch('/catalog.json')).json()).firmwares.map((f) => [f.id, f.chip || ''])") as? [[String]] ?? []
		let chipOf = Dictionary(catalog.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
		XCTAssertFalse(shownFiltered.isEmpty)
		XCTAssertTrue(shownFiltered.allSatisfy { ["new", "any"].contains(chipOf[$0] ?? "?") }, "only newer-chip firmwares: \(shownFiltered.filter { !["new", "any"].contains(chipOf[$0] ?? "?") })")
		let turned = try await h.js(HubFilter.turnOffJS) as? Bool
		XCTAssertEqual(turned, true)
		try await Task.sleep(nanoseconds: 500_000_000)
		let off = try await h.js(HubFilter.isOnJS) as? Bool
		XCTAssertEqual(off, false)
		let shownAll = try await h.js("return \(visible)") as? [String] ?? []
		XCTAssertGreaterThan(shownAll.count, shownFiltered.count, "Show all shows more")
	}

	func testDockSiteConsoleConnectsWithAnIPhoneUserAgent() async throws {
		let f = try FakeFM1()
		let h = try WebHarness(filter: f.filter, allowedOrigins: ["https://joakimeriksson.github.io"], userAgent: Self.iPhoneUA)
		defer { h.close() }
		do { try await h.load(URL(string: "https://joakimeriksson.github.io/fm1-dock/")!, timeout: 40) } catch { throw XCTSkip("no network: \(error)") }
		try await h.waitFor("typeof navigator.requestMIDIAccess === 'function'")
		let v12 = try await h.js("return document.getElementById('nomidi').hidden") as? Bool
		XCTAssertEqual(v12, true)
		try await h.js("document.getElementById('c-connect').click()")
		try await h.waitFor("document.getElementById('c-state').textContent.startsWith('connected:')", timeout: 20)
		try await h.js("document.getElementById('dev-connect').click()")
		try await h.waitFor("document.getElementById('dev-pill').textContent === 'FM-1 · fm1-dock'", timeout: 20)
	}
}
#endif
