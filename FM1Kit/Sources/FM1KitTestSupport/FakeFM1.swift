// SPDX-License-Identifier: GPL-3.0-only
import CoreMIDI
import FM1Kit
import Foundation

/// A simulated FM-1 on a virtual CoreMIDI source and destination of its own, named "FM-1 Test <token>" (an FM-1's
/// name to the pages, unique to this run). It answers as vendor/fm1-dock/docs/demo.js's Device does: the updater's
/// handshake and reads (install/fm1ota.js), and fm1-dock's HELLO / LIST / LOG / BEGIN / DATA / COMMIT / DELETE.
///
/// Safety: give the code under test `filter` as its MIDIEngine filter. It admits only endpoints whose name carries
/// this fake's token, so nothing is ever listed, opened or sent to a real device plugged into the machine.
public final class FakeFM1: @unchecked Sendable {
	public enum EndpointAPI: Sendable { case universal, legacy }

	public let token: String
	public let sourceAPI: EndpointAPI
	public let destinationAPI: EndpointAPI
	/// What the device writes to the page is cut into packets of this many bytes (0: one packet per message).
	public var chunkSize: Int { get { locked { _chunkSize } } set { locked { _chunkSize = newValue } } }
	/// The loader's identity number after the running firmware stages it ("900": ota-FM-1_900, Felucca's and
	/// fm1-dock's; another firmware's own copy has its own, as Skiff 2.7's ota-FM-1_727).
	public var loaderVersion: String { get { locked { _loaderVersion } } set { locked { _loaderVersion = newValue } } }
	/// The loader fails this many requests into its write pass: its USB goes away (as a loader that restarts after a
	/// flash error does) and comes back after `dropFor` seconds as the same loader, waiting for UPDATE again. Once.
	public var dropLoaderAfter: Int? { get { locked { _dropLoaderAfter } } set { locked { _dropLoaderAfter = newValue } } }
	public var dropFor: TimeInterval = 1.5
	/// The flash chip INFO reports (fm1-dock 0.8 on): 0xB36014 the newer chip, 0x856014 the older.
	public var flashJEDEC: UInt32 = 0xB3_6014
	private var _loaderVersion = "900"
	private var _dropLoaderAfter: Int?
	private var writeServed = 0

	private var client = MIDIClientRef()
	private var source = MIDIEndpointRef()
	private var destination = MIDIEndpointRef()
	private let queue = DispatchQueue(label: "FakeFM1")
	private let lock = NSLock()
	private var parser = MIDIStreamParser()

	// device state (on queue)
	private var _chunkSize = 0
	private var _received: [[UInt8]] = []
	private var _portName = ""
	private var identity: String
	private var dockVersion: String?
	private let imageLength: Int
	private let product: String
	/// The deployed table in its order (dock.c dt.s): each module's flash offset and the bytes it writes (`total`).
	private var deployed: [Placed] = []
	/// An open receive (BEGIN ... COMMIT): kept across an unplug, as the device's RAM keeps it while powered.
	private var receiving: (size: Int, crc: UInt32, name: String, got: [UInt8], chunks: Set<Int>)?
	private var curName = "SINE"
	private var _commands: [String] = []
	private var logText = ""
	private var queueOTA: [(addr: UInt32, len: Int)] = []
	private var waiting: (addr: UInt32, len: Int)?
	private var _written: [UInt8]
	private var _events: [String] = []
	private let started = Date()

	/// - Parameters:
	///   - identity: what the handshake answers ("FM-1_921"; "ota-FM-1_900" in update mode)
	///   - dockVersion: the fm1-dock it runs (nil: a firmware without fm1-dock, it answers no HELLO)
	///   - imageLength: the update image an install would read (a package's length less 20)
	///   - product: what it runs after an update
	public init(identity: String = "FM-1_921", dockVersion: String? = "0.7", imageLength: Int = 0x2400,
	            product: String = "FM-1_921", sourceAPI: EndpointAPI = .legacy, destinationAPI: EndpointAPI = .universal,
	            token: String = String(UUID().uuidString.prefix(8)), name: String? = nil) throws {
		customName = name
		self.identity = identity; self.dockVersion = dockVersion; self.imageLength = imageLength; self.product = product
		self.sourceAPI = sourceAPI; self.destinationAPI = destinationAPI; self.token = token
		_written = [UInt8](repeating: 0, count: imageLength)
		// (CoreMIDI's server can be briefly unavailable between test suites, above all on CI runners, where
		// MIDIClientCreate has failed with -2 and -304: a few tries before giving up)
		var st = MIDIClientCreateWithBlock("FakeFM1 \(token)" as CFString, &client, nil)
		var tries = 0
		while st != noErr && tries < 10 {
			Thread.sleep(forTimeInterval: 0.5)
			tries += 1
			st = MIDIClientCreateWithBlock("FakeFM1 \(token)" as CFString, &client, nil)
		}
		guard st == noErr else { throw MIDIEngineError.coreMIDI("MIDIClientCreate", st) }
		try plugIn(name: self.name(for: identity))
		bootLog()
	}

