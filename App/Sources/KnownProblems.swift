// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import SwiftUI

/// Firmware problems known first-hand, from App/Resources/KnownProblems.json (bundled; nothing is fetched).
///
/// Format, version 1: { "format": "fm1-manager-known-problems", "version": 1, "problems": [ {
///   "id": stable, unique;  "firmware", "firmwareVersion": as its maker names them;  "source": where it was installed
///   from;  "chip": "newer" | "older" | "any": the FM-1s it was seen on;  "from": the firmware the FM-1 ran before;
///   "date": "YYYY-MM";  "summary": one sentence;  "details": what happened, only what was seen;  "recovery": how the
///   FM-1 was brought back;  "seen": how many units, first-hand or reported } ] }. Unknown keys are ignored.
struct KnownProblem: Codable, Identifiable, Hashable {
	let id: String
	let firmware: String
	let firmwareVersion: String
	let source: String
	let chip: FlashChip?
	let from: String?
	let date: String
	let summary: String
	let details: String
	let recovery: String
	let seen: String

	enum CodingKeys: String, CodingKey { case id, firmware, firmwareVersion, source, chip, from, date, summary, details, recovery, seen }
	init(from d: Decoder) throws {
		let c = try d.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id); firmware = try c.decode(String.self, forKey: .firmware)
		firmwareVersion = try c.decode(String.self, forKey: .firmwareVersion); source = try c.decode(String.self, forKey: .source)
		chip = FlashChip(rawValue: (try? c.decode(String.self, forKey: .chip)) ?? "")
		from = try? c.decode(String.self, forKey: .from); date = try c.decode(String.self, forKey: .date)
		summary = try c.decode(String.self, forKey: .summary); details = try c.decode(String.self, forKey: .details)
		recovery = try c.decode(String.self, forKey: .recovery); seen = try c.decode(String.self, forKey: .seen)
	}

	struct File: Codable { let format: String; let version: Int; let problems: [KnownProblem] }

	static func load(_ bundle: Bundle = .main) -> [KnownProblem] {
		guard let url = bundle.url(forResource: "KnownProblems", withExtension: "json"), let data = try? Data(contentsOf: url),
		      let f = try? JSONDecoder().decode(File.self, from: data), f.format == "fm1-manager-known-problems", f.version <= 1 else { return [] }
		return f.problems
	}
}

struct KnownProblemsView: View {
	@Environment(\.openURL) private var openURL
	private let problems = KnownProblem.load()
	var body: some View {
		List {
			Section {
				Text("Problems with particular firmwares that we have seen ourselves. A firmware not listed here is not known to be safe: this list is short because few installs have been tried from a phone.")
					.font(.footnote).foregroundStyle(.secondary)
			}
			ForEach(problems) { p in
				Section {
					Text(p.summary).font(.subheadline.weight(.semibold))
					Text(p.details).font(.footnote)
					LabeledContent("Recovered", value: p.recovery).font(.footnote)
					LabeledContent("Seen", value: "\(p.seen), \(p.date)").font(.footnote)
				} header: {
					Text("\(p.firmware) \(p.firmwareVersion), from the \(p.source)\(p.chip == .newer ? ", newer flash chip" : p.chip == .older ? ", older flash chip" : "")")
				}
			}
			Section { Button("Recovery notes") { openURL(Links.recovery) } }
		}
		.navigationTitle("Known problems")
		.navigationBarTitleDisplayMode(.inline)
	}
}

/// Which flash chip: asked once, plainly, when the app could not read it (or changed in Settings).
struct ChipQuestion: View {
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			VStack(alignment: .leading, spacing: 14) {
				Text("Which FM-1 do you have?").font(.title2.weight(.bold))
				Text("FM-1s sold from autumn 2026 have a newer flash chip. You can tell by the **M-VAVE logo under the screen**. Firmware written only for the older chip cannot save on a newer FM-1, and its updates can fail.")
				Text("The app reads the chip itself when your FM-1 runs fm1-dock 0.8 or later; otherwise it asks.").font(.footnote).foregroundStyle(.secondary)
				Spacer()
				Button { choose(.newer) } label: { Text("Newer: logo under the screen").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
				Button { choose(.older) } label: { Text("Older: no logo under the screen").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
				Button { choose(.unsure) } label: { Text("Not sure").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
			}
			.padding()
			.toolbar { Button("Later") { dismiss() } }
		}
		.presentationDetents([.medium, .large])
	}
	private func choose(_ c: FlashChip) { app.chip.say(c); dismiss() }
}

/// The slim bar over the Firmware Hub: what the app did with the Hub's own filter, or a caution.
struct HubChipBar: View {
	let mode: HubFilter.Mode
	let showAll: () -> Void
	@Binding var shownAll: Bool
	@State private var asking = false

	var body: some View {
		if mode == .caution || (mode == .filtered && !shownAll) {
			VStack(alignment: .leading, spacing: 4) {
				Text(mode == .filtered ? "Showing firmwares that save on newer FM-1s, going by their authors' own flags."
				                       : "Not sure which flash chip your FM-1 has? Some firmwares cannot save on newer FM-1s.")
					.font(.footnote)
				HStack(spacing: 16) {
					if mode == .filtered {
						Button("Show all") { shownAll = true; showAll() }
					} else {
						Button("Choose my FM-1") { asking = true }
					}
					NavigationLink("Known problems") { KnownProblemsView() }
				}
				.font(.footnote.weight(.semibold))
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 12).padding(.vertical, 8)
			.background(Color.accentColor.opacity(0.12))
			.sheet(isPresented: $asking) { ChipQuestion() }
		}
	}
}
