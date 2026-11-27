// SPDX-License-Identifier: GPL-3.0-only
import CoreAudioKit
import FM1Kit
import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
	case site(Site), library, hands
	#if FM1_DOCK
	case rig(UUID), catalogue
	#endif
}

struct HomeView: View {
	@Environment(AppModel.self) private var app
	@Binding var path: [Route]
	@State private var showBluetooth = false
	@State private var showAbout = false

	var body: some View {
		@Bindable var app = app
		ScrollViewReader { scroll in
			List {
				Section {
					DeviceStatus()
				}
				Section("Install") {
					ForEach(Site.all) { site in
						if case let .shown(note) = visibility(site) {
							NavigationLink(value: Route.site(site)) {
								Label {
									VStack(alignment: .leading) {
										Text(site.title)
										Text(site.detail + (note.map { "; \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
									}
								} icon: { Image(systemName: site.symbol) }
							}
						}
					}
				}
				#if FM1_DOCK
				Section {
					NavigationLink(value: Route.library) {
						LabeledContent("Library") { Text("\(app.library.files.count) files") }
					}
				} footer: {
					Text("Your .fwsc and .dock files. Add them here, from Files (On My iPhone › FM-1 Manager), or with Share › FM-1 Manager in Safari or Mail.")
				}
				#endif
				Section {
					#if FM1_DOCK
					RigsRows(path: $path)
					#endif
					NavigationLink(value: Route.hands) {
						Label {
							VStack(alignment: .leading, spacing: 2) {
								Text("Hands")
								Text("Unfinished: a touch keyboard, XY pad and tilt that play the FM-1.").font(.caption).foregroundStyle(.secondary)
							}
						} icon: { Image(systemName: "hand.raised.fingers.spread") }
					}
					GarageBandRow()
				} header: {
					Text("Experimental")
				} footer: {
					Text("These are new and may change or misbehave.")
				}
				Section {
					Picker("My FM-1's flash chip", selection: Binding(get: { app.chip.answer ?? .unsure }, set: { app.chip.say($0) })) {
						Text("Newer (logo under the screen)").tag(FlashChip.newer)
						Text("Older").tag(FlashChip.older)
						Text("Not sure").tag(FlashChip.unsure)
					}
					if app.chip.chip == .newer {
						Toggle("Firmware Hub: only firmwares that save on newer FM-1s", isOn: $app.chip.filterHub)
					}
					NavigationLink("Known problems") { KnownProblemsView() }
					AppIconPicker().id("appIcon")
					Picker("MIDI packets", selection: $app.packetAPI) {
						Text("Universal (UMP)").tag(MIDIEngine.PacketAPI.universal)
						Text("Legacy packet lists").tag(MIDIEngine.PacketAPI.legacy)
					}
					Button("Bluetooth MIDI…") { showBluetooth = true }
					Button("About, privacy and support") { showAbout = true }
				} header: {
					Text("Settings")
				} footer: {
					Text(chipFooter + " Both MIDI APIs reach the same pages; switch only if an install misbehaves. Bluetooth MIDI is untested for installs: use USB.")
				}
			}
			.navigationTitle("FM-1 Manager")
			#if FM1_DOCK
			.task(id: app.fm1?.id) { await app.detectChip() }
			#endif
			.onAppear {
				app.library.refresh()
				#if DEBUG
				// screenshots (simctl cannot scroll): launch with -FM1ShowAppIcons to open on the icon chooser
				if ProcessInfo.processInfo.arguments.contains("-FM1ShowAppIcons") { scroll.scrollTo("appIcon", anchor: .center) }
				#endif
			}
		}
		.sheet(isPresented: $showBluetooth) { BluetoothMIDIView().ignoresSafeArea() }
		.sheet(isPresented: $showAbout) { AboutView() }
	}
}

extension HomeView {
	/// Baud Girl (FM-1+VA) does not say whether it supports the newer flash chip: shown, with a note.
	func visibility(_ site: Site) -> InstallerVisibility {
		site.id == Site.baudGirl.id ? InstallerVisibility.of(support: .unknown, chip: app.chip.chip) : .shown(note: nil)
	}

	var chipFooter: String {
		if app.chip.wasDetected, let id = app.chip.detectedID {
			return "Flash chip \(id), read from fm1-dock\(app.chip.detectedAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")."
		}
		return "The flash chip is read from fm1-dock 0.8 or later when it is plugged in; otherwise say which here (newer FM-1s have the logo under the screen)."
	}
}

/// The app icon colours: the primary icon (nil, terracotta) and the alternate icon sets in Assets.xcassets,
/// all drawn by ios/icons/src/render.swift. The names must match ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES (a test checks).
struct AppIconChoice: Identifiable, Hashable {
	let name: String?, label: String, preview: String
	var id: String { preview }
	static let all: [AppIconChoice] = [
		.init(name: nil, label: "Terracotta", preview: "IconPreview-terracotta"),
		.init(name: "AppIcon-Black", label: "Black", preview: "IconPreview-black"),
		.init(name: "AppIcon-BlackGreen", label: "Black & green", preview: "IconPreview-blackgreen"),
		.init(name: "AppIcon-GreyBlack", label: "Grey & black", preview: "IconPreview-greyblack"),
		.init(name: "AppIcon-GreyBlue", label: "Grey & blue", preview: "IconPreview-greyblue"),
		.init(name: "AppIcon-WhiteGrey", label: "White & grey", preview: "IconPreview-whitegrey"),
		.init(name: "AppIcon-WhiteGreen", label: "White & green", preview: "IconPreview-whitegreen"),
		.init(name: "AppIcon-Purple", label: "Purple", preview: "IconPreview-purple"),
	]
}

/// "App icon" in Settings: the colours as tappable icons, the current one ringed. Match your FM-1.
struct AppIconPicker: View {
	@State private var current = UIApplication.shared.alternateIconName
	@State private var error: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			LabeledContent("App icon") {
				Text(AppIconChoice.all.first { $0.name == current }?.label ?? "Terracotta")
			}
			LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
				ForEach(AppIconChoice.all) { choice in
					let selected = choice.name == current
					Button { choose(choice) } label: {
						Image(choice.preview)
							.resizable()
							.aspectRatio(1, contentMode: .fit)
							.frame(maxWidth: 60)
							.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
							.padding(3)
							.overlay {
								RoundedRectangle(cornerRadius: 16, style: .continuous)
									.strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
							}
					}
					.buttonStyle(.plain)
					.accessibilityLabel(choice.label)
					.accessibilityAddTraits(selected ? .isSelected : [])
				}
			}
			.disabled(!UIApplication.shared.supportsAlternateIcons)
			if let error { Text(error).font(.caption).foregroundStyle(.red) }
		}
		.padding(.vertical, 4)
	}

	private func choose(_ choice: AppIconChoice) {
		guard choice.name != current, UIApplication.shared.supportsAlternateIcons else { return }
		let previous = current
		current = choice.name   // (the ring moves at once; iOS's own alert follows)
		Task {
			do {
				try await UIApplication.shared.setAlternateIconName(choice.name)
				error = nil
			} catch {
				current = previous
				self.error = error.localizedDescription
			}
		}
	}
}

