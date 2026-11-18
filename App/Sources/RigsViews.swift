// SPDX-License-Identifier: GPL-3.0-only
#if FM1_DOCK
import FM1Kit
import Observation
import SwiftUI
import WebKit

// MARK: the rigs on the phone

/// The rigs: one JSON file each in Documents/Rigs/ (Files shows it; a backup keeps it; it can be shared).
@MainActor @Observable
final class RigStore {
	let folder: URL
	private(set) var rigs: [Rig] = []
	private var files: [UUID: URL] = [:]
	var lastError: String?
	/// The measured speed of a deploy (bytes a second), for the plan's time; a guess until the first one.
	var bytesPerSecond: Double {
		get { UserDefaults.standard.double(forKey: "rigs.bytesPerSecond").nonZero ?? 6000 }
		set { UserDefaults.standard.set(newValue, forKey: "rigs.bytesPerSecond") }
	}

	init(documents: URL) {
		folder = documents.appendingPathComponent("Rigs", isDirectory: true)
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		refresh()
	}

	func refresh() {
		let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
		var out: [Rig] = [], map: [UUID: URL] = [:]
		for u in urls where u.lastPathComponent.hasSuffix(Rig.fileSuffix) {
			guard let data = try? Data(contentsOf: u), let r = try? Rig.decode(data) else { continue }
			if map[r.id] != nil { continue }                     // (a copy made in Files: the first one counts)
			out.append(r); map[r.id] = u
		}
		rigs = out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		files = map
	}

	func url(of rig: Rig) -> URL? { files[rig.id] }

	func save(_ rig: Rig) {
		var r = rig
		r.modified = Date()
		let safe = r.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
		let url = folder.appendingPathComponent((safe.isEmpty ? "Rig" : safe) + Rig.fileSuffix)
		do {
			if let old = files[r.id], old != url { try? FileManager.default.removeItem(at: old) }
			if FileManager.default.fileExists(atPath: url.path), files[r.id] != url {
				throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "A rig named \(r.name) is already there."])
			}
			try r.encoded().write(to: url, options: .atomic)
		} catch { lastError = error.localizedDescription }
		refresh()
	}

	func delete(_ rig: Rig) {
		if let u = files[rig.id] { try? FileManager.default.removeItem(at: u) }
		refresh()
	}

	func duplicate(_ rig: Rig) {
		var name = rig.name + " copy", n = 2
		while rigs.contains(where: { $0.name == name }) { name = "\(rig.name) copy \(n)"; n += 1 }
		save(Rig(name: name, color: rig.color, symbol: rig.symbol, modules: rig.modules, select: rig.select, firmware: rig.firmware))
	}
}

private extension Double { var nonZero: Double? { self > 0 ? self : nil } }

extension Rig {
	var tint: Color {
		switch color {
		case "red": .red
		case "pink": .pink
		case "purple": .purple
		case "blue": .blue
		case "teal": .teal
		case "green": .green
		case "yellow": .yellow
		case "gray": .gray
		default: .orange
		}
	}
}

func kib(_ n: Int) -> String { "\(Int((Double(n) / 1024).rounded())) KiB" }

/// fm1-dock's own deploy area on an FM-1 (dock.c DP_LO..DP_HI), for the editor's meter before any device was read.
let fm1Capacity = 296 * 1024

// MARK: the device link (a page nobody sees, in the window while a rig screen needs it)

@MainActor
final class RigLinkHost {
	static func make(_ app: AppModel) -> WebDockLink? {
		guard let engine = app.engine, let web = Bundle.main.url(forResource: "web", withExtension: nil) else { return nil }
		let link = WebDockLink(engine: engine, resolver: LocalSchemeHandler.site(root: web, library: app.library.folder))
		link.webView.alpha = 0.01
		link.webView.isUserInteractionEnabled = false
		let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
		window?.addSubview(link.webView)
		return link
	}
	static func close(_ link: WebDockLink?) {
		link?.close()
		link?.webView.removeFromSuperview()
	}
}

// MARK: home: the grid

struct RigsRows: View {
	@Environment(AppModel.self) private var app
	@Binding var path: [Route]
	@State private var editing: Rig?
	@State private var capturing = false

