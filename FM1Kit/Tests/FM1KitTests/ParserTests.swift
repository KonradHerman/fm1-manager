// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import FM1Kit

/// The awkward stream the CoreMIDI tests send too: packets as a USB transfer might cut them.
enum Awkward {
	static let sysexA: [UInt8] = [0xF0] + Array(UInt8(1)...0x30) + [0xF7]
	/// Each element is one packet.
	static let packets: [[UInt8]] = [
		[0xF0, 0x01, 0x02, 0x03],                                  // a SysEx starts...
		Array(4...0x10) + [0xF8] + [0x11, 0x12],                   // ...a clock in the middle of it...
		Array(0x13...0x30) + [0xF7, 0x90, 0x3C, 0x64],             // ...it ends, and a note on follows in the same packet
		[0x3E, 0x64],                                              // running status: another note on
		[0xF0, 0x7D, 0x01, 0xF7, 0xF0, 0x7D, 0x02, 0xF7],          // two SysEx in one packet
		[0xB0, 0x07],                                              // a CC cut in two
		[0x7F],
	]
	/// The events a page must get for them, in order.
	static let events: [[UInt8]] = [
		[0xF8],
		sysexA,
		[0x90, 0x3C, 0x64],
		[0x90, 0x3E, 0x64],
		[0xF0, 0x7D, 0x01, 0xF7],
		[0xF0, 0x7D, 0x02, 0xF7],
		[0xB0, 0x07, 0x7F],
	]
	static func isRight(_ got: [[UInt8]]) -> Bool { got == events }

	/// As awkward as CoreMIDI lets a source be. Its MIDIPacket contract: whole messages in a packet, except a SysEx,
	/// which may run over several, with real-time messages between its packets. (It rewrites packets that break it,
	/// before any client sees them: a clock inside a SysEx's packet ends that SysEx, a CC cut over two packets is
	/// lost. A USB-MIDI driver's packets keep the contract: USB-MIDI events are whole messages or SysEx pieces.)
	static let coreMIDIPackets: [[UInt8]] = [
		[0xF0, 0x01, 0x02, 0x03],                                  // a SysEx starts, split mid-message...
		Array(4...0x10),
		[0xF8],                                                    // ...a clock in the middle of it...
		Array(0x11...0x30) + [0xF7, 0x90, 0x3C, 0x64, 0x3E, 0x64], // ...its end, a note on and one by running status
		[0xF0, 0x7D, 0x01, 0xF7, 0xF0, 0x7D, 0x02, 0xF7],          // two SysEx in one packet
		[0xB0, 0x07, 0x7F],
	]
}

final class ParserTests: XCTestCase {
	func testAwkwardPacketsBecomeExactlyTheRightMessages() {
		var p = MIDIStreamParser()
		let got = Awkward.packets.flatMap { p.feed($0) }
		XCTAssertEqual(got, Awkward.events)
		var q = MIDIStreamParser()
		XCTAssertEqual(Awkward.coreMIDIPackets.flatMap { q.feed($0) }, Awkward.events)
	}

	/// The check above must fail for a bridge that hands each packet to the page as it came (no reassembly):
	/// it would fail if reassembly were skipped.
	func testTheCheckFailsWithoutReassembly() {
		let naive = Awkward.packets                                    // one event per packet
		XCTAssertFalse(Awkward.isRight(naive))
		XCTAssertFalse(Awkward.isRight(Awkward.coreMIDIPackets))
		// and a per-packet parser (state thrown away between packets) is caught as well
		let perPacket = Awkward.packets.flatMap { pkt -> [[UInt8]] in var p = MIDIStreamParser(); return p.feed(pkt) }
		XCTAssertFalse(Awkward.isRight(perPacket))
	}

	func testByteAtATime() {
		var p = MIDIStreamParser()
		let got = Awkward.packets.joined().flatMap { p.feed([$0]) }
		XCTAssertEqual(got, Awkward.events)
	}

	func testSysExCutOffByAStatusIsDropped() {
		var p = MIDIStreamParser()
		XCTAssertEqual(p.feed([0xF0, 0x01, 0x02, 0x90, 0x40, 0x10, 0xF7]), [[0x90, 0x40, 0x10]])
	}

