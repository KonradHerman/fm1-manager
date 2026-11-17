// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import FM1KitTestSupport
import XCTest

/// A clock and a timer queue the test turns by hand.
final class ManualTime: @unchecked Sendable {
	private let lock = NSLock()
	private(set) var t: TimeInterval = 100
	private var jobs: [(TimeInterval, @Sendable () -> Void)] = []
	var now: @Sendable () -> TimeInterval { { [unowned self] in lock.withLock { t } } }
	var after: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void {
		{ [unowned self] d, f in lock.withLock { jobs.append((t + d, f)) } }
	}
	func advance(_ d: TimeInterval) {
		let target = lock.withLock { t + d }
		while true {
			let next: (TimeInterval, @Sendable () -> Void)? = lock.withLock {
				guard let i = jobs.indices.filter({ jobs[$0].0 <= target }).min(by: { jobs[$0].0 < jobs[$1].0 }) else { return nil }
				let j = jobs.remove(at: i); t = max(t, j.0); return j
			}
			guard let job = next else { break }
			job.1()
		}
		lock.withLock { t = target }
	}
}

final class Sink: @unchecked Sendable {
	private let lock = NSLock()
	private var _msgs: [[UInt8]] = []
	var msgs: [[UInt8]] { lock.withLock { _msgs } }
	var send: @Sendable ([UInt8]) -> Void { { [unowned self] m in lock.withLock { _msgs.append(m) } } }
}

/// Every note on has its note off (a note on with velocity 0 counts as off), per channel and note.
func stuckNotes(_ msgs: [[UInt8]]) -> [UInt8] {
	var on: [UInt8: Int] = [:]
	for m in msgs where m.count == 3 {
		switch m[0] & 0xF0 {
		case 0x90 where m[2] > 0: on[m[1], default: 0] += 1
		case 0x80, 0x90: on[m[1], default: 0] -= 1
		default: break
		}
	}
	return on.filter { $0.value != 0 }.map(\.key).sorted()
}

final class HandsTests: XCTestCase {
	func make() -> (Hands, Sink, ManualTime) {
		let s = Sink(), t = ManualTime()
		return (Hands(send: s.send, now: t.now, after: t.after), s, t)
	}

	func testTouchesMakeNoteOnOffPairs() {
		let (h, s, _) = make()
		h.touchDown(1, note: 60, velocity: 100)
		h.touchDown(2, note: 64, velocity: 90)
		h.touchUp(1)
		h.touchUp(2)
		XCTAssertEqual(s.msgs, [[0x90, 60, 100], [0x90, 64, 90], [0x80, 60, 0], [0x80, 64, 0]])
	}

	func testSlideCancelAndTwoFingersOnOneKey() {
		let (h, s, _) = make()
		h.touchDown(1, note: 60, velocity: 100)
		h.touchMoved(1, note: 60, velocity: 100)                  // same key: nothing
		h.touchMoved(1, note: 62, velocity: 80)                   // slid on
		h.touchDown(2, note: 62, velocity: 70)                    // a second finger on the same key: no second note on
		h.touchUp(1)                                              // the other finger still holds it
		XCTAssertEqual(s.msgs, [[0x90, 60, 100], [0x80, 60, 0], [0x90, 62, 80]])
		h.touchCancelled(2)
		XCTAssertEqual(s.msgs.last, [0x80, 62, 0])
		XCTAssertEqual(stuckNotes(s.msgs), [])
	}

	func testLatchHoldsAndReleases() {
		let (h, s, _) = make()
		h.latch = true
		h.touchDown(1, note: 60, velocity: 100); h.touchUp(1)
		h.touchDown(2, note: 67, velocity: 100); h.touchUp(2)
		XCTAssertEqual(h.soundingNotes, [60, 67])
		XCTAssertEqual(stuckNotes(s.msgs), [60, 67], "latched: still on")
		h.touchDown(3, note: 60, velocity: 100); h.touchUp(3)     // touched again: off
		XCTAssertEqual(h.soundingNotes, [67])
		h.latch = false                                           // latch off: the rest stop
		XCTAssertEqual(stuckNotes(s.msgs), [])
		// a cancelled touch never stays latched
		h.latch = true
		h.touchDown(4, note: 72, velocity: 100); h.touchCancelled(4)
		XCTAssertEqual(stuckNotes(s.msgs), [])
	}

	func testReleaseAllAndPanicLeaveNothingOn() {
		let (h, s, _) = make()
		h.latch = true
		h.touchDown(1, note: 60, velocity: 100); h.touchUp(1)
		h.touchDown(2, note: 61, velocity: 100)                   // still held when the app goes away
		h.releaseAll()
		XCTAssertEqual(stuckNotes(s.msgs), [])
		h.touchUp(2)                                              // (its touch ends later: nothing more)
		h.touchDown(3, note: 50, velocity: 10)
		h.panic()
		XCTAssertEqual(stuckNotes(s.msgs), [])
		XCTAssertTrue(s.msgs.contains([0xB0, 123, 0]))
		XCTAssertEqual(s.msgs.last, [0xE0, 0, 64])
	}

	func testChannelChangeLetsGoFirst() {
		let (h, s, _) = make()
		h.touchDown(1, note: 60, velocity: 100)
		h.setChannel(4)
		h.touchDown(2, note: 62, velocity: 100); h.touchUp(2)
		XCTAssertEqual(s.msgs, [[0x90, 60, 100], [0x80, 60, 0], [0x94, 62, 100], [0x84, 62, 0]])
	}