	/// The rows of Rigs, inside the home screen's Experimental section.
	var body: some View {
		Group {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("Rigs")
					Text("Sets of fm1-dock modules, put on the FM-1 in one go. Tested against a simulated FM-1 only: check “Save what's on my FM-1” first.")
						.font(.caption).foregroundStyle(.secondary)
				}
			} icon: { Image(systemName: "square.stack") }
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
				ForEach(app.rigs.rigs) { rig in
					Button { path.append(.rig(rig.id)) } label: { RigCard(rig: rig) }.buttonStyle(.plain)
				}
				Button { editing = Rig(name: "New rig") } label: {
					VStack { Image(systemName: "plus").font(.title2); Text("New rig").font(.subheadline) }
						.frame(maxWidth: .infinity, minHeight: 92)
						.background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
				}.buttonStyle(.plain)
			}
			.padding(.vertical, 4)
			Button { capturing = true } label: { Label("Save what's on my FM-1 as a rig", systemImage: "square.and.arrow.down.on.square") }
				.disabled(app.fm1 == nil)
			NavigationLink(value: Route.catalogue) { Label("Get modules from fm1-dock's catalogue", systemImage: "arrow.down.circle") }
		}
		.sheet(item: $editing) { RigEditor(rig: $0) }
		.sheet(isPresented: $capturing) { CaptureView() }
	}
}

struct RigCard: View {
	let rig: Rig
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Image(systemName: rig.symbol).font(.title2).foregroundStyle(rig.tint)
			Text(rig.name).font(.headline).lineLimit(1)
			Text("\(rig.modules.count) modules · \(kib(rig.footprint))").font(.caption).foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
		.padding(10)
		.background(rig.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
		.overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(rig.tint.opacity(0.5)))
		.accessibilityElement(children: .combine)
	}
}

// MARK: a rig

struct RigDetailView: View {
	let id: UUID
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var editing: Rig?
	@State private var applying = false
	@State private var confirmDelete = false

	var body: some View {
		if let rig = app.rigs.rigs.first(where: { $0.id == id }) {
			let lib = LibraryModule.scan(app.library.folder)
			List {
				Section {
					Button { applying = true } label: { Label("Put it on the FM-1…", systemImage: "arrow.down.to.line") }
						.font(.headline).disabled(app.fm1 == nil)
					if app.fm1 == nil { Text("Plug in the FM-1 to apply it.").font(.footnote).foregroundStyle(.secondary) }
				}
				Section {
					SizeMeter(used: rig.footprint, capacity: fm1Capacity)
					ForEach(rig.modules, id: \.name) { m in
						HStack {
							VStack(alignment: .leading) {
								Text(m.name + (rig.select == m.name ? "  ▶︎" : ""))
								Text("v\(m.version) · \(kib(m.footprint))").font(.caption).foregroundStyle(.secondary)
							}
							Spacer()
							status(m, lib)
						}
					}
				} header: { Text("Modules, in order") }
				if let fw = rig.firmware {
					Section("Firmware") { Text("Expects \(fw.product)" + (fw.file.map { " (\($0))" } ?? "")) }
				}
				Section {
					Button("Edit") { editing = rig }
					Button("Duplicate") { app.rigs.duplicate(rig) }
					if let url = app.rigs.url(of: rig) { ShareLink("Share the rig file", item: url) }
					Button("Delete", role: .destructive) { confirmDelete = true }
				}
			}
			.navigationTitle(rig.name)
			.sheet(item: $editing) { RigEditor(rig: $0) }
			.sheet(isPresented: $applying) { ApplyView(rig: rig) }
			#if DEBUG
			.task { if DemoMode.value("-FM1Open") == "plan" { try? await Task.sleep(nanoseconds: 800_000_000); applying = true } }
			#endif
			.confirmationDialog("Delete \(rig.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
				Button("Delete the rig", role: .destructive) { app.rigs.delete(rig); dismiss() }
			} message: { Text("Only the rig: the modules stay in the library and on the FM-1.") }
		} else {
			ContentUnavailableView("No such rig", systemImage: "questionmark")
		}
	}

	@ViewBuilder
	private func status(_ m: RigModule, _ lib: [LibraryModule]) -> some View {
		if lib.contains(where: { CRC32.hex($0.header.crc32) == m.crc32.lowercased() }) {
			Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityLabel("In the library")
		} else if lib.contains(where: { $0.header.name == m.name }) {
			Text("library has another version").font(.caption).foregroundStyle(.orange)
		} else {
			Text("not in your library").font(.caption).foregroundStyle(.red)
		}
	}
}