	deinit {
		unplug()
		MIDIClientDispose(client)
	}

	public static func portName(identity: String, token: String) -> String {
		identity.hasPrefix("ota-") ? "FM-1 Update Test \(token)" : "FM-1 Test \(token)"
	}

	/// The filter for the MIDIEngine under test: this fake's endpoints and nothing else.
	/// A port name of the caller's choosing (a demo's "FM-1"); nil: "FM-1 Test <token>". With one, use idFilter.
	private let customName: String?
	private var _ids: Set<String> = []

	private func name(for identity: String) -> String {
		guard let n = customName else { return Self.portName(identity: identity, token: token) }
		return identity.hasPrefix("ota-") ? "\(n) Update" : n
	}

	/// This fake's endpoints by their CoreMIDI unique ids (as they are now): for a port name a real device may share.
	public var idFilter: MIDIEngine.Filter {
		{ [weak self] e in self?.locked { self?._ids.contains(e.id) ?? false } ?? false }
	}

	public var filter: MIDIEngine.Filter {
		let t = token
		return { $0.name.hasSuffix(" Test \(t)") }
	}

	public var portName: String { locked { _portName } }
	/// Every complete message the device got, in order.
	public var received: [[UInt8]] { locked { _received } }
	/// The update image as the loader read it (the bytes the host served, at their addresses).
	public var written: [UInt8] { locked { _written } }
	public var deployedModules: [(name: String, blob: [UInt8])] { locked { deployed.map { ($0.name, $0.blob) } } }
	/// The deploy area as the device has it: each module's flash offset and footprint (whole sectors), table order.
	public var layout: [(name: String, at: Int, footprint: Int)] { locked { deployed.map { ($0.name, $0.at, Self.sectors($0.total)) } } }
	/// The module playing.
	public var current: String { locked { curName } }
	/// What changed the device, in order: "BEGIN X", "COMMIT X", "DELETE X", "SELECT X", "ABORT".
	public var commands: [String] { locked { _commands } }
	public var isReceiving: Bool { locked { receiving != nil } }

	struct Placed { var name: String; var blob: [UInt8]; var at: Int; var total: Int; var version: UInt32; var listSize: UInt32 }

	/// Puts a module straight into flash at a flash offset (inside the deploy area, sector aligned), as an earlier
	/// session would have left it: for laying out a fragmented area.
	public func preload(_ blob: Data, at offset: Int) {
		let b = [UInt8](blob)
		guard let h = Self.header(b) else { preconditionFailure("not a module") }
		precondition(offset % 4096 == 0 && Self.deployArea.contains(offset))
		locked { deployed.append(Placed(name: h.name, blob: b, at: offset, total: h.total, version: h.version, listSize: h.listSize)) }
	}

	/// The cable back in: the same identity's ports again, the flash as it was.
	public func replug() throws {
		guard source == 0 else { return }
		try plugIn(name: self.name(for: identity))
	}
	/// What happened, for a test's failure message.
	public var events: [String] { locked { _events } }

	private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
	private func note(_ s: String) { locked { _events.append(String(format: "%.2f ", Date().timeIntervalSince(started)) + s) } }

	// MARK: endpoints