/// Looping is GarageBand's: the FM-1 plays its instruments as a MIDI keyboard. GarageBand's URL scheme could not be
/// checked (its Info.plist is not available here), so this opens its App Store page (id408709785, checked: "GarageBand
/// App - App Store") instead. USB audio: fm1-dock's platform.c builds usb.c with FELUCCA_UAC 1 (a UAC1 input).
struct GarageBandRow: View {
	@Environment(\.openURL) private var openURL
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Label("Jam in GarageBand", systemImage: "waveform.badge.plus")
			#if FM1_DOCK
			Text("Put a rig on, then open GarageBand: with the FM-1 plugged in, its keys play GarageBand's instruments and GarageBand's loops record what you play.")
				.font(.caption).foregroundStyle(.secondary)
			Text("fm1-dock's firmware also declares a USB audio input (44.1 / 48 kHz), so GarageBand may record the FM-1's own sound over the same cable. Nobody has tried that yet.")
				.font(.caption).foregroundStyle(.secondary)
			#else
			Text("With the FM-1 plugged in, its keys play GarageBand's instruments and GarageBand's loops record what you play.")
				.font(.caption).foregroundStyle(.secondary)
			Text("Recording the FM-1's own sound over the cable needs a firmware with USB audio; whether yours has it, and whether GarageBand takes it, is untested.")
				.font(.caption).foregroundStyle(.secondary)
			#endif
			Button("GarageBand in the App Store") { openURL(URL(string: "https://apps.apple.com/app/garageband/id408709785")!) }
				.font(.caption.weight(.semibold))
		}
		.padding(.vertical, 2)
	}
}