	/// 1000 moves in one second: no more than 200 messages, every value in range, and the last value sent is the
	/// last one asked for.
	func testControlsAreRateLimitedInRangeAndEndOnTheLastValue() {
		let (h, s, t) = make()
		for i in 0..<1000 {
			h.control(.x, .cc(74), Double(i % 97) / 96)
			h.control(.y, .pitchBend, sin(Double(i) / 50))
			t.advance(0.001)
		}
		h.control(.x, .cc(74), 0.5)
		h.control(.y, .pitchBend, -1)
		t.advance(0.05)
		let x = s.msgs.filter { $0[0] == 0xB0 }, y = s.msgs.filter { $0[0] == 0xE0 }
		XCTAssertLessThanOrEqual(x.count, 202, "CC 74: \(x.count) in about a second")
		XCTAssertLessThanOrEqual(y.count, 202)
		XCTAssertGreaterThan(x.count, 100, "not starved either")
		XCTAssertTrue(x.allSatisfy { $0.count == 3 && $0[1] == 74 && $0[2] <= 127 })
		XCTAssertTrue(y.allSatisfy { $0.count == 3 && $0[1] <= 127 && $0[2] <= 127 })
		XCTAssertEqual(x.last, [0xB0, 74, 64])
		XCTAssertEqual(y.last, [0xE0, 0, 0], "bend fully down: 0")
		h.endControl(.y, .pitchBend)
		t.advance(0.01)
		XCTAssertEqual(s.msgs.last, [0xE0, 0, 64], "bend back to the centre")
	}

	func testMessagesAtTheEdges() {
		XCTAssertEqual(Hands.message(.pitchBend, 1, channel: 2), [0xE2, 0x7F, 0x7F])
		XCTAssertEqual(Hands.message(.pitchBend, 0, channel: 0), [0xE0, 0, 64])
		XCTAssertEqual(Hands.message(.cc(1), 7, channel: 0), [0xB0, 1, 127])
		XCTAssertEqual(Hands.message(.aftertouch, -3, channel: 15), [0xDF, 0])
		XCTAssertEqual(Hands.message(.cc(74), .nan, channel: 0), [0xB0, 74, 0])
	}

	func testTiltIsRelativeToZeroSmoothedAndClamped() {
		var m = TiltMapper(rangeDegrees: 45, smoothing: 0)
		m.setZero(0.5)
		XCTAssertEqual(m.value(0.5), 0, accuracy: 1e-9)
		XCTAssertEqual(m.value(0.5 + .pi / 8), 0.5, accuracy: 1e-9)
		XCTAssertEqual(m.value(3), 1)
		XCTAssertEqual(m.value(-1.5), -1)
		var s = TiltMapper(rangeDegrees: 45, smoothing: 0.5)
		s.setZero(0)
		_ = s.value(0)
		let v = s.value(.pi / 4)                                  // a jump to full: half way there at once
		XCTAssertEqual(v, 0.5, accuracy: 1e-9)
	}

	func testScaleSnap() {
		XCTAssertEqual(Scale.major.snap(61, root: 0), 60)
		XCTAssertEqual(Scale.minor.snap(64, root: 0), 63)
		XCTAssertTrue(Scale.pentatonic.contains(67, root: 0))
		XCTAssertEqual(Scale.chromatic.snap(61, root: 0), 61)
	}

	func testSettingsPersist() {
		let d = UserDefaults(suiteName: "hands-\(UUID().uuidString)")!
		var s = HandsSettings()
		s.channel = 5; s.x = .pitchBend; s.tilt = .cc(11); s.scaleLock = true; s.scale = .dorian; s.latch = true
		s.save(d)
		XCTAssertEqual(HandsSettings.load(d), s)
		XCTAssertEqual(HandsSettings.load(UserDefaults(suiteName: "empty-\(UUID().uuidString)")!), HandsSettings())
	}
}

/// Hands over CoreMIDI to a virtual destination (a FakeFM1; the engine sees nothing else).
@MainActor
final class HandsVirtualEndpointTests: XCTestCase {
	func testNoStuckNotesOverCoreMIDI() async throws {
		let fake = try FakeFM1()
		let engine = try MIDIEngine(clientName: "hands test", filter: fake.filter)
		let end = Date().addingTimeInterval(5)
		while engine.endpoints.count < 2 && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
		let out = try XCTUnwrap(engine.endpoints.first { $0.kind == .output }?.id)
		let h = Hands(send: { m in try? engine.send(m, to: out) })
		var rng = SystemRandomNumberGenerator()
		for round in 0..<200 {
			let id = Int.random(in: 0..<5, using: &rng)
			switch Int.random(in: 0..<6, using: &rng) {
			case 0, 1: h.touchDown(id, note: Int.random(in: 48..<84, using: &rng), velocity: 100)
			case 2: h.touchMoved(id, note: Int.random(in: 48..<84, using: &rng), velocity: 90)
			case 3: h.touchUp(id)
			case 4: h.touchCancelled(id)
			default: h.latch = round % 2 == 0
			}
			h.control(.x, .cc(74), Double.random(in: 0...1, using: &rng))
		}
		h.releaseAll()                                            // the app going to the background
		try await Task.sleep(nanoseconds: 300_000_000)
		let got = fake.received
		XCTAssertGreaterThan(got.filter { $0.first == 0x90 }.count, 10)
		XCTAssertEqual(stuckNotes(got), [], "every note on has its note off at the device")
		XCTAssertTrue(got.filter { $0.first == 0xB0 }.allSatisfy { $0[1] == 74 && $0[2] <= 127 })
	}
}
