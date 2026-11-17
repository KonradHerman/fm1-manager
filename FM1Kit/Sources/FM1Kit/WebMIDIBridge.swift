// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import Foundation
import WebKit

/// Web MIDI for a WKWebView: `navigator.requestMIDIAccess` (webmidi.js, injected at document start) on the pages of
/// `allowedOrigins`, backed by a MIDIEngine. Pages of other origins get no Web MIDI at all, and the app's handler
/// refuses messages from them.
///
///     let bridge = WebMIDIBridge(engine: engine, allowedOrigins: ["https://thefirmwarehub.com"])
///     bridge.install(in: configuration)            // before the web view is made
///     let webView = WKWebView(frame: .zero, configuration: configuration)
///     bridge.attach(webView)
@MainActor
public final class WebMIDIBridge: NSObject, WKScriptMessageHandlerWithReply {
	public static let handlerName = "fm1midi"

	public let engine: MIDIEngine
	public let allowedOrigins: [String]
	/// When a SysEx last went either way: an install keeps this fresh (the device asks for data all the time).
	public private(set) var lastSysEx: Date?
	/// Every message either way (out: true for what the page sent); for a log.
	public var onTraffic: ((_ out: Bool, _ bytes: [UInt8]) -> Void)?
	/// A send CoreMIDI refused (the page cannot see it: Web MIDI's send returns nothing).
	public var onSendError: ((Error) -> Void)?

	private weak var webView: WKWebView?
	private var observation: MIDIEngine.Observation?
	private weak var controller: WKUserContentController?

	public init(engine: MIDIEngine, allowedOrigins: [String]) {
		self.engine = engine
		self.allowedOrigins = allowedOrigins
	}

	/// The shim's source with the allowed origins put in.
	public static func shimSource(allowedOrigins: [String]) -> String {
		guard let url = Bundle.module.url(forResource: "webmidi", withExtension: "js"),
		      let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
		let list = (try? String(data: JSONEncoder().encode(allowedOrigins), encoding: .utf8)) ?? "[]"
		return js.replacingOccurrences(of: "__FM1_ORIGINS__", with: list)
	}

	public func install(in configuration: WKWebViewConfiguration) {
		let ucc = configuration.userContentController
		ucc.addUserScript(WKUserScript(source: Self.shimSource(allowedOrigins: allowedOrigins),
		                               injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
		ucc.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
		controller = ucc
	}

	public func attach(_ webView: WKWebView) {
		self.webView = webView
		observation = engine.observe(
			endpoints: { [weak self] list in MainActor.assumeIsolated { self?.push(endpoints: list) } },
			messages: { [weak self] msgs in MainActor.assumeIsolated { self?.push(messages: msgs) } })
	}

	/// Stops the traffic and lets go of the web view (the user content controller holds the bridge until then).
	public func detach() {
		observation?.cancel()
		observation = nil
		controller?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
		webView = nil
	}

	/// True while the page says an install is running (it would ask before being left, or marks itself busy).
	public func pageIsBusy() async -> Bool {
		guard let webView else { return false }
		let r = try? await webView.callAsyncJavaScript("return window.__fm1midi ? window.__fm1midi.busy() : false",
		                                               arguments: [:], in: nil, contentWorld: .page)
		return (r as? Bool) ?? ((r as? NSNumber)?.boolValue ?? false)
	}

	// MARK: app -> page

	private static func json(_ e: MIDIEndpointInfo) -> [String: String] {
		["id": e.id, "kind": e.kind.rawValue, "name": e.name, "manufacturer": e.manufacturer, "version": e.version]
	}

	private func push(endpoints: [MIDIEndpointInfo]) {
		webView?.callAsyncJavaScript("window.__fm1midi && window.__fm1midi.ports(list)",
		                             arguments: ["list": endpoints.map(Self.json)], in: nil, in: .page, completionHandler: nil)
	}

	private func push(messages: [MIDIReceivedMessage]) {
		for m in messages {
			if m.bytes.first == 0xF0 { lastSysEx = Date() }
			onTraffic?(false, m.bytes)
		}
		let batch: [[Any]] = messages.map { [$0.endpointID, $0.bytes.map(Int.init)] }
		webView?.callAsyncJavaScript("window.__fm1midi && window.__fm1midi.receive(batch)",
		                             arguments: ["batch": batch], in: nil, in: .page, completionHandler: nil)
	}

	// MARK: page -> app

	static func origin(of frame: WKFrameInfo) -> String {
		let o = frame.securityOrigin
		return o.port == 0 ? "\(o.protocol)://\(o.host)" : "\(o.protocol)://\(o.host):\(o.port)"
	}

	public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
	                                  replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
		guard message.frameInfo.isMainFrame, allowedOrigins.contains(Self.origin(of: message.frameInfo)) else {
			replyHandler(nil, "MIDI is not offered to this page"); return
		}
		guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
			replyHandler(nil, "bad message"); return
		}
		switch op {
		case "access":
			replyHandler(engine.endpoints.map(Self.json), nil)
		case "send":
			guard let (id, bytes, delay) = WebMIDIWire.send(from: body) else { replyHandler(nil, "bad send"); return }
			if bytes.first == 0xF0 { lastSysEx = Date() }
			onTraffic?(true, bytes)
			do { try engine.send(bytes, to: id, delay: delay) } catch { onSendError?(error) }
			replyHandler(nil, nil)
		default:
			replyHandler(nil, "unknown op \(op)")
		}
	}
}