struct DeviceStatus: View {
	@Environment(AppModel.self) private var app
	var body: some View {
		if let err = app.engineError {
			Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
		} else if let loader = app.fm1InUpdateMode {
			UpdateModeGuide(port: loader.name)
		} else if let fm1 = app.fm1 {
			Label {
				VStack(alignment: .leading) {
					Text("FM-1 connected").font(.headline)
					Text(fm1.name + (fm1.manufacturer.isEmpty ? "" : " · \(fm1.manufacturer)")).font(.caption).foregroundStyle(.secondary)
				}
			} icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
		} else {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text("No FM-1 connected").font(.headline)
					Text("Plug it in with a USB data cable and switch it on.").font(.caption).foregroundStyle(.secondary)
					if !app.otherDevices.isEmpty {
						Text("Other MIDI: \(app.otherDevices.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
					}
				}
			} icon: { Image(systemName: "cable.connector.slash").foregroundStyle(.red) }
		}
	}
}

struct LibraryView: View {
	@Environment(AppModel.self) private var app
	@State private var importing = false

	var body: some View {
		let lib = app.library
		List {
			if lib.files.isEmpty {
				ContentUnavailableView("No files yet", systemImage: "tray",
				                       description: Text("Import a .fwsc firmware or a .dock module, or share one to FM-1 Manager."))
			}
			ForEach(lib.files, id: \.self) { f in
				VStack(alignment: .leading) {
					Text(f.lastPathComponent)
					Text("\(Library.kind(f)) · \(ByteCountFormatter.string(fromByteCount: Int64(f.fileSize), countStyle: .file))")
						.font(.caption).foregroundStyle(.secondary)
				}
				.swipeActions { Button("Delete", role: .destructive) { lib.delete(f) } }
			}
		}
		.navigationTitle("Library")
		.toolbar { Button { importing = true } label: { Label("Import", systemImage: "plus") } }
		.fileImporter(isPresented: $importing, allowedContentTypes: [.fwsc, .dockModule, .data], allowsMultipleSelection: true) { r in
			if case let .success(urls) = r { lib.add(urls) }
		}
		.alert(lib.lastError ?? "", isPresented: Binding(get: { lib.lastError != nil }, set: { if !$0 { lib.lastError = nil } })) {}
		.refreshable { lib.refresh() }
		.onAppear { lib.refresh() }
	}
}

/// iOS's own Bluetooth MIDI pairing: a paired FM-1 then shows up as a MIDI port like the USB one.
struct BluetoothMIDIView: UIViewControllerRepresentable {
	func makeUIViewController(context: Context) -> UINavigationController {
		let vc = CABTMIDICentralViewController()
		let nav = UINavigationController(rootViewController: vc)
		vc.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
		return nav
	}
	func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
