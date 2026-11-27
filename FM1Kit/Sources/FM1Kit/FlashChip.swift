// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Which flash chip an FM-1 has. Units sold from autumn 2026 (the logo under the screen) have a UCUN UC25HQ80
/// (JEDEC id B36014); earlier ones a Puya P25Q80 (856014). Firmware written only for the older chip cannot save on a
/// newer unit and can leave it refusing updates.
public enum FlashChip: String, Codable, CaseIterable, Sendable {
	case newer, older, unsure

	/// From the JEDEC id fm1-dock's INFO reports ("B36014", as dock.js formats it); nil for an id not known here.
	public static func from(jedec: String?) -> FlashChip? {
		switch jedec?.uppercased().trimmingCharacters(in: .whitespaces) {
		case "B36014": .newer
		case "856014": .older
		default: nil
		}
	}
}

/// What the app knows about the FM-1's chip: what the person said, and what fm1-dock last reported. A detection
/// overrides the remembered answer and becomes it (with two FM-1s on one phone, the last one detected counts).
public struct ChipKnowledge: Codable, Hashable, Sendable {
	/// The person's answer; nil until asked.
	public var answer: FlashChip?
	/// The last JEDEC id fm1-dock reported, and when.
	public var detectedID: String?
	public var detectedAt: Date?
	/// The Firmware Hub opens with its "Saves on newer FM-1s" filter on when the chip is newer (a setting).
	public var filterHub = true

	public init() {}

	public var chip: FlashChip? { answer }
	public var wasDetected: Bool { detectedID != nil && FlashChip.from(jedec: detectedID) == answer }
	/// Ask the person (once) when nothing is known.
	public var shouldAsk: Bool { answer == nil }

	public mutating func detected(_ jedec: String, at date: Date = Date()) {
		guard let c = FlashChip.from(jedec: jedec) else { return }
		answer = c; detectedID = jedec.uppercased(); detectedAt = date
	}

	public mutating func say(_ c: FlashChip) { answer = c }

	public static let key = "chip.knowledge"
	public static func load(_ d: UserDefaults = .standard) -> ChipKnowledge {
		guard let data = d.data(forKey: key), let k = try? JSONDecoder().decode(ChipKnowledge.self, from: data) else { return ChipKnowledge() }
		return k
	}
	public func save(_ d: UserDefaults = .standard) {
		if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
	}
}

/// The Firmware Hub's own "Saves on newer FM-1s" filter (its key `newchip`). The page selects a filter named in the
/// address's fragment when it loads (thefirmwarehub.com/#newchip, which its own FAQ links to) and keeps the choice
/// in its own storage; its filter panel has a checkbox per key (`#fpanel input[value=newchip]`) whose change
/// handler turns it off again. The app uses those two and nothing else.
public enum HubFilter {
	public static let key = "newchip"

	/// What the Hub bar says and whether the page opens filtered.
	public enum Mode: Equatable, Sendable {
		/// Newer chip, filter wanted: open with #newchip, say so, offer Show all.
		case filtered
		/// Not sure: no filter, a caution and a way to choose.
		case caution
		/// Older chip, or the filter turned off: nothing.
		case none
	}

	public static func mode(_ k: ChipKnowledge) -> Mode {
		switch k.chip {
		case .newer: k.filterHub ? .filtered : .none
		case .unsure, nil: .caution
		case .older: .none
		}
	}

	public static func startURL(_ base: URL, _ mode: Mode) -> URL {
		guard mode == .filtered, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
		c.fragment = key
		return c.url ?? base
	}

	/// Turns the page's filter off through its own checkbox (as a person unticking it would); returns whether it was on.
	public static let turnOffJS = """
	const b = document.querySelector('#fpanel input[value="newchip"]');
	if (!b || !b.checked) return false;
	b.checked = false;
	b.dispatchEvent(new Event("change"));
	return true;
	"""

	/// Whether the page's filter is on now.
	public static let isOnJS = """
	const b = document.querySelector('#fpanel input[value="newchip"]');
	return !!(b && b.checked);
	"""
}

/// Whether a firmware's installer row is shown for this FM-1. Baud Girl (FM-1+VA) does not say whether it supports
/// the newer chip (neither its install page, its firmware page nor the Firmware Hub's card for it), so it stays
/// shown, with a note, whatever the chip; a firmware that said it does not would be hidden on a newer chip.
public enum ChipSupport: String, Sendable { case yes, no, unknown }

public enum InstallerVisibility: Equatable, Sendable {
	case shown(note: String?)
	case hidden(reason: String)

	public static func of(support: ChipSupport, chip: FlashChip?) -> InstallerVisibility {
		switch (support, chip) {
		case (.no, .newer): .hidden(reason: "its maker says it does not support the newer flash chip")
		case (.unknown, .newer), (.unknown, .unsure), (.unknown, nil): .shown(note: "newer-chip support unknown")
		case (.no, .unsure), (.no, nil): .shown(note: "made for the older flash chip only")
		default: .shown(note: nil)
		}
	}
}
