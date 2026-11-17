// SPDX-License-Identifier: GPL-3.0-only
import CoreMIDI
import Foundation

/// A MIDI port as a page sees it: a CoreMIDI source is a Web MIDI input, a destination an output.
public struct MIDIEndpointInfo: Sendable, Hashable, Codable {
	public enum Kind: String, Sendable, Codable { case input, output }
	/// Stable while the device stays known to CoreMIDI: its kMIDIPropertyUniqueID.
	public let id: String
	public let kind: Kind
	public let name: String
	public let manufacturer: String
	public let version: String

	public init(id: String, kind: Kind, name: String, manufacturer: String = "", version: String = "") {
		self.id = id; self.kind = kind; self.name = name; self.manufacturer = manufacturer; self.version = version
	}
}

/// One complete message from an input (a whole SysEx, a channel message, a real-time byte).
public struct MIDIReceivedMessage: Sendable, Hashable {
	public let endpointID: String
	public let bytes: [UInt8]
}

public enum MIDIEngineError: Error, CustomStringConvertible {
	case coreMIDI(String, OSStatus)
	case unknownOutput(String)
	case incompleteMessage
	case bufferFull

	public var description: String {
		switch self {
		case let .coreMIDI(what, status): "\(what) failed (OSStatus \(status))"
		case let .unknownOutput(id): "no MIDI output \(id)"
		case .incompleteMessage: "not a complete MIDI message (a SysEx needs F0 ... F7)"
		case .bufferFull: "the message did not fit in a packet list"
		}
	}
}

/// CoreMIDI for the pages: the sources and destinations a filter lets through, every message from those sources
/// reassembled into whole messages, and sends to those destinations. Nothing outside the filter is listed, connected
/// or sent to: the tests pass a filter that admits only their own virtual endpoints.
///
/// Thread safety: CoreMIDI reads on its own thread; state is behind a lock and observers are called, in order, on
/// `callbackQueue` (a serial queue: the main queue by default). Create it on a thread with a run loop (the main
/// thread) so CoreMIDI's setup notifications (hot-plug) arrive.
public final class MIDIEngine: @unchecked Sendable {
	/// Which CoreMIDI API carries the packets: the protocol-aware one (MIDIEventList, UMP, MIDI 1.0 protocol) or
	/// the older MIDIPacketList of bytes. Both end in the same reassembly.
	public enum PacketAPI: String, Sendable, CaseIterable, Codable { case universal, legacy }

	public typealias Filter = @Sendable (MIDIEndpointInfo) -> Bool
	public typealias EndpointsObserver = @Sendable ([MIDIEndpointInfo]) -> Void
	public typealias MessagesObserver = @Sendable ([MIDIReceivedMessage]) -> Void

	public let inputAPI: PacketAPI
	public let outputAPI: PacketAPI
	public let callbackQueue: DispatchQueue
	private let filter: Filter

	private var client = MIDIClientRef()
	private var inPort = MIDIPortRef()
	private var outPort = MIDIPortRef()

	private struct Source { var ref: MIDIEndpointRef; var token: Int; var parser = MIDIStreamParser() }
	private struct State {
		var endpoints: [MIDIEndpointInfo] = []
		var destinations: [String: MIDIEndpointRef] = [:]
		var sources: [String: Source] = [:]          // connected sources by id
		var tokens: [Int: String] = [:]              // connection refCon -> source id
		var nextToken = 1
		var observers: [Int: (EndpointsObserver, MessagesObserver)] = [:]
		var nextObserver = 1
		var rescanPending = false
	}
	private let lock = NSLock()
	private var state = State()

