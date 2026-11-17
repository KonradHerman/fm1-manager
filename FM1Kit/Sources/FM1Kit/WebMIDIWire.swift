// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What webmidi.js posts to the app, as WebKit hands it over (NSDictionary / NSArray / NSNumber).
public enum WebMIDIWire {
	/// A `send`: { op: "send", id, data: [byte, ...], delay: ms } -> the output's id, the bytes, the delay in seconds.
	public static func send(from body: Any) -> (id: String, bytes: [UInt8], delay: TimeInterval)? {
		guard let body = body as? [String: Any], body["op"] as? String == "send", let id = body["id"] as? String,
		      let raw = body["data"] as? [Any] else { return nil }
		var bytes: [UInt8] = []
		bytes.reserveCapacity(raw.count)
		for x in raw {
			guard let n = x as? NSNumber, n.intValue >= 0, n.intValue <= 255 else { return nil }
			bytes.append(UInt8(n.intValue))
		}
		return (id, bytes, ((body["delay"] as? NSNumber)?.doubleValue ?? 0) / 1000)
	}
}

extension URL {
	/// The file's size in bytes (0 when it cannot be read).
	public var fileSize: Int { (try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
}
