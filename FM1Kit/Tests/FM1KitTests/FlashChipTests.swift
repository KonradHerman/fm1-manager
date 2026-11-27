// SPDX-License-Identifier: GPL-3.0-only
import FM1Kit
import XCTest

final class FlashChipTests: XCTestCase {
	func testJEDECIds() {
		XCTAssertEqual(FlashChip.from(jedec: "B36014"), .newer)
		XCTAssertEqual(FlashChip.from(jedec: "b36014"), .newer)
		XCTAssertEqual(FlashChip.from(jedec: "856014"), .older)
		XCTAssertNil(FlashChip.from(jedec: "EF4015"))
		XCTAssertNil(FlashChip.from(jedec: nil))
	}

	func testDetectionOverridesTheAnswerAndIsRemembered() {
		var k = ChipKnowledge()
		XCTAssertTrue(k.shouldAsk)
		k.say(.unsure)
		XCTAssertFalse(k.shouldAsk)
		k.detected("B36014")
		XCTAssertEqual(k.chip, .newer)
		XCTAssertTrue(k.wasDetected)
		k.detected("856014")                                          // another FM-1 on the same phone: the last one counts
		XCTAssertEqual(k.chip, .older)
		k.detected("EF4015")                                          // an id not known here changes nothing
		XCTAssertEqual(k.chip, .older)
		k.say(.newer)                                                 // the person may still say otherwise in Settings
		XCTAssertFalse(k.wasDetected)
		let d = UserDefaults(suiteName: "chip-\(UUID().uuidString)")!
		k.save(d)
		XCTAssertEqual(ChipKnowledge.load(d), k)
	}

	func testHubFilterMode() {
		var k = ChipKnowledge()
		XCTAssertEqual(HubFilter.mode(k), .caution, "not asked yet: no filter, a caution")
		k.say(.unsure)
		XCTAssertEqual(HubFilter.mode(k), .caution)
		k.say(.older)
		XCTAssertEqual(HubFilter.mode(k), .none)
		k.say(.newer)
		XCTAssertEqual(HubFilter.mode(k), .filtered)
		k.filterHub = false
		XCTAssertEqual(HubFilter.mode(k), .none)
		let hub = URL(string: "https://thefirmwarehub.com/")!
		XCTAssertEqual(HubFilter.startURL(hub, .filtered).absoluteString, "https://thefirmwarehub.com/#newchip")
		XCTAssertEqual(HubFilter.startURL(hub, .caution), hub)
	}

	func testInstallerVisibility() {
		XCTAssertEqual(InstallerVisibility.of(support: .unknown, chip: .newer), .shown(note: "newer-chip support unknown"))
		XCTAssertEqual(InstallerVisibility.of(support: .unknown, chip: .older), .shown(note: nil))
		XCTAssertEqual(InstallerVisibility.of(support: .unknown, chip: nil), .shown(note: "newer-chip support unknown"))
		if case .hidden = InstallerVisibility.of(support: .no, chip: .newer) {} else { XCTFail("hidden on a newer chip") }
		XCTAssertEqual(InstallerVisibility.of(support: .no, chip: .older), .shown(note: nil))
		XCTAssertEqual(InstallerVisibility.of(support: .yes, chip: .newer), .shown(note: nil))
	}
}