struct SizeMeter: View {
	let used: Int
	let capacity: Int
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			ProgressView(value: Double(min(used, capacity)), total: Double(capacity)).tint(used > capacity ? .red : .accentColor)
			Text(used > capacity ? "Over by \(kib(used - capacity)) (\(kib(used)) of \(kib(capacity)))"
			                     : "Fits: \(kib(used)) of \(kib(capacity)), \(kib(capacity - used)) left")
				.font(.caption).foregroundStyle(used > capacity ? .red : .secondary)
		}
	}
}

// MARK: making and changing a rig

struct RigEditor: View {
	@State var rig: Rig
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	static let symbols = ["pianokeys", "waveform", "music.note", "sparkles", "bolt", "moon.stars", "flame", "leaf", "drop", "cloud", "guitars", "metronome"]

	var body: some View {
		let lib = LibraryModule.scan(app.library.folder)
		NavigationStack {
			Form {
				Section {
					TextField("Name", text: $rig.name)
					Picker("Colour", selection: $rig.color) { ForEach(Rig.colors, id: \.self) { Text($0.capitalized).tag($0) } }
					Picker("Symbol", selection: $rig.symbol) { ForEach(Self.symbols, id: \.self) { Label($0, systemImage: $0).tag($0) } }
				}
				Section {
					SizeMeter(used: rig.footprint, capacity: fm1Capacity)
					ForEach(rig.modules, id: \.name) { m in
						LabeledContent(m.name) { Text(kib(m.footprint)) }
					}
					.onMove { rig.modules.move(fromOffsets: $0, toOffset: $1) }
					.onDelete { rig.modules.remove(atOffsets: $0) }
					if !rig.modules.isEmpty {
						Picker("Playing at the end", selection: $rig.select) {
							Text("Whatever the FM-1 picks").tag(String?.none)
							ForEach(rig.modules, id: \.name) { Text($0.name).tag(Optional($0.name)) }
						}
					}
				} header: { Text("In the rig") } footer: {
					Text("The FM-1 has \(kib(fm1Capacity)) for added modules; each takes whole 4 KiB sectors.")
				}
				Section("Add from the library") {
					let inRig = Set(rig.modules.map(\.name))
					let choices = lib.filter { !inRig.contains($0.header.name) && !$0.header.isProbe && !$0.header.isBoot }
					if choices.isEmpty { Text("No other modules in the library: get some from the catalogue or Files.").foregroundStyle(.secondary) }
					ForEach(choices, id: \.fileName) { f in
						Button {
							rig.modules.append(RigModule(f.header, file: f.fileName))
							if rig.select == nil { rig.select = f.header.name }
						} label: {
							HStack {
								VStack(alignment: .leading) {
									Text(f.header.name)
									Text("\(f.fileName) · v\(f.header.version)").font(.caption).foregroundStyle(.secondary)
								}
								Spacer()
								Text(kib(f.header.footprint)).foregroundStyle(.secondary)
								Image(systemName: "plus.circle")
							}
						}
					}
				}
			}
			.environment(\.editMode, .constant(.active))
			.navigationTitle(app.rigs.rigs.contains { $0.id == rig.id } ? "Edit rig" : "New rig")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") { app.rigs.save(rig); dismiss() }.disabled(rig.name.trimmingCharacters(in: .whitespaces).isEmpty)
				}
			}
		}
	}
}

// MARK: "Save what's on my FM-1"

