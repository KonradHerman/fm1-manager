// SPDX-License-Identifier: GPL-3.0-only
import CoreMIDI
import XCTest
@testable import FM1Kit
import FM1KitTestSupport

/// Spins the main run loop until `cond` holds (CoreMIDI's notifications and the engine's callbacks come there).
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ what: String = "", file: StaticString = #filePath, line: UInt = #line,
               _ cond: () -> Bool) {
	let end = Date().addingTimeInterval(timeout)
	while !cond() {
		if Date() > end { XCTFail("timed out: \(what)", file: file, line: line); return }
		RunLoop.main.run(until: Date().addingTimeInterval(0.01))
	}
}

@MainActor
func settle(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// Collects what an engine reports, on the main queue.
@MainActor
final class Recorder {
	var endpoints: [MIDIEndpointInfo] = []
	var messages: [MIDIReceivedMessage] = []
	var observation: MIDIEngine.Observation?
	init(_ engine: MIDIEngine) {
		observation = engine.observe(
			endpoints: { [weak self] l in MainActor.assumeIsolated { self?.endpoints = l } },
			messages: { [weak self] m in MainActor.assumeIsolated { self?.messages += m } })
	}
}

/// CoreMIDI for real, on virtual endpoints only: every engine here gets the fake's filter (its unique name), so a
/// real device on this Mac is never listed, connected or sent to.
@MainActor
final class VirtualEndpointTests: XCTestCase {
	static let sysex700: [UInt8] = [0xF0, 0x7D] + (0..<697).map { UInt8(($0 * 37 + 11) % 128) } + [0xF7]

	func makeEngine(_ fake: FakeFM1, input: MIDIEngine.PacketAPI = .universal, output: MIDIEngine.PacketAPI = .universal) throws -> MIDIEngine {
		let engine = try MIDIEngine(clientName: "FM1KitTests", inputAPI: input, outputAPI: output, filter: fake.filter)
		waitUntil(5, "the fake's two endpoints") { engine.endpoints.count == 2 }
		XCTAssertTrue(engine.endpoints.allSatisfy { $0.name == fake.portName }, "\(engine.endpoints)")
		return engine
	}

	func testOnlyTheFakesEndpointsAreListed() throws {
		let fake = try FakeFM1()
		let engine = try makeEngine(fake)
		XCTAssertEqual(Set(engine.endpoints.map(\.kind)), [.input, .output])
		XCTAssertEqual(Set(engine.endpoints.map(\.name)), [fake.portName])
		// a second fake is not the first one's: its filter does not let it in
		let other = try FakeFM1()
		settle(0.3)
		engine.rescan()
		XCTAssertFalse(engine.endpoints.contains { $0.name == other.portName })
	}

	/// A 700-byte SysEx as the page posts it (an array of numbers) reaches the virtual destination whole: every
	/// combination of the engine's output API and the destination's protocol.
	func test700ByteSysExFromJSShapedInputArrivesIntact() throws {
		for out in MIDIEngine.PacketAPI.allCases {
			for dest in [FakeFM1.EndpointAPI.universal, .legacy] {
				let fake = try FakeFM1(destinationAPI: dest)
				let engine = try makeEngine(fake, output: out)
				let outID = try XCTUnwrap(engine.endpoints.first { $0.kind == .output }?.id)
				let body: [String: Any] = ["op": "send", "id": outID, "data": Self.sysex700.map { NSNumber(value: $0) }, "delay": 0]
				let (id, bytes, delay) = try XCTUnwrap(WebMIDIWire.send(from: body))
				try engine.send(bytes, to: id, delay: delay)
				try engine.send([0x90, 0x3C, 0x64], to: id)                       // and a note after it, in order
				waitUntil(5, "700 B via \(out) to a \(dest) destination") { fake.received.count >= 2 }
				settle(0.1)
				XCTAssertEqual(fake.received.count, 2, "\(out) -> \(dest)")
				XCTAssertEqual(fake.received.first, Self.sysex700, "\(out) -> \(dest): the SysEx differs")
				XCTAssertEqual(fake.received.last, [0x90, 0x3C, 0x64])
			}
		}
	}

	func testManyLongSysExStayInOrder() throws {
		let fake = try FakeFM1()
		let engine = try makeEngine(fake)
		let out = try XCTUnwrap(engine.endpoints.first { $0.kind == .output }?.id)
		let msgs = (0..<50).map { k in [0xF0, UInt8(k)] + [UInt8](repeating: UInt8(k), count: 600) + [0xF7] }
		for m in msgs { try engine.send(m, to: out) }
		waitUntil(10, "50 SysEx") { fake.received.count >= 50 }
		XCTAssertEqual(fake.received, msgs)
	}

	/// send(data, timestamp) in the future: CoreMIDI holds it until then (both output APIs).
	func testTimestampedSendIsDelayed() throws {
		for out in MIDIEngine.PacketAPI.allCases {
			let fake = try FakeFM1()
			let engine = try makeEngine(fake, output: out)
			let id = try XCTUnwrap(engine.endpoints.first { $0.kind == .output }?.id)
			let t0 = Date()
			try engine.send([0x90, 0x40, 0x40], to: id, delay: 0.4)
			try engine.send([0x90, 0x41, 0x40], to: id)
			waitUntil(5, "\(out)") { fake.received.count >= 2 }
			XCTAssertEqual(fake.received, [[0x90, 0x41, 0x40], [0x90, 0x40, 0x40]], "\(out): the later one first")
			XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.35, "\(out)")
		}
	}

	func testIncompleteMessagesAreRefused() throws {
		let fake = try FakeFM1()
		let engine = try makeEngine(fake)
		let out = try XCTUnwrap(engine.endpoints.first { $0.kind == .output }?.id)
		XCTAssertThrowsError(try engine.send([0xF0, 0x01, 0x02], to: out))
		XCTAssertThrowsError(try engine.send([0x90, 0x3C], to: "no-such-port"))
	}

	/// Packets cut as awkwardly as CoreMIDI allows (a SysEx split mid-message over three packets with a clock between
	/// them, a note and running status after its end in the same packet, two SysEx in one packet), each packet its
	/// own MIDIReceived call: the engine reports exactly the right messages, with either input API.
	func testAwkwardChunksFromVirtualSourceAreReassembled() throws {
		for api in MIDIEngine.PacketAPI.allCases {
			let fake = try FakeFM1(sourceAPI: .legacy)
			let engine = try makeEngine(fake, input: api)
			let rec = Recorder(engine)
			settle(0.1)
			fake.emit(packetLists: Awkward.coreMIDIPackets.map { [$0] })
			waitUntil(5, "\(api): \(Awkward.events.count) messages") { rec.messages.count >= Awkward.events.count }
			settle(0.2)
			XCTAssertEqual(rec.messages.map(\.bytes), Awkward.events, "\(api) input")
			XCTAssertTrue(Awkward.isRight(rec.messages.map(\.bytes)))
		}
	}

	/// The same packets all in one packet list (one MIDIReceived call).
	func testAwkwardChunksInOnePacketList() throws {
		for api in MIDIEngine.PacketAPI.allCases {
			let fake = try FakeFM1(sourceAPI: .legacy)
			let engine = try makeEngine(fake, input: api)
			let rec = Recorder(engine)
			settle(0.1)
			fake.emit(packetLists: [Awkward.coreMIDIPackets])
			waitUntil(5, "\(api)") { rec.messages.count >= Awkward.events.count }
			settle(0.2)
			XCTAssertEqual(rec.messages.map(\.bytes), Awkward.events, "\(api) input")
		}
	}

	/// A source that speaks UMP: SysEx7 start / continue / end in separate event lists with a clock between, then two
	/// whole SysEx in one list.
	func testUMPSysEx7FromVirtualSourceIsReassembled() throws {
		let long: [UInt8] = [0xF0] + Array(1...40) + [0xF7]
		let p = UMP.packets(forMessage: long)                      // 7 packets: start, 5 continue, end
		let lists: [[[UInt32]]] = [
			[p[0], p[1]],
			[[0x10F8_0000]],
			[p[2], p[3], p[4]],
			[p[5], p[6]],
			UMP.packets(forMessage: [0xF0, 0x7D, 0x01, 0xF7]) + UMP.packets(forMessage: [0xF0, 0x7D, 0x02, 0xF7]),
		]
		let want: [[UInt8]] = [[0xF8], long, [0xF0, 0x7D, 0x01, 0xF7], [0xF0, 0x7D, 0x02, 0xF7]]
		for api in MIDIEngine.PacketAPI.allCases {
			let fake = try FakeFM1(sourceAPI: .universal)
			let engine = try makeEngine(fake, input: api)
			let rec = Recorder(engine)
			settle(0.1)
			fake.emit(umpLists: lists)
			waitUntil(5, "\(api)") { rec.messages.count >= want.count }
			settle(0.2)
			XCTAssertEqual(rec.messages.map(\.bytes), want, "\(api) input")
		}
	}

	func testHotPlug() throws {
		let token = String(UUID().uuidString.prefix(8))
		let engine = try MIDIEngine(clientName: "FM1KitTests", filter: { $0.name.hasSuffix(" Test \(token)") })
		let rec = Recorder(engine)
		settle(0.2)
		XCTAssertTrue(engine.endpoints.isEmpty)
		var fake: FakeFM1? = try FakeFM1(token: token)
		waitUntil(5, "plugged in") { rec.endpoints.count == 2 }
		let ids = Set(rec.endpoints.map(\.id))
		fake = nil
		_ = fake
		waitUntil(5, "unplugged") { rec.endpoints.isEmpty }
		fake = try FakeFM1(token: token)
		waitUntil(5, "plugged in again") { rec.endpoints.count == 2 }
		XCTAssertEqual(rec.endpoints.count, 2)
		_ = ids
	}
}