	func testStrayDataAndUndefinedStatusesAreDropped() {
		var p = MIDIStreamParser()
		XCTAssertEqual(p.feed([0x01, 0x02, 0xF7, 0xF4, 0x05, 0xC0, 0x05, 0x06]), [[0xC0, 0x05], [0xC0, 0x06]])
	}

	func testSystemCommonClearsRunningStatus() {
		var p = MIDIStreamParser()
		XCTAssertEqual(p.feed([0x90, 0x40, 0x7F, 0xF2, 0x01, 0x02, 0x41, 0x7F, 0xF6, 0xF1, 0x10, 0xF3, 0x02]),
		               [[0x90, 0x40, 0x7F], [0xF2, 0x01, 0x02], [0xF6], [0xF1, 0x10], [0xF3, 0x02]])
	}

	func testRealTimeInsideAChannelMessage() {
		var p = MIDIStreamParser()
		XCTAssertEqual(p.feed([0x90, 0x40, 0xFE, 0x7F]), [[0xFE], [0x90, 0x40, 0x7F]])
	}

	func testSplitForSending() {
		XCTAssertTrue(MIDIStreamParser.split([0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00]).complete)
		XCTAssertEqual(MIDIStreamParser.split([0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00]).messages.count, 2)
		XCTAssertFalse(MIDIStreamParser.split([0xF0, 0x01, 0x02]).complete)           // no F7
		XCTAssertFalse(MIDIStreamParser.split([0x90, 0x3C]).complete)                 // no velocity
		XCTAssertFalse(MIDIStreamParser.split([0x90, 0x3C, 0x64, 0x3E, 0x64]).complete) // running status: refused, as Chrome does
		let big = [0xF0] + (0..<698).map { UInt8($0 % 128) } + [0xF7]
		XCTAssertEqual(MIDIStreamParser.split(big).messages, [big])
	}
}

final class UMPTests: XCTestCase {
	func testSysExRoundTrip() {
		for n in [0, 1, 5, 6, 7, 12, 13, 698] {
			let m = [0xF0] + (0..<n).map { UInt8(($0 * 7) % 128) } + [0xF7]
			let packets = UMP.packets(forMessage: m)
			XCTAssertEqual(packets.count, max(1, (n + 5) / 6), "\(n)")
			var p = MIDIStreamParser()
			XCTAssertEqual(p.feed(UMP.midi1Bytes(fromWords: packets.joined())), [m], "\(n) data bytes")
		}
	}

	func testSysEx7StartContinueEndWithRealTimeBetween() {
		let m: [UInt8] = [0xF0] + Array(1...20) + [0xF7]
		var packets = UMP.packets(forMessage: m)                       // start, continue, continue, end
		XCTAssertEqual(packets.map { ($0[0] >> 20) & 0xF }, [1, 2, 2, 3])
		packets.insert([0x10F8_0000], at: 2)                           // a clock between two of its packets
		var p = MIDIStreamParser()
		XCTAssertEqual(p.feed(UMP.midi1Bytes(fromWords: packets.joined())), [[0xF8], m])
	}

	func testChannelAndSystemMessages() {
		let msgs: [[UInt8]] = [[0x90, 0x3C, 0x64], [0xC3, 0x05], [0xD1, 0x40], [0xE0, 0x00, 0x40], [0xF2, 0x10, 0x20], [0xF8], [0xF1, 0x33]]
		let words = msgs.flatMap(UMP.packets(forMessage:)).joined()
		var p = MIDIStreamParser()
		XCTAssertEqual(p.feed(UMP.midi1Bytes(fromWords: words)), msgs)
	}

	func testMIDI2AndUtilityPacketsAreSkipped() {
		let words: [UInt32] = [0x0000_0000, 0x4090_3C00, 0xFFFF_0000, 0x2090_3C64]   // NOOP, MIDI 2.0 note (2 words), note
		XCTAssertEqual(UMP.midi1Bytes(fromWords: words), [0x90, 0x3C, 0x64])
	}
}
