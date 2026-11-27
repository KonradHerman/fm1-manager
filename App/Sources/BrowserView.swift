// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import SwiftUI
import WebKit

struct WebViewHost: UIViewRepresentable {
	let webView: WKWebView
	func makeUIView(context: Context) -> WKWebView { webView }
	func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Which MIDI device is attached: green with the FM-1's port name, red when there is none.
struct ConnectionPill: View {
	@Environment(AppModel.self) private var app
	var body: some View {
		HStack(spacing: 6) {
			Circle().fill(app.fm1 == nil ? Color.red : Color.green).frame(width: 8, height: 8)
			Text(app.fm1?.name ?? "No FM-1").font(.caption.weight(.semibold)).lineLimit(1)
		}
		.padding(.horizontal, 10).padding(.vertical, 5)
		.background(.thinMaterial, in: Capsule())
		.accessibilityElement(children: .combine)
		.accessibilityLabel(app.fm1.map { "Connected: \($0.name)" } ?? "No FM-1 connected")
	}
}

/// What to do when no FM-1 is plugged in.
struct NoDeviceBanner: View {
	@Environment(AppModel.self) private var app
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Label("No FM-1 connected", systemImage: "cable.connector.slash").font(.headline)
			Text("Plug the FM-1 into the iPhone with a USB-C data cable (on a Lightning iPhone: Apple's Lightning to USB 3 Camera Adapter, with power) and switch it on.")
				.font(.footnote)
			if !app.otherDevices.isEmpty {
				Text("MIDI devices here: \(app.otherDevices.joined(separator: ", "))").font(.footnote).foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(12)
		.background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
		.padding(.horizontal, 12).padding(.top, 6)
	}
}

struct BrowserView: View {
	let site: Site
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var page: WebPage?
	@State private var confirmLeave: (() -> Void)?
	@State private var showFiles = false

	var body: some View {
		Group {
			if let page {
				content(page)
			} else if let err = app.engineError {
				ContentUnavailableView("MIDI is not available", systemImage: "exclamationmark.triangle", description: Text(err))
			} else {
				ProgressView()
			}
		}
		.navigationBarBackButtonHidden(true)
		.warnsAboutWrites()
		.onAppear {
			if page == nil, let engine = app.engine { page = WebPage(site: site, engine: engine, library: app.library.folder) }
		}
	}