/// Serves an app's own pages to a WKWebView under a custom scheme (fm1dock://app/...), so ES modules and fetch()
/// work as they do over HTTP; a resolver maps each URL to its bytes and type, nil for a 404.
@MainActor
public final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
	public typealias Resolver = @MainActor (URL) -> (data: Data, mimeType: String)?
	private let resolver: Resolver

	public init(resolver: @escaping Resolver) { self.resolver = resolver }

	/// Files under root, by the URL's path (a path ending in "/" is its index.html); nothing outside root.
	public static func directory(_ root: URL) -> Resolver {
		let base = root.standardizedFileURL.path
		return { url in
			var path = url.path.removingPercentEncoding ?? url.path
			if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
			let file = URL(fileURLWithPath: base + path).standardizedFileURL
			guard file.path.hasPrefix(base + "/"), let data = try? Data(contentsOf: file) else { return nil }
			return (data, mimeType(forExtension: file.pathExtension))
		}
	}

	/// The app's offline site: files under `root`, and the library folder at /library/ (its files by name, and
	/// /library/index.json: [{ name, size }], the visible regular files, by name).
	public static func site(root: URL, library: URL) -> Resolver {
		let files = directory(root)
		return { url in
			let path = url.path.removingPercentEncoding ?? url.path
			guard path.hasPrefix("/library/") else { return files(url) }
			let name = String(path.dropFirst("/library/".count))
			if name == "index.json" {
				let list = libraryFiles(library).map { ["name": $0.lastPathComponent, "size": $0.fileSize] as [String: Any] }
				return ((try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8), "application/json")
			}
			guard !name.contains("/"), !name.hasPrefix("."),
			      let data = try? Data(contentsOf: library.appendingPathComponent(name)) else { return nil }
			return (data, "application/octet-stream")
		}
	}

	/// The visible regular files in a folder, by name.
	nonisolated public static func libraryFiles(_ folder: URL) -> [URL] {
		let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
		let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
		                                                         options: [.skipsHiddenFiles])) ?? []
		return all.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
			.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
	}

	public static func mimeType(forExtension ext: String) -> String {
		switch ext.lowercased() {
		case "html", "htm": "text/html; charset=utf-8"
		case "js", "mjs": "text/javascript; charset=utf-8"
		case "css": "text/css; charset=utf-8"
		case "json": "application/json"
		case "svg": "image/svg+xml"
		case "png": "image/png"
		case "jpg", "jpeg": "image/jpeg"
		case "webp": "image/webp"
		case "txt", "md", "syms": "text/plain; charset=utf-8"
		default: "application/octet-stream"
		}
	}

	public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
		guard let url = task.request.url else { return }
		let found = resolver(url)
		let body = found?.data ?? Data("not found".utf8)
		let headers = ["Content-Type": found?.mimeType ?? "text/plain", "Content-Length": String(body.count),
		               "Cache-Control": "no-store"]
		let response = HTTPURLResponse(url: url, statusCode: found == nil ? 404 : 200, httpVersion: "HTTP/1.1",
		                               headerFields: headers)!
		task.didReceive(response)
		task.didReceive(body)
		task.didFinish()
	}

	public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
#endif
