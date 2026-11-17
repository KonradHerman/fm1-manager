// SPDX-License-Identifier: GPL-3.0-only
#if canImport(WebKit)
import FM1Kit
import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct HarnessError: Error, CustomStringConvertible {
	public let description: String
	public init(_ d: String) { description = d }
}

/// A WKWebView with the Web MIDI bridge, its MIDI engine limited to one FakeFM1's endpoints, for tests. Pages are
/// served under fm1dock://app/ by a resolver (a directory, or the test's own files); confirm() answers yes.
@MainActor
public final class WebHarness: NSObject, WKNavigationDelegate, WKUIDelegate {
	public let webView: WKWebView
	public let bridge: WebMIDIBridge
	public let engine: MIDIEngine
	public private(set) var dialogs: [String] = []
	public private(set) var loadError: Error?
	private var finished = false
	#if canImport(AppKit)
	private var window: NSWindow?
	#else
	private var window: UIWindow?
	#endif

	public init(filter: @escaping MIDIEngine.Filter, resolver: LocalSchemeHandler.Resolver? = nil,
	            allowedOrigins: [String] = ["fm1dock://app"], userAgent: String? = nil,
	            inputAPI: MIDIEngine.PacketAPI = .universal, outputAPI: MIDIEngine.PacketAPI = .universal) throws {
		engine = try MIDIEngine(clientName: "FM1 WebHarness", inputAPI: inputAPI, outputAPI: outputAPI, filter: filter)
		bridge = WebMIDIBridge(engine: engine, allowedOrigins: allowedOrigins)
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		if let resolver { config.setURLSchemeHandler(LocalSchemeHandler(resolver: resolver), forURLScheme: "fm1dock") }
		bridge.install(in: config)
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 900), configuration: config)
		webView.customUserAgent = userAgent
		super.init()
		webView.navigationDelegate = self
		webView.uiDelegate = self
		bridge.attach(webView)
		// in a window, so the page's timers run as in a visible page (a page out of any window may be throttled)
		#if canImport(AppKit)
		let w = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
		w.isReleasedWhenClosed = false
		w.contentView = webView
		w.orderBack(nil)
		window = w
		#else
		let w = UIWindow(frame: webView.frame)
		let vc = UIViewController()
		vc.view = webView
		w.rootViewController = vc
		w.isHidden = false
		window = w
		#endif
	}

	public func close() {
		bridge.detach()
		#if canImport(AppKit)
		window?.close()
		#endif
		window = nil
	}

	public func load(_ url: URL, timeout: TimeInterval = 30) async throws {
		finished = false; loadError = nil
		webView.load(URLRequest(url: url))
		let end = Date().addingTimeInterval(timeout)
		while !finished {
			if let loadError { throw loadError }
			if Date() > end { throw HarnessError("\(url) did not load in \(timeout) s") }
			try await Task.sleep(nanoseconds: 20_000_000)
		}
	}

	@discardableResult
	public func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
		try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
	}

	/// Polls a JS expression's truth until it holds; the last value it gave is in the error.
	public func waitFor(_ expr: String, timeout: TimeInterval = 15, poll: UInt64 = 50_000_000) async throws {
		let end = Date().addingTimeInterval(timeout)
		var last: Any?
		while true {
			last = try? await js("return \(expr)")
			if let b = last as? Bool, b { return }
			if let n = last as? NSNumber, n.boolValue { return }
			if Date() > end { throw HarnessError("timed out waiting for \(expr) (last: \(String(describing: last)))") }
			try await Task.sleep(nanoseconds: poll)
		}
	}

	public func text(_ selector: String) async throws -> String {
		(try await js("const e = document.querySelector(s); return e ? e.textContent : null", ["s": selector]) as? String) ?? ""
	}

	// MARK: delegates

	public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
	public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadError = error }
	public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadError = error }

	public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
	                    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
		dialogs.append(message); completionHandler(true)
	}

	public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
	                    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
		dialogs.append(message); completionHandler()
	}
}
#endif
