// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What a continuous control sends.
public enum ControlTarget: Codable, Hashable, Sendable {
	case cc(UInt8)
	case pitchBend
	case aftertouch

	public var label: String {
		switch self {
		case let .cc(n):
			switch n {
			case 1: "Mod wheel (CC 1)"
			case 74: "CC 74 (KNOB1)"
			case 71: "CC 71 (KNOB2)"
			case 73: "CC 73 (KNOB3)"
			case 72: "CC 72 (KNOB4)"
			default: "CC \(n)"
			}
		case .pitchBend: "Pitch bend"
		case .aftertouch: "Channel aftertouch"
		}
	}
	/// The choices the settings offer: fm1-dock's knob CCs (dock.c KNOB_CC: 74, 71, 73, 72), the mod wheel, bend,
	/// aftertouch, and a few common CCs.
	public static let choices: [ControlTarget] = [.cc(74), .cc(71), .cc(73), .cc(72), .cc(1), .pitchBend, .aftertouch,
	                                              .cc(7), .cc(10), .cc(11), .cc(64)]
}

public enum Scale: String, Codable, CaseIterable, Sendable {
	case chromatic, major, minor, dorian, pentatonic, minorPentatonic, blues
	public var steps: [Int] {
		switch self {
		case .chromatic: Array(0..<12)
		case .major: [0, 2, 4, 5, 7, 9, 11]
		case .minor: [0, 2, 3, 5, 7, 8, 10]
		case .dorian: [0, 2, 3, 5, 7, 9, 10]
		case .pentatonic: [0, 2, 4, 7, 9]
		case .minorPentatonic: [0, 3, 5, 7, 10]
		case .blues: [0, 3, 5, 6, 7, 10]
		}
	}
	public var label: String {
		switch self {
		case .chromatic: "Chromatic"
		case .major: "Major"
		case .minor: "Minor"
		case .dorian: "Dorian"
		case .pentatonic: "Major pentatonic"
		case .minorPentatonic: "Minor pentatonic"
		case .blues: "Blues"
		}
	}
	public func contains(_ note: Int, root: Int) -> Bool { steps.contains(((note - root) % 12 + 12) % 12) }
	/// The note itself if it is in the scale, else the nearest one below.
	public func snap(_ note: Int, root: Int) -> Int {
		var n = note
		while !contains(n, root: root) && n > 0 { n -= 1 }
		return n
	}
}

/// Hands' settings, kept between launches (UserDefaults, JSON).
public struct HandsSettings: Codable, Hashable, Sendable {
	public var channel = 0                      // 0...15
	public var x: ControlTarget = .cc(74)
	public var y: ControlTarget = .cc(71)
	public var tilt: ControlTarget = .cc(1)
	public var tiltRangeDegrees = 40.0
	public var tiltSmoothing = 0.25             // 0: none ... 0.9: heavy
	public var lowestNote = 48                  // C3: the keyboard's first key
	public var octaves = 2
	public var scaleLock = false
	public var scale: Scale = .major
	public var root = 0                         // C
	public var latch = false
	public var haptics = true
	public var xyReturns = false                // the pad springs back to its centre on release

	public init() {}

	public static let key = "hands.settings"
	public static func load(_ d: UserDefaults = .standard) -> HandsSettings {
		guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(HandsSettings.self, from: data) else { return HandsSettings() }
		return s
	}
	public func save(_ d: UserDefaults = .standard) {
		if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
	}
}

/// The performance screen's MIDI, without the screen: notes by touch (with slides, latch, cancel), continuous
/// controls rate-limited, and the guarantees that no note is left on. Thread-safe: touches come on the main thread,
/// tilt on a motion queue; each sends straight to `send` (CoreMIDI), in order, with no hop in between.
public final class Hands: @unchecked Sendable {
	public enum Slot: Int, CaseIterable, Sendable { case x, y, tilt }

	/// At most this many messages a second per control; the last value always goes out.
	public static let maxRate = 200.0

