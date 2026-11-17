// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import Foundation
import WebKit

public struct DockLinkError: Error, CustomStringConvertible, Hashable {
	public let description: String
	public init(_ d: String) { description = d }
}

/// fm1-dock on the FM-1, as rigs need it. One interface, so that how it is spoken can change (fm1-dock's own
/// dock.js now, through WebDockLink) without touching the planner, the applier or the UI.
@MainActor
public protocol DockLink: AnyObject {
	/// HELLO, LIST (and the handshake's identity): read only.
	func readState() async throws -> DockDeviceState
	/// BEGIN, DATA..., COMMIT. progress: 0...1 while the data goes.
	func deploy(_ file: Data, progress: @escaping @MainActor (Double) -> Void) async throws
	func delete(_ name: String) async throws
	func select(_ name: String) async throws
	/// ABORT: an open receive (BEGIN without its COMMIT) closed.
	func abort() async throws
}

/// DockLink over fm1-dock's own JavaScript (dock.js, install/*.js) in a WKWebView nobody sees, on the app's MIDI
/// engine through the Web MIDI bridge. The view must be in a window (a web view out of one may have its timers
/// held back): `webView` is there for the host to add.
@MainActor
public final class WebDockLink: NSObject, DockLink, WKNavigationDelegate {
	public let webView: WKWebView
	private let bridge: WebMIDIBridge
	private var loaded = false
	private var loadError: Error?

	/// - Parameter resolver: serves fm1dock://app/ (rigs.html, rigs.js, dock.js, install/...): the app's web folder.
	public init(engine: MIDIEngine, resolver: @escaping LocalSchemeHandler.Resolver) {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		config.setURLSchemeHandler(LocalSchemeHandler(resolver: resolver), forURLScheme: "fm1dock")
		bridge = WebMIDIBridge(engine: engine, allowedOrigins: ["fm1dock://app"])
		bridge.install(in: config)
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
		super.init()
		webView.navigationDelegate = self
		bridge.attach(webView)
	}

	/// Lets go of the MIDI traffic; the view is the host's to remove.
	public func close() { bridge.detach(); webView.stopLoading() }

	private func ready() async throws {
		if !loaded {
			loadError = nil
			webView.load(URLRequest(url: URL(string: "fm1dock://app/rigs.html")!))
			let end = Date().addingTimeInterval(15)
			while !loaded {
				if let loadError { throw loadError }
				if Date() > end { throw DockLinkError("The rigs page did not load.") }
				try await Task.sleep(nanoseconds: 20_000_000)
			}
		}
		let end = Date().addingTimeInterval(10)
		while (try? await webView.callAsyncJavaScript("return !!(window.R && R.ready)", arguments: [:], in: nil, contentWorld: .page)) as? Bool != true {
			if Date() > end { throw DockLinkError("The rigs page did not start.") }
			try await Task.sleep(nanoseconds: 20_000_000)
		}
	}

	private func call(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
		try await ready()
		do { return try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page) } catch {
			let msg = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
			throw DockLinkError(msg.replacingOccurrences(of: "Error: ", with: ""))
		}
	}

	public func readState() async throws -> DockDeviceState {
		guard let r = try await call("return await R.state()") as? [String: Any] else { throw DockLinkError("No answer.") }
		let identity = r["identity"] as? String
		guard let dock = r["dock"] as? [String: Any], let hello = dock["hello"] as? [String: Any] else {
			throw DockLinkError(identity.map { "The FM-1 runs \($0), not fm1-dock." } ?? "No FM-1 running fm1-dock answered.")
		}
		let info = dock["info"] as? [String: Any]
		let n = { (d: [String: Any]?, k: String) -> Int in (d?[k] as? NSNumber)?.intValue ?? 0 }
		let kinds: [String: DeviceModule.Kind] = ["built in": .builtIn, "image": .image, "deployed": .deployed, "boot": .boot]
		let modules = (dock["modules"] as? [[String: Any]] ?? []).map { m in
			DeviceModule(index: n(m, "index"), name: m["name"] as? String ?? "", kind: kinds[m["kind"] as? String ?? ""] ?? .other,
			             state: m["state"] as? String ?? "", version: UInt32(truncatingIfNeeded: n(m, "version")),
			             size: UInt32(truncatingIfNeeded: n(m, "size")), xip: UInt32(truncatingIfNeeded: n(m, "at")))
		}
		let smk = (info?["board"] as? String) == "smk37" || (identity ?? "").uppercased().hasPrefix("SMK")
			|| (identity ?? "").uppercased().hasPrefix("MKE") || (identity ?? "").uppercased().hasPrefix("STARRY")
		return DockDeviceState(identity: identity, dockVersion: info?["version"] as? String, board: smk ? .smk37 : .fm1,
		                       abi: UInt32(n(hello, "abi")), free: n(hello, "free"), largest: n(hello, "largest"),
		                       maxFile: n(hello, "maxFile"), receiving: n(hello, "receiving") != 0, current: n(hello, "cur"),
		                       modules: modules)
	}

	public func deploy(_ file: Data, progress: @escaping @MainActor (Double) -> Void) async throws {
		let poll = Task { @MainActor [webView] in
			while !Task.isCancelled {
				if let x = try? await webView.callAsyncJavaScript("return R.progress", arguments: [:], in: nil, contentWorld: .page) as? Double {
					progress(x)
				}
				try? await Task.sleep(nanoseconds: 150_000_000)
			}
		}
		defer { poll.cancel() }
		_ = try await call("return await R.deploy(b)", ["b": file.base64EncodedString()])
		progress(1)
	}

	private func status(_ r: Any?, _ what: String) throws {
		let s = r as? String ?? "no answer"
		if s != "done" { throw DockLinkError("\(what): fm1-dock says \(s)") }
	}
	public func delete(_ name: String) async throws { try status(try await call("return await R.remove(n)", ["n": name]), "Removing \(name)") }
	public func select(_ name: String) async throws { try status(try await call("return await R.select(n)", ["n": name]), "Selecting \(name)") }
	public func abort() async throws { _ = try await call("return await R.abort()") }

	public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
	public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadError = error }
	public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadError = error }
}
#endif