	@ViewBuilder
	private func content(_ page: WebPage) -> some View {
		@Bindable var page = page
		WebViewHost(webView: page.webView)
			.overlay {
				if let err = page.loadError, !page.hasLoaded {
					ContentUnavailableView {
						Label("\(site.title) did not load", systemImage: "wifi.exclamationmark")
					} description: {
						Text("\(err)\n\(site.url.scheme == "https" ? "This page comes from \(site.url.host ?? "the web"): the phone needs the internet for it." : "")")
					} actions: {
						Button("Try again") { page.goHome() }.buttonStyle(.borderedProminent)
					}
					.background(Color(.systemBackground))
				}
			}
			.ignoresSafeArea(edges: .bottom)
			.safeAreaInset(edge: .top, spacing: 0) {
				VStack(spacing: 0) {
					if app.fm1 == nil && !page.busy { NoDeviceBanner() }
					// the FM-1 in its update loader once the page's own install has stopped (during an install it
					// passes through update mode on purpose; the page says busy then)
					if let loader = app.fm1InUpdateMode, !page.pageBusy {
						UpdateModeGuide(port: loader.name, compact: true)
							.padding(12)
							.background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
							.padding(.horizontal, 12).padding(.top, 6)
					}
					// (only while the page itself says an install runs: plain SysEx traffic, a Connect, keeps the
					// screen awake but is no install)
					if page.pageBusy {
						Label("Installing: keep the app open and the FM-1 plugged in", systemImage: "bolt.horizontal.circle")
							.font(.footnote.weight(.semibold)).frame(maxWidth: .infinity)
							.padding(8).background(Color.orange.opacity(0.18))
					}
					if let err = page.loadError {
						HStack {
							Text(err).font(.footnote)
							Spacer()
							Button("Reload") { page.reload() }.font(.footnote.weight(.semibold))
						}
						.padding(10).background(Color.yellow.opacity(0.2))
					}
				}
			}
			.overlay(alignment: .bottom) {
				if let t = page.toast {
					Text(t).font(.footnote).padding(10).background(.regularMaterial, in: Capsule()).padding(.bottom, 24)
						.task(id: t) { try? await Task.sleep(nanoseconds: 3_000_000_000); page.toast = nil }
				}
			}
			.navigationTitle(page.title.isEmpty ? site.title : page.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItemGroup(placement: .topBarLeading) {
					Button { guarded(page) { page.close(); dismiss() } } label: { Image(systemName: "xmark") }
						.accessibilityLabel("Close")
					Button { guarded(page) { page.goBack() } } label: { Image(systemName: "chevron.backward") }
						.disabled(!page.canGoBack).accessibilityLabel("Back")
				}
				ToolbarItem(placement: .principal) { ConnectionPill() }
				ToolbarItemGroup(placement: .topBarTrailing) {
					#if FM1_DOCK
					Button { showFiles = true } label: { Image(systemName: "doc.badge.arrow.up") }
						.accessibilityLabel("Give the page a file from the library")
					#endif
					Button { guarded(page) { page.reload() } } label: {
						Image(systemName: page.isLoading ? "xmark.circle" : "arrow.clockwise")
					}
					.accessibilityLabel("Reload")
				}
			}
			.confirmationDialog("An install is running", isPresented: Binding(get: { confirmLeave != nil }, set: { if !$0 { confirmLeave = nil } }),
			                    titleVisibility: .visible) {
				Button("Leave anyway", role: .destructive) { confirmLeave?(); confirmLeave = nil }
				Button("Stay", role: .cancel) { confirmLeave = nil }
			} message: {
				Text("Leaving the page now stops it. The FM-1 then stays in update mode until the same firmware is installed again.")
			}
			.alert(page.dialog?.message ?? "", isPresented: Binding(get: { page.dialog != nil }, set: { _ in })) {
				if let d = page.dialog {
					if d.kind == .prompt { TextField("", text: Binding(get: { page.dialog?.text ?? "" }, set: { page.dialog?.text = $0 })) }
					if d.kind != .alert { Button("Cancel", role: .cancel) { answer(page, false) } }
					Button("OK") { answer(page, true) }
				}
			}
			#if FM1_DOCK
			.sheet(isPresented: $showFiles) { GiveFileSheet(page: page) }
			#endif
	}

	private func answer(_ page: WebPage, _ ok: Bool) {
		guard let d = page.dialog else { return }
		page.dialog = nil
		d.answer(ok, d.text)
	}

	private func guarded(_ page: WebPage, _ action: @escaping () -> Void) {
		if page.busy { confirmLeave = action } else { action() }
	}
}

#if FM1_DOCK
/// The library's files that this page's file inputs take; the one picked goes to the page as if chosen there.
struct GiveFileSheet: View {
	let page: WebPage
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var accepted: [String]?

	var body: some View {
		NavigationStack {
			List {
				let files = app.library.files.filter { f in
					guard let a = accepted else { return false }
					return a.contains("*") || a.contains("." + f.pathExtension.lowercased())
				}
				if accepted == nil {
					ProgressView()
				} else if accepted!.isEmpty {
					Text("This page has no file input. On fm1-dock's page, connect the console first (its Deploy takes a .dock); for firmware files use Install from Library.")
						.foregroundStyle(.secondary)
				} else if files.isEmpty {
					Text("No file in the library that this page takes (\(accepted!.joined(separator: ", "))).").foregroundStyle(.secondary)
				}
				ForEach(files, id: \.self) { f in
					Button {
						Task { await page.give(f); dismiss() }
					} label: {
						VStack(alignment: .leading) {
							Text(f.lastPathComponent)
							Text("\(Library.kind(f)) · \(ByteCountFormatter.string(fromByteCount: Int64(f.fileSize), countStyle: .file))")
								.font(.caption).foregroundStyle(.secondary)
						}
					}
				}
			}
			.navigationTitle("Give the page a file")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
			.task { app.library.refresh(); accepted = await page.acceptedExtensions() }
		}
		.presentationDetents([.medium, .large])
	}
}
#endif
