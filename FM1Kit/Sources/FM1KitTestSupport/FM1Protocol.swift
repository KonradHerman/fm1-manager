// SPDX-License-Identifier: GPL-3.0-only
// fm1-dock's SysEx framing and the FM-1 updater's, after vendor/fm1-dock/docs/dock.js, install/fm1ota.js and
// tools/hbdeploy.py: for the simulated device's side.

public enum FM1Protocol {
	public static let handshakeQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7]
	public static let upgrade: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7]
	public static let dockManufacturer: [UInt8] = [0x7D, 0x48, 0x42]

	public enum Cmd: UInt8 {
		case hello = 0x01, list = 0x02, info = 0x03, begin = 0x10, data = 0x11, commit = 0x12, abort = 0x13, delete = 0x14
		case log = 0x20, safe = 0x21, select = 0x22, module = 0x23
	}

	public static func pack7(_ data: [UInt8]) -> [UInt8] {
		var out: [UInt8] = [], acc: UInt32 = 0, nb = 0
		for b in data {
			acc |= UInt32(b) << nb; nb += 8
			while nb >= 7 { out.append(UInt8(acc & 0x7F)); acc >>= 7; nb -= 7 }
		}
		if nb > 0 { out.append(UInt8(acc & 0x7F)) }
		return out
	}

	public static func unpack7<S: Sequence>(_ s: S) -> [UInt8] where S.Element == UInt8 {
		var out: [UInt8] = [], acc: UInt32 = 0, nb = 0
		for b in s {
			acc |= UInt32(b & 0x7F) << nb; nb += 7
			if nb >= 8 { out.append(UInt8(acc & 0xFF)); acc >>= 8; nb -= 8 }
		}
		return out
	}

	private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
		var c = UInt32(n)
		for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
		return c
	}

	public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
		var c: UInt32 = 0xFFFF_FFFF
		for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
		return c ^ 0xFFFF_FFFF
	}

	public static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
	public static func rd32(_ d: [UInt8], _ o: Int) -> UInt32 {
		guard o + 4 <= d.count else { return 0 }
		return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
	}

	/// F0 7D 48 42 cmd seq pack7(payload + CRC-32 LE) F7
	public static func frame(cmd: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
		[0xF0] + dockManufacturer + [cmd, seq & 0x7F] + pack7(payload + le32(crc32(payload))) + [0xF7]
	}

	/// A dock frame: (cmd without the reply bit, seq, payload), or nil if not one / damaged.
	public static func parse(_ msg: [UInt8]) -> (cmd: UInt8, seq: UInt8, payload: [UInt8])? {
		guard msg.count >= 7, msg.first == 0xF0, msg.last == 0xF7, Array(msg[1...3]) == dockManufacturer else { return nil }
		let d = unpack7(msg[6..<(msg.count - 1)])
		guard d.count >= 4 else { return nil }
		let body = Array(d[0..<(d.count - 4)])
		guard crc32(body) == rd32(d, d.count - 4) else { return nil }
		return (msg[4] & ~0x40, msg[5], body)
	}

	public static func name24(_ s: String) -> [UInt8] {
		var b = [UInt8](repeating: 0, count: 24)
		for (i, c) in s.utf8.prefix(23).enumerated() { b[i] = c }
		return b
	}

	public static func cstr<S: Sequence>(_ d: S) -> String where S.Element == UInt8 {
		String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
	}
}