struct CaptureView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var link: WebDockLink?
	@State private var state: DockDeviceState?
	@State private var error: String?
	@State private var rig: Rig?
	@State private var missing: [String] = []
	@State private var catalogue: [CatalogueEntry] = []
	@State private var fetching: String?

	var body: some View {
		NavigationStack {
			Form {
				if let error { Text(error).foregroundStyle(.red) }
				if let s = state, let r = rig {
					Section {
						TextField("Name", text: Binding(get: { rig?.name ?? "" }, set: { rig?.name = $0 }))
						LabeledContent("Firmware", value: s.identity ?? "?")
						DeviceRoom(state: s, library: LibraryModule.scan(app.library.folder))
					}
					Section("On the FM-1") {
						ForEach(r.modules, id: \.name) { m in
							HStack {
								Text(m.name)
								Spacer()
								if missing.contains(m.name) {
									if let e = catalogue.first(where: { $0.name == m.name }) {
										Button(fetching == e.id ? "Getting…" : "Get from catalogue") { Task { await get(e) } }
											.disabled(fetching != nil)
									} else { Text("not in your library").font(.caption).foregroundStyle(.red) }
								} else { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
							}
						}
						if r.modules.isEmpty { Text("No added modules: only the firmware's own.").foregroundStyle(.secondary) }
					}
					if !missing.isEmpty {
						Section {
							Text("\(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") not in your library: the FM-1 cannot give a module back, so the rig keeps \(missing.count == 1 ? "it" : "them") only while \(missing.count == 1 ? "it stays" : "they stay") on the FM-1.")
								.font(.footnote)
						}
					}
				} else if error == nil {
					HStack { ProgressView(); Text("Reading the FM-1…") }
				}
			}
			.navigationTitle("Save as a rig")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") { if let rig { app.rigs.save(rig) }; dismiss() }.disabled(rig == nil)
				}
			}
			.task { await read() }
			.onDisappear { RigLinkHost.close(link) }
		}
	}

	private func read() async {
		if link == nil { link = RigLinkHost.make(app) }
		guard let link else { error = "MIDI is not available."; return }
		do {
			let s = try await link.readState()               // (read only: nothing is sent that changes the FM-1)
			state = s
			let lib = LibraryModule.scan(app.library.folder)
			let (r, miss) = RigCapture.rig(named: rig?.name ?? "On my FM-1 \(Date().formatted(date: .abbreviated, time: .omitted))",
			                              from: s, library: lib)
			rig = r; missing = miss
			if !miss.isEmpty, catalogue.isEmpty { catalogue = (try? await ModuleCatalogue.fetch()) ?? [] }
		} catch { self.error = "\(error)" }
	}

	private func get(_ e: CatalogueEntry) async {
		fetching = e.id
		defer { fetching = nil }
		do {
			_ = try await ModuleCatalogue.download(e, into: app.library.folder)
			app.library.refresh()
			if let s = state {
				let (r, miss) = RigCapture.rig(named: rig?.name ?? "", from: s, library: LibraryModule.scan(app.library.folder))
				rig = r; missing = miss
			}
		} catch { self.error = "\(error)" }
	}
}

/// The device's room as it reports it, beside the app's model of it (they must agree before Apply is trusted).
struct DeviceRoom: View {
	let state: DockDeviceState
	let library: [LibraryModule]
	var body: some View {
		let m = RigPlanner.layout(of: state, library: library)
		VStack(alignment: .leading, spacing: 2) {
			LabeledContent("Free for modules", value: "\(kib(state.free)), largest piece \(kib(state.largest))")
			Text(m.exact ? "The app's model of the area agrees (\(kib(m.layout.free)) free, \(kib(m.layout.largest)) largest)."
			             : "The app's model says \(kib(m.layout.free)) free, \(kib(m.layout.largest)) largest: not exactly the FM-1's.")
				.font(.caption).foregroundStyle(m.exact ? Color.secondary : Color.orange)
		}
	}
}

// MARK: Apply: read, plan, confirm, run, verify; Resume after a stop

struct ApplyView: View {
	let rig: Rig
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	enum Phase { case reading, planned(DockDeviceState, RigPlan), refused(DockDeviceState?, String, RigPlanProblem?), running, finished(DockDeviceState, [String]), stopped(String, DockDeviceState?, [RigPlan.Step]) }
	@State private var phase: Phase = .reading
	@State private var link: WebDockLink?
	@State private var applier: RigApplier?
	@State private var progress: RigApplier.Progress?
	@State private var accepted: Set<String> = []
	@State private var confirming = false