	private let send: @Sendable ([UInt8]) -> Void
	private let now: @Sendable () -> TimeInterval
	private let after: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
	private let lock = NSLock()

	private var channel: UInt8 = 0
	private var touches: [Int: UInt8] = [:]      // touch -> the note it holds (none: a touch that released a latched note)
	private var sounding: [UInt8: Int] = [:]     // note -> how many touches hold it
	private var latched: Set<UInt8> = []
	private var latchOn = false
	private var lastSent: [Slot: [UInt8]] = [:]
	private var lastTime: [Slot: TimeInterval] = [:]
	private var pending: [Slot: [UInt8]] = [:]
	private var flushArmed: Set<Slot> = []

	/// - Parameters:
	///   - now: seconds, monotonic (tests pass their own clock)
	///   - after: runs a closure after a delay (tests run it by hand)
	public init(send: @escaping @Sendable ([UInt8]) -> Void,
	            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
	            after: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { d, f in
	            	DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + d, execute: f) }) {
		self.send = send; self.now = now; self.after = after
	}

	private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

	/// The channel (0...15). Notes sounding on the old one are let go first.
	public func setChannel(_ c: Int) {
		let c = UInt8(max(0, min(15, c)))
		if c != locked({ channel }) { releaseAll() }
		locked { channel = c }
	}

	public var latch: Bool {
		get { locked { latchOn } }
		set {
			locked { latchOn = newValue }
			if !newValue { releaseLatched() }
		}
	}

	/// Notes that sound now (held or latched).
	public var soundingNotes: Set<UInt8> { locked { Set(sounding.keys).union(latched) } }

	// MARK: notes

	public func touchDown(_ id: Int, note: Int, velocity: Int) {
		let n = UInt8(max(0, min(127, note))), v = UInt8(max(1, min(127, velocity)))
		locked {
			if latchOn && latched.contains(n) && sounding[n] == nil {   // a latched note touched again: it stops
				latched.remove(n)
				send([0x80 | channel, n, 0])
				touches[id] = nil
				return
			}
			touches[id] = n
			if sounding[n, default: 0] == 0 && !latched.contains(n) { send([0x90 | channel, n, v]) }
			sounding[n, default: 0] += 1
		}
	}

	/// The finger slid onto another key: the old note stops, the new one starts.
	public func touchMoved(_ id: Int, note: Int, velocity: Int) {
		let n = UInt8(max(0, min(127, note)))
		let held = locked { touches[id] }
		guard let held, held != n else { return }
		release(id, latching: false)                              // (a slide never leaves notes latched behind it)
		touchDown(id, note: Int(n), velocity: velocity)
	}

	public func touchUp(_ id: Int) { release(id, latching: true) }

	private func release(_ id: Int, latching: Bool) {
		locked {
			guard let n = touches.removeValue(forKey: id) else { return }
			let left = sounding[n, default: 1] - 1
			if left > 0 { sounding[n] = left; return }
			sounding[n] = nil
			if latchOn && latching { latched.insert(n) } else { send([0x80 | channel, n, 0]) }
		}
	}

	/// The system took the touch (a call, a gesture): its note stops even when latch is on.
	public func touchCancelled(_ id: Int) {
		locked {
			guard let n = touches.removeValue(forKey: id) else { return }
			let left = sounding[n, default: 1] - 1
			if left > 0 { sounding[n] = left; return }
			sounding[n] = nil
			latched.remove(n)
			send([0x80 | channel, n, 0])
		}
	}

	private func releaseLatched() {
		locked {
			for n in latched.sorted() where sounding[n] == nil { send([0x80 | channel, n, 0]) }
			latched.removeAll()
		}
	}

	/// Every note this screen started stops (leaving the screen, the app going to the background).
	public func releaseAll() {
		locked {
			for n in Set(sounding.keys).union(latched).sorted() { send([0x80 | channel, n, 0]) }
			sounding.removeAll(); latched.removeAll(); touches.removeAll()
		}
	}

	/// The FM-1 went away: nothing can be sent to it; what this screen held is forgotten.
	public func forget() {
		locked { sounding.removeAll(); latched.removeAll(); touches.removeAll(); pending.removeAll(); lastSent.removeAll() }
	}

	/// Panic: every note off (CC 123, CC 120 and a note off for each this screen started), bend centred.
	public func panic() {
		releaseAll()
		locked {
			send([0xB0 | channel, 123, 0])
			send([0xB0 | channel, 120, 0])
			send([0xE0 | channel, 0, 64])
			lastSent[.x] = nil; lastSent[.y] = nil; lastSent[.tilt] = nil
		}
	}

	// MARK: continuous controls

	/// The message for a value: for bend, -1...1 (0 the centre); otherwise 0...1.
	public static func message(_ t: ControlTarget, _ value: Double, channel: UInt8) -> [UInt8] {
		let v = value.isFinite ? value : 0
		switch t {
		case let .cc(n):
			return [0xB0 | channel, n & 0x7F, UInt8((max(0, min(1, v)) * 127).rounded())]
		case .aftertouch:
			return [0xD0 | channel, UInt8((max(0, min(1, v)) * 127).rounded())]
		case .pitchBend:
			let x = max(-1, min(1, v))
			let b = 8192 + Int((x < 0 ? x * 8192 : x * 8191).rounded())    // (0: all the way down, 16383 up)
			let c = max(0, min(16383, b))
			return [0xE0 | channel, UInt8(c & 0x7F), UInt8(c >> 7)]
		}
	}

	/// A control's new value: sent at once, or (faster than maxRate) held and sent when its turn comes.
	public func control(_ slot: Slot, _ target: ControlTarget, _ value: Double) {
		locked {
			let m = Self.message(target, value, channel: channel)
			if lastSent[slot] == m && pending[slot] == nil { return }
			let t = now(), wait = (lastTime[slot] ?? -1) + 1 / Self.maxRate - t
			if wait <= 0 && !flushArmed.contains(slot) {
				send(m); lastSent[slot] = m; lastTime[slot] = t
				return
			}
			pending[slot] = m
			if !flushArmed.contains(slot) {
				flushArmed.insert(slot)
				after(max(0, wait)) { [weak self] in self?.flush(slot) }
			}
		}
	}

	private func flush(_ slot: Slot) {
		locked {
			flushArmed.remove(slot)
			guard let m = pending.removeValue(forKey: slot) else { return }
			if lastSent[slot] != m { send(m); lastSent[slot] = m; lastTime[slot] = now() }
		}
	}

	/// The control let go: bend back to the centre, aftertouch to 0; a CC stays where it is.
	public func endControl(_ slot: Slot, _ target: ControlTarget) {
		switch target {
		case .pitchBend: control(slot, target, 0)
		case .aftertouch: control(slot, target, 0)
		case .cc: break
		}
	}
}

/// Tilt to a control value: the angle from the attitude taken as zero, over a range, smoothed.
public struct TiltMapper: Sendable {
	public var rangeDegrees: Double
	public var smoothing: Double                // 0 none ... <1 heavy
	public private(set) var zero: Double = 0
	private var y: Double?

	public init(rangeDegrees: Double = 40, smoothing: Double = 0.25) { self.rangeDegrees = rangeDegrees; self.smoothing = smoothing }

	/// The angle now (radians) becomes the centre.
	public mutating func setZero(_ angle: Double) { zero = angle; y = nil }

	/// -1...1 for this angle (radians); for a CC or aftertouch, take max(0, value).
	public mutating func value(_ angle: Double) -> Double {
		var d = angle - zero
		while d > .pi { d -= 2 * .pi }
		while d < -.pi { d += 2 * .pi }
		let x = max(-1, min(1, d / (rangeDegrees * .pi / 180)))
		let a = 1 - max(0, min(0.95, smoothing))
		let out = y.map { $0 + a * (x - $0) } ?? x
		y = out
		return out
	}
}
