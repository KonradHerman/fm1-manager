// SPDX-License-Identifier: GPL-3.0-only

/// Universal MIDI Packets (MIDI 1.0 protocol, group 0) to and from MIDI 1.0 bytes: what the protocol-aware CoreMIDI
/// API (MIDIEventList) carries. SysEx travels as SysEx7 packets of up to six data bytes each, without F0 and F7: the
/// decoder puts them back, so its output goes through the same MIDIStreamParser as the bytes of a MIDIPacketList.
public enum UMP {
	/// The words in a packet of this message type (the top 4 bits of its first word).
	public static func packetWords(messageType mt: UInt32) -> Int {
		switch mt {
		case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
		case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
		case 0xB, 0xC: return 3
		default: return 4
		}
	}

	/// MIDI 1.0 bytes for a run of UMP words. A SysEx split over several SysEx7 packets comes out as F0, its data
	/// and F7 with any real-time message that came between its packets in place (the parser lifts that out).
	/// MIDI 2.0 channel voice packets, utility and data packets are skipped.
	public static func midi1Bytes<C: Collection>(fromWords words: C) -> [UInt8] where C.Element == UInt32 {
		var out: [UInt8] = []
		var i = words.startIndex
		while i != words.endIndex {
			let w0 = words[i]
			let mt = w0 >> 28
			let n = packetWords(messageType: mt)
			var packet: [UInt32] = []
			var j = i
			for _ in 0..<n {
				guard j != words.endIndex else { break }
				packet.append(words[j]); j = words.index(after: j)
			}
			i = j
			guard packet.count == n else { break }                 // a packet cut short: nothing more to read
			let status = UInt8((w0 >> 16) & 0xFF), d1 = UInt8((w0 >> 8) & 0x7F), d2 = UInt8(w0 & 0x7F)
			switch mt {
			case 0x1:                                              // system common and real time
				switch status {
				case 0xF1, 0xF3: out += [status, d1]
				case 0xF2: out += [status, d1, d2]
				case 0xF6, 0xF8...0xFF: out.append(status)
				default: break
				}
			case 0x2:                                              // MIDI 1.0 channel voice
				guard status >= 0x80, status < 0xF0 else { break }
				out += (status & 0xE0) == 0xC0 ? [status, d1] : [status, d1, d2]
			case 0x3:                                              // SysEx7
				let kind = (w0 >> 20) & 0xF, count = min(6, Int((w0 >> 16) & 0xF))
				let w1 = packet[1]
				let data: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
				                     UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
				let body = data.prefix(count).map { $0 & 0x7F }
				switch kind {
				case 0: out.append(0xF0); out += body; out.append(0xF7)   // complete in one packet
				case 1: out.append(0xF0); out += body                     // start
				case 2: out += body                                       // continue
				case 3: out += body; out.append(0xF7)                     // end
				default: break
				}
			default: break
			}
		}
		return out
	}

	/// The UMP packets (each one or two words) for one complete MIDI 1.0 message; empty for what is not one.
	public static func packets(forMessage m: [UInt8]) -> [[UInt32]] {
		guard let status = m.first else { return [] }
		if status == 0xF0 {
			guard m.count >= 2, m.last == 0xF7 else { return [] }
			let body = Array(m[1..<(m.count - 1)])
			var chunks: [ArraySlice<UInt8>] = stride(from: 0, to: body.count, by: 6).map { body[$0..<min($0 + 6, body.count)] }
			if chunks.isEmpty { chunks = [[]] }
			return chunks.enumerated().map { k, chunk in
				let kind: UInt32 = chunks.count == 1 ? 0 : k == 0 ? 1 : k == chunks.count - 1 ? 3 : 2
				var d = [UInt8](repeating: 0, count: 6)
				for (x, b) in chunk.enumerated() { d[x] = b & 0x7F }
				let w0 = 0x3000_0000 | kind << 20 | UInt32(chunk.count) << 16 | UInt32(d[0]) << 8 | UInt32(d[1])
				let w1 = UInt32(d[2]) << 24 | UInt32(d[3]) << 16 | UInt32(d[4]) << 8 | UInt32(d[5])
				return [w0, w1]
			}
		}
		let d1 = m.count > 1 ? UInt32(m[1] & 0x7F) : 0, d2 = m.count > 2 ? UInt32(m[2] & 0x7F) : 0
		if status >= 0x80 && status < 0xF0 { return [[0x2000_0000 | UInt32(status) << 16 | d1 << 8 | d2]] }
		if status > 0xF0 && status != 0xF7 { return [[0x1000_0000 | UInt32(status) << 16 | d1 << 8 | d2]] }
		return []
	}
}
