// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// .dock files made up for tests: a valid header (fm1-dock's hb_file_t, its CRC right), no relocations, an image of
/// the size asked. `kib`: what it takes in the deploy area (the file is exactly that long).
public enum SyntheticDock {
	public static func make(name: String, version: UInt32 = 1, kib: Int, abi: UInt32 = 2, flags: UInt32 = 0, seed: UInt8 = 0) -> Data {
		make(name: name, version: version, imageBytes: kib * 1024 - 256, abi: abi, flags: flags, seed: seed)
	}

	public static func make(name: String, version: UInt32 = 1, imageBytes n: Int, abi: UInt32 = 2, flags: UInt32 = 0, seed: UInt8 = 0) -> Data {
		var h = [UInt8](repeating: 0, count: 80)
		func put(_ v: UInt32, _ o: Int) { for k in 0..<4 { h[o + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) } }
		put(0x5242_5248, 0); put(abi, 4); put(flags, 8)
		for (i, c) in name.utf8.prefix(23).enumerated() { h[12 + i] = c }
		put(version, 36)
		let code = UInt32(n * 3 / 4), data = UInt32(n) - code
		put(code, 40); put(data, 44); put(0, 48); put(0, 52)
		put(0, 60); put(0x0200_0100, 64); put(0, 68); put(0, 72)
		let image = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }
		put(FM1Protocol.crc32(h[0..<76] + image), 76)
		return Data(h + [UInt8](repeating: 0xFF, count: 256 - 80) + image)
	}
}
