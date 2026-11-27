// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import Observation
import UIKit
import WebKit

/// A JavaScript alert / confirm / prompt the page opened, for SwiftUI to show (WKWebView shows none itself: without
/// this, confirm() is false and the pages' Install and Deploy would silently do nothing).
struct PageDialog: Identifiable {
	enum Kind { case alert, confirm, prompt }
	let id = UUID()
	let kind: Kind
	let message: String
	var text: String
	let answer: @MainActor (Bool, String?) -> Void
}

/// One page in a WKWebView with Web MIDI: its navigation, its dialogs, and whether an install is running there.
@MainActor @Observable
final class WebPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
	let site: Site
	let webView: WKWebView
	let bridge: WebMIDIBridge
	private(set) var title = ""
	private(set) var canGoBack = false
	private(set) var isLoading = false
	private(set) var loadError: String?
	/// A page has loaded at least once (before that, a failed load leaves nothing but a blank view).
	private(set) var hasLoaded = false
	/// An install (or another SysEx exchange) is running: the screen stays on, leaving asks first.
	private(set) var busy = false
	/// The page itself says an install runs (beforeunload would ask, or data-busy): links wait then.
	private(set) var pageBusy = false
	var dialog: PageDialog?
	var toast: String?
	private var poll: Task<Void, Never>?
	private var observers: [NSKeyValueObservation] = []

	/// Where a page's downloads go (a preset backup an installer saves): the library folder, visible in Files.
	private let downloads: URL

	/// The address the page opens at (the site's own, or the Firmware Hub's with its newer-chip filter).
	let startURL: URL
	/// Runs once the first page has loaded (the Hub bar's filter check).
	var afterFirstLoad: (@MainActor (WebPage) -> Void)?

	init(site: Site, engine: MIDIEngine, library: URL, url: URL? = nil) {
		self.site = site
		startURL = url ?? site.url
		downloads = library
		let config = WKWebViewConfiguration()
		#if FM1_DOCK
		let web = Bundle.main.url(forResource: "web", withExtension: nil)!
		config.setURLSchemeHandler(LocalSchemeHandler(resolver: LocalSchemeHandler.site(root: web, library: library)),
		                           forURLScheme: Site.scheme)
		#endif
		config.allowsInlineMediaPlayback = true
		bridge = WebMIDIBridge(engine: engine, allowedOrigins: Site.midiOrigins)
		bridge.install(in: config)
		webView = WKWebView(frame: .zero, configuration: config)
		webView.allowsBackForwardNavigationGestures = true
		#if DEBUG
		webView.isInspectable = true
		#endif
		super.init()
		webView.navigationDelegate = self
		webView.uiDelegate = self
		bridge.attach(webView)
		// KVO change handlers: @Sendable, so they are not main-actor isolated (KVO may call them on any thread);
		// the state is read and set on the main actor
		observers = [
			webView.observe(\.title) { @Sendable [weak self] _, _ in onMain { self?.title = self?.webView.title ?? "" } },
			webView.observe(\.canGoBack) { @Sendable [weak self] _, _ in onMain { self?.canGoBack = self?.webView.canGoBack ?? false } },
			webView.observe(\.isLoading) { @Sendable [weak self] _, _ in onMain { self?.isLoading = self?.webView.isLoading ?? false } },
		]
		webView.load(URLRequest(url: startURL))
		poll = Task { [weak self] in
			while !Task.isCancelled {
				await self?.checkBusy()
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
	}

	/// Stops the page (its MIDI traffic and the busy polling) and lets the screen sleep again.
	func close() {
		if let d = dialog { dialog = nil; d.answer(false, nil) }
		poll?.cancel()
		bridge.detach()
		webView.stopLoading()
		webView.loadHTMLString("", baseURL: nil)
		UIApplication.shared.isIdleTimerDisabled = false
	}

	private func checkBusy() async {
		let recent = bridge.lastSysEx.map { Date().timeIntervalSince($0) < 20 } ?? false
		let page = await bridge.pageIsBusy()
		let now = recent || page
		if now != busy { busy = now }
		if page != pageBusy { pageBusy = page }
		UIApplication.shared.isIdleTimerDisabled = now
	}

	func goBack() { webView.goBack() }
	func reload() { loadError = nil; webView.reload() }
	func goHome() { loadError = nil; webView.load(URLRequest(url: startURL)) }

	// MARK: the library's files to the page's file inputs

	/// The extensions this page's file inputs take ("*": an input that takes anything).
	func acceptedExtensions() async -> [String] {
		(try? await webView.callAsyncJavaScript(PageScripts.acceptedExtensions, arguments: [:], in: nil, contentWorld: .page)) as? [String] ?? []
	}

	func give(_ file: URL) async {
		do {
			let data = try Data(contentsOf: file)
			let r = try await webView.callAsyncJavaScript(PageScripts.giveFile,
			                                              arguments: ["name": file.lastPathComponent, "base64": data.base64EncodedString()],
			                                              in: nil, contentWorld: .page) as? String
			toast = (r ?? "").isEmpty ? "This page has no place for a .\(file.pathExtension) file."
				: "\(file.lastPathComponent) handed to the page."
		} catch {
			toast = "Could not hand \(file.lastPathComponent) over: \(error.localizedDescription)"
		}
	}

	// MARK: navigation

	func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
		guard let url = action.request.url else { return .cancel }
		// a file the page saves (<a download>, as Baud Girl's installer saves a backup of the presets): kept in the
		// library rather than shown in place of the page
		if action.shouldPerformDownload { return .download }
		let main = action.targetFrame?.isMainFrame ?? true
		if !main { return .allow }                               // (frames inside a page: the page's own business)
		if !Site.opensInApp(url) {                                // other sites, mail, the App Store: not here
			await UIApplication.shared.open(url)
			return .cancel
		}
		if pageBusy, action.navigationType == .linkActivated {
			toast = "An install is running: links wait until it is done."
			return .cancel
		}
		return .allow
	}

	func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
		response.canShowMIMEType ? .allow : .download
	}

	func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
	func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

	func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
		let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
		let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
		var url = downloads.appendingPathComponent(name), n = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
		}
		pendingDownload = url.lastPathComponent
		return url
	}

	func downloadDidFinish(_ download: WKDownload) {
		toast = "Saved \(pendingDownload ?? "the file") in the library (Files › FM-1 Manager)."
	}

	func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
		toast = "The download did not finish: \(error.localizedDescription)"
	}

	private var pendingDownload: String?

	func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loadError = nil }
	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		#if DEBUG
		if !hasLoaded, let sel = DemoMode.value("-FM1Click") {          // (the screenshots: an installer's Connect)
			Task { [weak self] in
				try? await Task.sleep(nanoseconds: 1_500_000_000)
				_ = try? await self?.webView.callAsyncJavaScript("const e = document.querySelector(s); if (e) e.click()",
				                                                arguments: ["s": sel], in: nil, contentWorld: .page)
			}
		}
		#endif
		if !hasLoaded, let f = afterFirstLoad { afterFirstLoad = nil; Task { @MainActor in f(self) } }
		hasLoaded = true
	}

	/// Runs a script in the page and gives back what it returned (nil on an error).
	func run(_ js: String) async -> Any? {
		try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		failed(error)
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

	private func failed(_ error: Error) {
		let e = error as NSError
		if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
		if e.domain == "WebKitErrorDomain" && e.code == 102 { return }   // (a navigation handed to Safari)
		loadError = e.localizedDescription
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		loadError = "The page stopped (its web process ended). Reload it."
	}

	/// target=_blank: the sites' pages open here, everything else in Safari.
	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
	             for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		if let url = action.request.url {
			if Site.opensInApp(url) { webView.load(action.request) } else { UIApplication.shared.open(url) }
		}
		return nil
	}

	// MARK: dialogs

	func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
	             completionHandler: @escaping @MainActor @Sendable () -> Void) {
		dialog = PageDialog(kind: .alert, message: message, text: "") { _, _ in completionHandler() }
	}

	func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
	             completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
		dialog = PageDialog(kind: .confirm, message: message, text: "") { ok, _ in completionHandler(ok) }
	}

	func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
	             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
		dialog = PageDialog(kind: .prompt, message: prompt, text: defaultText ?? "") { ok, text in completionHandler(ok ? text : nil) }
	}
}