	private func plugIn(name: String) throws {
		var st: OSStatus
		switch sourceAPI {
		case .legacy: st = MIDISourceCreate(client, name as CFString, &source)
		case .universal: st = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
		}
		guard st == noErr else { throw MIDIEngineError.coreMIDI("MIDISourceCreate", st) }
		switch destinationAPI {
		case .universal:
			st = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { [weak self] list, _ in
				var bytes: [UInt8] = []
				for p in list.unsafeSequence() {
					let n = Int(p.pointee.wordCount)   // (variable length: a packet may hold more than its 64-word tuple)
					let base = UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
					bytes += UMP.midi1Bytes(fromWords: UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt32.self), count: n))
				}
				self?.got(bytes)
			}
		case .legacy:
			st = MIDIDestinationCreateWithBlock(client, name as CFString, &destination) { [weak self] list, _ in
				var bytes: [UInt8] = []
				for p in list.unsafeSequence() {
					let base = UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!)
					bytes += UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: Int(p.pointee.length))
				}
				self?.got(bytes)
			}
		}
		guard st == noErr else { throw MIDIEngineError.coreMIDI("MIDIDestinationCreate", st) }
		var a: MIDIUniqueID = 0, b: MIDIUniqueID = 0
		MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &a)
		MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &b)
		locked { _portName = name; _ids = [String(a), String(b)] }
		note("plugged in as \(name)")
	}

	/// The cable pulled: its endpoints go away.
	public func unplug() {
		if source != 0 { MIDIEndpointDispose(source); source = 0 }
		if destination != 0 { MIDIEndpointDispose(destination); destination = 0 }
	}

	/// The device restarts as `identity` (its ports go away, and come back under the name that identity shows).
	private func reboot(as newIdentity: String, dock: String?) {
		note("reboot as \(newIdentity)")
		unplug()
		identity = newIdentity; dockVersion = dock; queueOTA = []; waiting = nil
		locked { parser.reset() }
		queue.asyncAfter(deadline: .now() + 0.3) { [self] in
			try? plugIn(name: name(for: newIdentity))
			bootLog()
		}
	}

	// MARK: raw output (device -> page)

	/// Sends packet lists as given: each element is one MIDIReceived call, each inner array one packet in it.
	public func emit(packetLists: [[[UInt8]]]) {
		for packets in packetLists {
			let size = 1024 + packets.reduce(0) { $0 + $1.count + 16 }
			let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
			defer { raw.deallocate() }
			let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
			var cur: UnsafeMutablePointer<MIDIPacket>? = MIDIPacketListInit(list)
			for p in packets where !p.isEmpty {
				// (a time stamp of its own each: MIDIPacketListAdd would join packets of one time into one)
				let t = mach_absolute_time()
				cur = p.withUnsafeBufferPointer { MIDIPacketListAdd(list, size, cur!, t, $0.count, $0.baseAddress!) }
				precondition(cur != nil, "packet list full")
			}
			MIDIReceived(source, list)
		}
	}

	/// Sends UMP packet runs as given: each element is one MIDIReceivedEventList call, each inner array one packet.
	public func emit(umpLists: [[[UInt32]]]) {
		for packets in umpLists {
			let size = 1024 + packets.reduce(0) { $0 + 16 * $1.count + 16 }
			let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
			defer { raw.deallocate() }
			let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
			var cur: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
			for p in packets {
				let t = mach_absolute_time()
				cur = p.withUnsafeBufferPointer { MIDIEventListAdd(list, size, cur!, t, $0.count, $0.baseAddress!) }
				precondition(cur != nil, "event list full")
			}
			MIDIReceivedEventList(source, list)
		}
	}

	/// One message to the page, cut into chunkSize packets when that is set.
	private func tx(_ msg: [UInt8]) {
		guard source != 0 else { return }
		switch sourceAPI {
		case .universal:
			emit(umpLists: [UMP.packets(forMessage: msg)])
		case .legacy:
			let n = chunkSize
			if n > 0 {
				emit(packetLists: stride(from: 0, to: msg.count, by: n).map { [Array(msg[$0..<min($0 + n, msg.count)])] })
			} else { emit(packetLists: [[msg]]) }
		}
	}

	private func later(_ ms: Int, _ f: @escaping @Sendable () -> Void) { queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: f) }

	private func reply(_ cmd: UInt8, _ seq: UInt8, _ payload: [UInt8], ms: Int = 3) {
		let f = FM1Protocol.frame(cmd: cmd | 0x40, seq: seq, payload: payload)
		later(ms) { [self] in tx(f) }
	}

	// MARK: input (page -> device)

	private func got(_ bytes: [UInt8]) {
		let msgs = locked { () -> [[UInt8]] in
			let m = parser.feed(bytes)
			_received += m
			return m
		}
		for m in msgs { queue.async { [self] in rx(m) } }
	}

	private func rx(_ d: [UInt8]) {
		if d == FM1Protocol.handshakeQuery {
			// (ota.c ota_send_msg: 0, 0x59, cmd, the body's length, 0, 0, the body, ~sum of the body)
			let t = Array(identity.utf8.prefix(27)), body = t + [UInt8](repeating: 0, count: 27 - t.count)
			tx([0xF0] + FM1Protocol.pack7([0, 0x59, 0x11, 27, 0, 0] + body + [~body.reduce(0, &+)]) + [0xF7])
		} else if d == FM1Protocol.upgrade {
			upgrade()
		} else if d.count > 4, d[0] == 0xF0, Array(d[1...3]) == FM1Protocol.dockManufacturer {
			if dockVersion != nil, let r = FM1Protocol.parse(d) { dock(r.cmd, r.seq, r.payload) }
		} else if d.first == 0xF0, waiting != nil {
			served(d)
		}
	}

	// MARK: the update (fm1ota.js's other side)

	private func upgrade() {
		let ota = identity.hasPrefix("ota-")
		note("UPGRADE (\(ota ? "loader: the whole image" : "running: stage the loader"))")
		writeServed = 0
		if ota {
			queueOTA = stride(from: 0, to: imageLength, by: 512).map { (UInt32($0), min(512, imageLength - $0)) } + [(0xF000_0000, 8)]
		} else {
			queueOTA = [(0, 64), (0x40, 160), (0x1000, 512), (0xE000_0000, 8)]
		}
		later(50) { [self] in next() }
	}

	private func next() {
		guard !queueOTA.isEmpty else { return }
		let r = queueOTA.removeFirst()
		waiting = r
		var u: [UInt8] = [0, 0x59, 0x30, 8, 0, 0, 0] + FM1Protocol.le32(r.addr) + [UInt8(r.len & 0xFF), UInt8(r.len >> 8), 0]
		let s = u[6..<14].reduce(0) { $0 + Int($1) }
		u.append(UInt8(~s & 0xFF))
		tx([0xF0] + FM1Protocol.pack7(u) + [0xF7])
	}

	private func served(_ d: [UInt8]) {
		let u = FM1Protocol.unpack7(d[1..<(d.count - 1)])
		guard u.count > 14, u[1] == 0x59, u[2] == 0x30, let w = waiting else { return }
		waiting = nil
		let model = identity.replacingOccurrences(of: "ota-", with: "").components(separatedBy: "_")[0]
		if w.addr == 0xE000_0000 {
			let v = loaderVersion
			later(400) { [self] in reboot(as: "ota-\(model)_\(v)", dock: nil) }
		} else if w.addr == 0xF000_0000 {
			note("image written")
			later(600) { [self] in reboot(as: product, dock: "0.7") }
		} else {
			let data = Array(u[14..<min(u.count - 1, 14 + w.len)])
			if identity.hasPrefix("ota-") {
				locked { for (i, b) in data.enumerated() where Int(w.addr) + i < _written.count { _written[Int(w.addr) + i] = b } }
				writeServed += 1
				if let n = dropLoaderAfter, writeServed >= n {
					dropLoaderAfter = nil
					note("loader dropped its USB after \(writeServed) requests of the write")
					unplug()
					queueOTA = []; waiting = nil; writeServed = 0
					locked { parser.reset() }
					later(Int(dropFor * 1000)) { [self] in try? plugIn(name: name(for: identity)); note("loader back") }
					return
				}
			}
			next()
		}
	}

	// MARK: fm1-dock (firmware/src/dock.c's deploys), written from dock.c, not from the app's planner

	/// The FM-1's deploy area (dock.c DP_LO..DP_HI): 296 KiB.
	public static let deployArea = 0x96000..<0xE0000
	static func sectors(_ n: Int) -> Int { (n + 0xFFF) & ~0xFFF }
	/// hal/fm1_xip.h FM1_XIP
	static func xip(_ off: Int) -> UInt32 { UInt32(0x0200_0000 + off - 0x4000) }

	/// hb_file_t: name, version, code + data (LIST's size), and dock.c's total (header and relocs to 256, the image).
	static func header(_ b: [UInt8]) -> (name: String, version: UInt32, listSize: UInt32, total: Int, abi: UInt32, flags: UInt32)? {
		guard b.count >= 80, FM1Protocol.rd32(b, 0) == 0x5242_5248 else { return nil }
		let r = FM1Protocol.rd32
		let io = (80 + 4 * Int(r(b, 68)) + 255) & ~255
		return (FM1Protocol.cstr(b[12..<35]), r(b, 36), r(b, 40) &+ r(b, 44), io + Int(r(b, 40)) + Int(r(b, 44)) + Int(r(b, 52)),
		        r(b, 4), r(b, 8))
	}

	/// dock.c dp_room: the free bytes from at to the next module (0: at is inside one)
	private func dpRoom(_ at: Int) -> Int {
		var end = Self.deployArea.upperBound
		for m in deployed {
			let lo = m.at, hi = lo + Self.sectors(m.total)
			if at >= lo && at < hi { return 0 }
			if lo >= at && lo < end { end = lo }
		}
		return end - at
	}

	/// dock.c dp_place: first fit; (where, largest, total)
	private func dpPlace(_ need: Int) -> (at: Int?, largest: Int, total: Int) {
		var at: Int?, largest = 0, total = 0
		for i in 0...deployed.count {
			let s0 = i < deployed.count ? deployed[i].at + Self.sectors(deployed[i].total) : Self.deployArea.lowerBound
			guard Self.deployArea.contains(s0) else { continue }
			let r = dpRoom(s0)
			if r == 0 { continue }
			largest = max(largest, r); total += r
			if r >= need && (at == nil || s0 < at!) { at = s0 }
		}
		return (at, largest, total)
	}

	private static let image: [(String, Int)] = [("CS-1", 53000), ("SCINTILLA", 89000)]

	private func bootLog() {
		guard let v = dockVersion else { return }
		log("fm1-dock \(v) boot, reset 00000001", "started \(curName)")
	}

	private func log(_ lines: String...) {
		for l in lines { logText += "\(Int(Date().timeIntervalSince(started) * 1000)) \(l)\n" }
		if logText.count > 2048 { logText = String(logText.suffix(2048)) }
	}

	/// dock.c scan_slots: the sine, the package's modules, the deployed table (one of an image module's name takes
	/// its place in the list)
	private func modules() -> [(name: String, kind: UInt8, version: UInt32, size: UInt32, at: UInt32)] {
		var list: [(name: String, kind: UInt8, version: UInt32, size: UInt32, at: UInt32)] = [("SINE", 0, 0, 0, 0)]
		for (i, m) in Self.image.enumerated() { list.append((m.0, 1, 1, UInt32(m.1), Self.xip(0x35000 + i * 0x10000))) }
		for d in deployed {
			let e = (d.name, UInt8(2), d.version, d.listSize, Self.xip(d.at))
			if let i = list.firstIndex(where: { $0.kind == 1 && $0.name == d.name }) { list[i] = e } else { list.append(e) }
		}
		return list
	}

	private func command(_ c: String) { locked { _commands.append(c) } }

	private func dock(_ cmd: UInt8, _ seq: UInt8, _ d: [UInt8]) {
		let le = FM1Protocol.le32
		let mods = modules()
		let cur = mods.firstIndex { $0.name == curName } ?? 0
		switch FM1Protocol.Cmd(rawValue: cmd) {
		case .hello:
			let room = dpPlace(Int.max)
			reply(cmd, seq, [0, 1, 2, UInt8(mods.count), UInt8(cur), receiving == nil ? 0 : 1, 0, 0] + le(UInt32(room.largest))
				+ le(UInt32(room.total)) + le(0x44000) + le(0) + le(0) + le(61000) + le(0) + le(UInt32(logText.utf8.count))
				+ le(139_296) + [UInt8](repeating: 0, count: 16))
		case .list:
			for (i, m) in mods.enumerated() {
				reply(cmd, seq, [0, UInt8(i), 0, m.kind] + le(m.version) + le(m.size) + le(m.at) + FM1Protocol.name24(m.name), ms: 2 + i)
			}
			reply(cmd, seq, [0, 0xFF], ms: 4 + mods.count)
		case .log:
			let bytes = Array(logText.utf8), from = min(Int(FM1Protocol.rd32(d, 0)), bytes.count)
			reply(cmd, seq, [0, 0, 0, 0] + le(UInt32(bytes.count)) + le(UInt32(from)) + Array(bytes[from..<min(bytes.count, from + 180)]))
		case .begin:
			let size = Int(FM1Protocol.rd32(d, 0))
			guard d.count >= 32 else { reply(cmd, seq, [10]); break }
			guard size >= 84, size <= 0x44000 else { reply(cmd, seq, [3]); break }
			let name = FM1Protocol.cstr(d.dropFirst(8).prefix(23))
			receiving = (size, FM1Protocol.rd32(d, 4), name, [UInt8](repeating: 0, count: size), [])
			command("BEGIN \(name)")
			note("BEGIN \(name) \(size) B")
			reply(cmd, seq, [0], ms: 20)
		case .data:
			let off = Int(FM1Protocol.rd32(d, 0))
			guard var r = receiving else { reply(cmd, seq, [8, 0, 0, 0] + le(UInt32(off))); break }
			let want = off < r.size ? min(256, r.size - off) : 0
			guard off % 256 == 0, want > 0, d.count - 4 == want else { reply(cmd, seq, [10, 0, 0, 0] + le(UInt32(off))); break }
			for (i, b) in d.dropFirst(4).enumerated() { r.got[off + i] = b }
			r.chunks.insert(off / 256)
			receiving = r
			reply(cmd, seq, [0, 0, 0, 0] + le(UInt32(off)), ms: 6)
		case .commit:
			guard let r = receiving else { reply(cmd, seq, [8]); break }
			receiving = nil
			let status = commit(r)
			if status == 0 { command("COMMIT \(r.name)"); log("deploy: done") } else { note("COMMIT \(r.name): status \(status)") }
			let now = modules(), c = now.firstIndex { $0.name == curName } ?? 0
			reply(cmd, seq, [UInt8(status), UInt8(c), 0, 0] + le(now[c].at), ms: 300)
		case .abort:
			if receiving != nil { receiving = nil; command("ABORT") }
		case .delete:
			guard receiving == nil else { reply(cmd, seq, [8]); break }
			let name = FM1Protocol.cstr(d.prefix(23))
			guard deployed.contains(where: { $0.name == name }) else { reply(cmd, seq, [9]); break }
			locked { deployed.removeAll { $0.name == name } }
			if !modules().contains(where: { $0.name == curName }) { curName = "SINE" }
			command("DELETE \(name)")
			log("deploy: deleted", name)
			reply(cmd, seq, [0], ms: 100)
		case .select:
			guard receiving == nil else { reply(cmd, seq, [8]); break }
			let name = FM1Protocol.cstr(d.prefix(23))
			guard let k = mods.firstIndex(where: { $0.name == name }), k > 0 else { reply(cmd, seq, [9]); break }
			curName = name
			command("SELECT \(name)")
			reply(cmd, seq, [0, UInt8(k)], ms: 50)
		case .safe:
			curName = "SINE"
			reply(cmd, seq, [0])
		case .info:                                              // dock.c info_fill, format 1 (fm1-dock 0.8 on)
			guard let v = dockVersion, v >= "0.8" else { reply(0x3F, seq, [10]); break }   // (before 0.8: no INFO)
			let room = dpPlace(Int.max)
			func str(_ s: String, _ n: Int) -> [UInt8] { Array((Array(s.utf8) + [UInt8](repeating: 0, count: n)).prefix(n)) }
			var b: [UInt8] = [0, 1, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0] + le(flashJEDEC) + le(UInt32(room.total)) + le(UInt32(room.largest))
			b += le(0x44000) + le(0) + le(360) + str("AC791N", 8) + str(v, 16) + str(v, 12) + str("FM-1", 16)
			reply(cmd, seq, b)
		default:
			reply(0x3F, seq, [10])
		}
	}

	/// dock.c d_commit: checks, then first fit beside the old copy of the name if there is room, else without it
	private func commit(_ r: (size: Int, crc: UInt32, name: String, got: [UInt8], chunks: Set<Int>)) -> Int {
		guard r.chunks.count == (r.size + 255) / 256 else { return 7 }
		guard FM1Protocol.crc32(r.got) == r.crc else { return 1 }
		guard let h = Self.header(r.got), h.abi == 2, h.flags & 0x100 == 0, h.total <= r.size else { return 2 }
		var old = deployed.firstIndex { $0.name == h.name }
		if old == nil && deployed.count >= 32 { return 4 }
		let need = Self.sectors(h.total)
		var at = dpPlace(need).at
		if at == nil, let o = old {                              // no room beside the old copy: it goes first
			locked { _ = deployed.remove(at: o) }
			old = nil
			at = dpPlace(need).at
		}
		guard let at else { return 4 }
		let p = Placed(name: h.name, blob: r.got, at: at, total: h.total, version: h.version, listSize: h.listSize)
		locked { if let o = old { deployed[o] = p } else { deployed.append(p) } }
		curName = h.name                                          // (d_restart: the new one plays)
		return 0
	}
}