	var body: some View {
		NavigationStack {
			Form { content }
				.navigationTitle(rig.name)
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						if case .running = phase { Button("Stop after this step") { applier?.cancel() } } else { Button("Close") { dismiss() } }
					}
				}
				.interactiveDismissDisabled({ if case .running = phase { true } else { false } }())
				.warnsAboutWrites()
				.task { await read() }
				.onDisappear { RigLinkHost.close(link); UIApplication.shared.isIdleTimerDisabled = false }
		}
	}

	@ViewBuilder private var content: some View {
		switch phase {
		case .reading:
			HStack { ProgressView(); Text("Reading the FM-1…") }
		case let .refused(s, why, problem):
			Section { Text(why) }
			if case .firmware = problem {
				Section {
					Text("Install the firmware first, then come back.").font(.footnote)
					Button("Open Install from Library") { dismiss(); app.requestedRoute = .site(.local) }
					Button("Open the Firmware Hub") { dismiss(); app.requestedRoute = .site(.hub) }
				}
			}
			if let s { Section { DeviceRoom(state: s, library: LibraryModule.scan(app.library.folder)) } }
			Button("Read again") { Task { await read() } }
		case let .planned(s, plan):
			planView(s, plan)
		case .running:
			if let p = progress {
				Section {
					Text("Step \(p.step + 1) of \(p.steps): \(p.text)")
					ProgressView(value: (Double(p.step) + p.fraction) / Double(max(1, p.steps)))
					Text("Keep the app open and the FM-1 plugged in.").font(.footnote).foregroundStyle(.secondary)
				}
			} else { ProgressView() }
		case let .finished(s, issues):
			Section {
				Label(issues.isEmpty ? "Done: the FM-1 has the rig, checked." : "Done, but the FM-1 shows:",
				      systemImage: issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle")
					.foregroundStyle(issues.isEmpty ? .green : .orange)
				ForEach(issues, id: \.self) { Text($0).font(.footnote) }
			}
			Section("On the FM-1 now") { deviceList(s) }
		case let .stopped(reason, s, done):
			Section {
				Label("Stopped", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
				Text(reason).font(.footnote)
				if !done.isEmpty { Text("Done before it: \(done.map(stepText).joined(separator: "; ")).").font(.footnote) }
			}
			Section("On the FM-1 now") {
				if let s { deviceList(s) } else { Text("The FM-1 did not answer (unplugged?). Plug it in, then Resume.").font(.footnote) }
			}
			if let s, case let .success(rest) = RigPlanner.plan(rig: rig, device: s, library: LibraryModule.scan(app.library.folder)) {
				Section("Still to do") {
					if rest.changesNothing { Text("Nothing: the FM-1 has the rig.") }
					ForEach(Array(rest.steps.enumerated()), id: \.offset) { Text(stepText($0.element)).font(.footnote) }
				}
			}
			Button("Resume") { Task { await read() } }.font(.headline)
		}
	}

	private func deviceList(_ s: DockDeviceState) -> some View {
		ForEach(s.modules.filter { $0.kind == .deployed || $0.index == s.current }, id: \.index) { m in
			LabeledContent(m.name + (m.index == s.current ? "  ▶︎" : ""), value: m.kind == .deployed ? "added" : m.kind.rawValue)
		}
	}

	private func stepText(_ s: RigPlan.Step) -> String {
		switch s {
		case let .delete(n, _): "remove \(n)"
		case let .deploy(m, _): "add \(m.name)"
		case let .select(n): "select \(n)"
		}
	}

	@ViewBuilder
	private func planView(_ s: DockDeviceState, _ plan: RigPlan) -> some View {
		if plan.changesNothing {
			Section { Label("The FM-1 already has this rig.", systemImage: "checkmark.seal").foregroundStyle(.green) }
		} else {
			Section("The plan") {
				ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
					switch step {
					case let .delete(n, ok): Label("Remove \(n)" + (ok ? "" : " (not in your library)"), systemImage: "minus.circle").foregroundStyle(ok ? Color.primary : .red)
					case let .deploy(m, _): Label("Add \(m.name), \(kib(m.fileSize))", systemImage: "plus.circle")
					case let .select(n): Label("Play \(n)", systemImage: "play.circle")
					}
				}
				if !plan.kept.isEmpty { Text("Left as they are: \(plan.kept.joined(separator: ", "))").font(.footnote) }
				if !plan.inPackage.isEmpty { Text("In the firmware already: \(plan.inPackage.joined(separator: ", "))").font(.footnote) }
				if !plan.relocated.isEmpty { Text("Taken off and put back to make room: \(plan.relocated.joined(separator: ", "))").font(.footnote) }
				Text("About \(Int(plan.estimatedSeconds(bytesPerSecond: app.rigs.bytesPerSecond).rounded())) s, \(kib(plan.bytesToSend)) to send.")
					.font(.footnote).foregroundStyle(.secondary)
			}
			if !plan.unrestorable.isEmpty {
				Section {
					ForEach(plan.unrestorable, id: \.self) { n in
						Toggle("Delete \(n): it cannot be put back", isOn: Binding(get: { accepted.contains(n) },
						                                                             set: { if $0 { accepted.insert(n) } else { accepted.remove(n) } }))
					}
				} header: { Text("Not in your library") } footer: {
					Text("The FM-1 cannot give a module back to the phone. Get it from the catalogue or Files first if you want it again.")
				}
			}
			Section {
				Text("A module's settings and presets stay in the FM-1 when it is removed and come back with it, unless another module needed their place meanwhile (fm1-dock keeps 8 settings records and 9 preset banks). Nothing here can copy them to the phone.")
					.font(.footnote).foregroundStyle(.secondary)
				ForEach(plan.notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
			}
			Button("Apply…") { confirming = true }
				.font(.headline)
				.disabled(!Set(plan.unrestorable).isSubset(of: accepted))
				.confirmationDialog("Change the FM-1 now?", isPresented: $confirming, titleVisibility: .visible) {
					Button("Apply \(plan.steps.count) steps") { Task { await run(plan) } }
				} message: { Text(plan.deletes.isEmpty ? "Modules are added; nothing is removed." : "Removes \(plan.deletes.joined(separator: ", ")).") }
		}
		Section { DeviceRoom(state: s, library: LibraryModule.scan(app.library.folder)) }
	}

	private func read() async {
		phase = .reading
		if link == nil { link = RigLinkHost.make(app) }
		guard let link else { phase = .refused(nil, "MIDI is not available.", nil); return }
		do {
			let s = try await RigApplier.readForPlanning(link)
			switch RigPlanner.plan(rig: rig, device: s, library: LibraryModule.scan(app.library.folder)) {
			case let .success(p): phase = .planned(s, p)
			case let .failure(problem): phase = .refused(s, problem.description, problem)
			}
		} catch { phase = .refused(nil, "\(error)", nil) }
	}

	private func run(_ plan: RigPlan) async {
		guard let link else { return }
		let a = RigApplier(link: link, libraryFolder: app.library.folder)
		applier = a
		phase = .running
		UIApplication.shared.isIdleTimerDisabled = true
		defer { UIApplication.shared.isIdleTimerDisabled = false }
		let out = await a.run(plan, rig: rig, library: LibraryModule.scan(app.library.folder)) { progress = $0 }
		switch out {
		case let .finished(s, issues, rate):
			if let rate { app.rigs.bytesPerSecond = rate }
			phase = .finished(s, issues)
		case let .stopped(reason, _, s, done):
			phase = .stopped(reason, s, done)
		}
	}
}

// MARK: the catalogue

struct CatalogueView: View {
	@Environment(AppModel.self) private var app
	@State private var entries: [CatalogueEntry] = []
	@State private var error: String?
	@State private var loading = false
	@State private var getting: Set<String> = []

	var body: some View {
		List {
			Section {
				if loading { HStack { ProgressView(); Text("Asking fm1-dock's site…") } }
				if let error { Text(error).foregroundStyle(.red) }
				if entries.isEmpty && !loading && error == nil { Button("Load the catalogue") { Task { await load() } } }
			} footer: {
				Text("From joakimeriksson.github.io/fm1-dock, only when you ask. Each file is checked against the SHA-256 the site publishes, and its header against its name and ABI.")
			}
			ForEach(entries) { e in
				let have = app.library.files.contains { $0.lastPathComponent == e.file }
				HStack {
					VStack(alignment: .leading) {
						Text(e.title ?? e.name)
						Text([e.by, "v\(e.version)", kib(e.size), "takes \(kib(DockModuleFile.sectors(e.size)))"].compactMap { $0 }.joined(separator: " · "))
							.font(.caption).foregroundStyle(.secondary)
					}
					Spacer()
					if have { Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityLabel("In the library") }
					else if getting.contains(e.id) { ProgressView() }
					else { Button("Get") { Task { await get(e) } }.buttonStyle(.bordered) }
				}
			}
		}
		.navigationTitle("Module catalogue")
		.refreshable { await load() }
	}

	private func load() async {
		loading = true; error = nil
		defer { loading = false }
		do { entries = try await ModuleCatalogue.fetch() } catch { self.error = "Could not load the catalogue: \(error.localizedDescription)" }
	}

	private func get(_ e: CatalogueEntry) async {
		getting.insert(e.id)
		defer { getting.remove(e.id) }
		do { _ = try await ModuleCatalogue.download(e, into: app.library.folder); app.library.refresh() }
		catch { self.error = "\(e.file): \(error)" }
	}
}
#endif
