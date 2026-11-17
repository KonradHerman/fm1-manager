// SPDX-License-Identifier: GPL-3.0-only

/// Turns a MIDI 1.0 byte stream, however it was cut into packets, into complete messages, one per Web MIDI
/// `midimessage` event, as Chrome's MidiMessageQueue does:
/// - a SysEx is one message, F0 through F7, however many packets it came in;
/// - a real-time byte (F8...FF) is a message of its own at once, even in the middle of a SysEx or a channel message,
///   and changes nothing else;
/// - running status is expanded: every channel message comes out with its status byte;
/// - several messages in one packet come out one by one;
/// - a SysEx cut off by another status byte is dropped, as are data bytes with no status and the undefined F4/F5.
/// One parser per source: the state carries over from one packet to the next.
public struct MIDIStreamParser: Sendable {
	/// The longest SysEx kept; a longer one is dropped (a stream that never sends F7 cannot grow without end).
	public var maxSysExLength = 1 << 20

	private var runningStatus: UInt8 = 0
	private var message: [UInt8] = []
	private var expected = 0
	private var sysex: [UInt8]?
	private var sysexOverflow = false

	public init() {}

	/// True while a SysEx has started and not yet ended.
	public var inSysEx: Bool { sysex != nil }

	public mutating func reset() { self = MIDIStreamParser() }

	/// The data bytes after a status byte; nil for a status that has no message (F0, F7, F4, F5).
	public static func dataLength(_ status: UInt8) -> Int? {
		switch status {
		case 0x80...0xBF, 0xE0...0xEF: return 2
		case 0xC0...0xDF: return 1
		case 0xF1, 0xF3: return 1
		case 0xF2: return 2
		case 0xF6, 0xF8...0xFF: return 0
		default: return nil
		}
	}

	public mutating func feed<S: Sequence>(_ bytes: S) -> [[UInt8]] where S.Element == UInt8 {
		var out: [[UInt8]] = []
		for b in bytes { feed(byte: b, into: &out) }
		return out
	}

	private mutating func feed(byte b: UInt8, into out: inout [[UInt8]]) {
		if b >= 0xF8 { out.append([b]); return }                 // real time: at once, nothing else changes
		if b == 0xF0 {
			sysex = [0xF0]; sysexOverflow = false
			runningStatus = 0; message.removeAll(keepingCapacity: true)
			return
		}
		if b == 0xF7 {
			if var s = sysex {
				s.append(0xF7)
				if !sysexOverflow { out.append(s) }
				sysex = nil
			}
			return                                               // (an F7 with no F0: dropped)
		}
		if b & 0x80 != 0 {                                       // another status: a SysEx under way is cut off
			sysex = nil
			message.removeAll(keepingCapacity: true)
			guard let n = Self.dataLength(b) else { runningStatus = 0; return }   // F4, F5
			runningStatus = b < 0xF0 ? b : 0                      // (system common clears running status)
			if n == 0 { out.append([b]); return }                // F6
			message.append(b); expected = n
			return
		}
		// a data byte
		if sysex != nil {
			if sysex!.count >= maxSysExLength { sysexOverflow = true } else { sysex!.append(b) }
			return
		}
		if message.isEmpty {
			guard runningStatus != 0, let n = Self.dataLength(runningStatus) else { return }   // no status: dropped
			message.append(runningStatus); expected = n
		}
		message.append(b)
		if message.count == expected + 1 {
			out.append(message)
			message.removeAll(keepingCapacity: true)
		}
	}

	/// Splits bytes a page sends into messages and says whether they were whole: what is left at the end (a SysEx
	/// without its F7, a note without its velocity) is not.
	public static func split(_ bytes: [UInt8]) -> (messages: [[UInt8]], complete: Bool) {
		var p = MIDIStreamParser()
		let msgs = p.feed(bytes)
		return (msgs, !p.inSysEx && p.message.isEmpty && msgs.reduce(0) { $0 + $1.count } == bytes.count)
	}
}