	public init(clientName: String = "FM-1 Manager", inputAPI: PacketAPI = .universal, outputAPI: PacketAPI = .universal,
	            callbackQueue: DispatchQueue = .main, filter: @escaping Filter) throws {
		self.inputAPI = inputAPI; self.outputAPI = outputAPI; self.callbackQueue = callbackQueue; self.filter = filter
		var st = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] note in
			switch note.pointee.messageID {
			case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged: self?.scheduleRescan()
			default: break
			}
		}
		guard st == noErr else { throw MIDIEngineError.coreMIDI("MIDIClientCreate", st) }
		switch inputAPI {
		case .universal:
			st = MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
				self?.receive(eventList: list, refCon: refCon)
			}
		case .legacy:
			st = MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] list, refCon in
				self?.receive(packetList: list, refCon: refCon)
			}
		}
		guard st == noErr else { MIDIClientDispose(client); throw MIDIEngineError.coreMIDI("MIDIInputPortCreate", st) }
		st = MIDIOutputPortCreate(client, "out" as CFString, &outPort)
		guard st == noErr else { MIDIClientDispose(client); throw MIDIEngineError.coreMIDI("MIDIOutputPortCreate", st) }
		rescan()
	}

	deinit { MIDIClientDispose(client) }

	// MARK: observers

	public final class Observation: @unchecked Sendable {
		private let cancelFn: () -> Void
		private let once = NSLock()
		private var done = false
		init(_ cancel: @escaping () -> Void) { cancelFn = cancel }
		public func cancel() {
			once.lock(); defer { once.unlock() }
			if !done { done = true; cancelFn() }
		}
		deinit { cancel() }
	}

	/// Calls `endpoints` now and on every change, `messages` for every batch of messages; both on callbackQueue.
	/// Keep the returned Observation: dropping it stops the calls.
	public func observe(endpoints: @escaping EndpointsObserver, messages: @escaping MessagesObserver) -> Observation {
		let (id, list) = lock.withLock { () -> (Int, [MIDIEndpointInfo]) in
			let id = state.nextObserver
			state.nextObserver += 1
			state.observers[id] = (endpoints, messages)
			return (id, state.endpoints)
		}
		callbackQueue.async { endpoints(list) }
		return Observation { [weak self] in self?.lock.withLock { _ = self?.state.observers.removeValue(forKey: id) } }
	}

	public var endpoints: [MIDIEndpointInfo] { lock.withLock { state.endpoints } }

	// MARK: endpoints

	private func scheduleRescan() {
		let go = lock.withLock { () -> Bool in
			if state.rescanPending { return false }
			state.rescanPending = true
			return true
		}
		if go { callbackQueue.async { [weak self] in self?.rescan() } }
	}

	/// Lists the endpoints again, connects the new sources and tells the observers when something changed.
	public func rescan() {
		var found: [MIDIEndpointInfo] = []
		var srcs: [String: MIDIEndpointRef] = [:], dsts: [String: MIDIEndpointRef] = [:]
		for i in 0..<MIDIGetNumberOfSources() {
			let e = MIDIGetSource(i)
			if let info = Self.info(e, .input), filter(info) { found.append(info); srcs[info.id] = e }
		}
		for i in 0..<MIDIGetNumberOfDestinations() {
			let e = MIDIGetDestination(i)
			if let info = Self.info(e, .output), filter(info) { found.append(info); dsts[info.id] = e }
		}
		let (changed, observers) = lock.withLock { () -> (Bool, [EndpointsObserver]) in
			state.rescanPending = false
			for (id, src) in state.sources where srcs[id] == nil {
				MIDIPortDisconnectSource(inPort, src.ref)
				state.sources[id] = nil
				state.tokens[src.token] = nil
			}
			for (id, ref) in srcs where state.sources[id] == nil {
				let token = state.nextToken
				state.nextToken += 1
				if MIDIPortConnectSource(inPort, ref, UnsafeMutableRawPointer(bitPattern: token)) == noErr {
					state.sources[id] = Source(ref: ref, token: token)
					state.tokens[token] = id
				}
			}
			state.destinations = dsts
			let changed = found != state.endpoints
			state.endpoints = found
			return (changed, state.observers.values.map(\.0))
		}
		let list = found
		if changed { callbackQueue.async { for o in observers { o(list) } } }
	}

	private static func info(_ e: MIDIEndpointRef, _ kind: MIDIEndpointInfo.Kind) -> MIDIEndpointInfo? {
		guard e != 0 else { return nil }
		var offline: Int32 = 0
		if MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &offline) == noErr, offline != 0 { return nil }
		var uid: MIDIUniqueID = 0
		guard MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid) == noErr else { return nil }
		var version: Int32 = 0
		let hasVersion = MIDIObjectGetIntegerProperty(e, kMIDIPropertyDriverVersion, &version) == noErr
		// The name Chrome gives a port on macOS: the display name (the device's name for a one-port device)
		let name = string(e, kMIDIPropertyDisplayName) ?? string(e, kMIDIPropertyName) ?? ""
		return MIDIEndpointInfo(id: String(uid), kind: kind, name: name,
		                        manufacturer: string(e, kMIDIPropertyManufacturer) ?? "",
		                        version: hasVersion ? String(version) : "")
	}

	private static func string(_ obj: MIDIObjectRef, _ key: CFString) -> String? {
		var s: Unmanaged<CFString>?
		guard MIDIObjectGetStringProperty(obj, key, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
		return v as String
	}

	// MARK: receiving

	private func receive(eventList: UnsafePointer<MIDIEventList>, refCon: UnsafeMutableRawPointer?) {
		var bytes: [UInt8] = []
		for packet in eventList.unsafeSequence() {
			bytes += UMP.midi1Bytes(fromWords: Self.words(packet))
		}
		deliver(bytes, refCon: refCon)
	}

	private func receive(packetList: UnsafePointer<MIDIPacketList>, refCon: UnsafeMutableRawPointer?) {
		var bytes: [UInt8] = []
		for packet in packetList.unsafeSequence() {
			bytes += Self.bytes(packet)
		}
		deliver(bytes, refCon: refCon)
	}

	static func words(_ p: UnsafePointer<MIDIEventPacket>) -> UnsafeBufferPointer<UInt32> {
		let n = Int(p.pointee.wordCount)   // (variable length: a packet may hold more than its 64-word tuple)
		let base = UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
		return UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt32.self), count: n)
	}

	static func bytes(_ p: UnsafePointer<MIDIPacket>) -> UnsafeBufferPointer<UInt8> {
		let base = UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!)
		return UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: Int(p.pointee.length))
	}

	private func deliver(_ bytes: [UInt8], refCon: UnsafeMutableRawPointer?) {
		let token = Int(bitPattern: refCon)
		let (msgs, observers) = lock.withLock { () -> ([MIDIReceivedMessage], [MessagesObserver]) in
			guard let id = state.tokens[token], var src = state.sources[id] else { return ([], []) }
			let out = src.parser.feed(bytes).map { MIDIReceivedMessage(endpointID: id, bytes: $0) }
			state.sources[id] = src
			return (out, state.observers.values.map(\.1))
		}
		guard !msgs.isEmpty, !observers.isEmpty else { return }
		callbackQueue.async { for o in observers { o(msgs) } }
	}

	// MARK: sending

	/// Sends one or more complete messages to an output the filter lets through, `delay` seconds from now (0: at once).
	public func send(_ bytes: [UInt8], to id: String, delay: TimeInterval = 0) throws {
		guard let dest = lock.withLock({ state.destinations[id] }) else { throw MIDIEngineError.unknownOutput(id) }
		let (messages, complete) = MIDIStreamParser.split(bytes)
		guard complete, !messages.isEmpty else { throw MIDIEngineError.incompleteMessage }
		let when: MIDITimeStamp = delay > 0 ? mach_absolute_time() + Self.hostTicks(seconds: delay) : 0
		switch outputAPI {
		case .universal: try sendUMP(messages, to: dest, at: when)
		case .legacy: try sendPackets(messages, to: dest, at: when)
		}
	}

	private func sendUMP(_ messages: [[UInt8]], to dest: MIDIEndpointRef, at when: MIDITimeStamp) throws {
		let packets = messages.flatMap(UMP.packets(forMessage:))
		let size = 1024 + 16 * packets.reduce(0) { $0 + $1.count }
		let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
		defer { raw.deallocate() }
		let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
		var cur: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
		for p in packets {
			cur = p.withUnsafeBufferPointer { MIDIEventListAdd(list, size, cur!, when, $0.count, $0.baseAddress!) }
			if cur == nil { throw MIDIEngineError.bufferFull }
		}
		let st = MIDISendEventList(outPort, dest, list)
		if st != noErr { throw MIDIEngineError.coreMIDI("MIDISendEventList", st) }
	}

	private func sendPackets(_ messages: [[UInt8]], to dest: MIDIEndpointRef, at when: MIDITimeStamp) throws {
		let size = 1024 + messages.reduce(0) { $0 + $1.count + 16 }
		let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
		defer { raw.deallocate() }
		let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
		var cur: UnsafeMutablePointer<MIDIPacket>? = MIDIPacketListInit(list)
		for m in messages {
			cur = m.withUnsafeBufferPointer { MIDIPacketListAdd(list, size, cur!, when, $0.count, $0.baseAddress!) }
			if cur == nil { throw MIDIEngineError.bufferFull }
		}
		let st = MIDISend(outPort, dest, list)
		if st != noErr { throw MIDIEngineError.coreMIDI("MIDISend", st) }
	}

	static func hostTicks(seconds: TimeInterval) -> UInt64 {
		var tb = mach_timebase_info_data_t()
		mach_timebase_info(&tb)
		return UInt64(seconds * 1e9) * UInt64(tb.denom) / UInt64(tb.numer)
	}
}
