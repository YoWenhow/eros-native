import Foundation
import XCTest
import ErosCore

final class SpreadLayoutPolicyTests: XCTestCase {
    private func policy(_ count: Int, cover: Bool = true, mode: ReadingMode = .leftToRight,
                        orientation: ReaderViewportOrientation = .landscape, layout: ReaderLayoutMode = .doublePage) throws -> SpreadLayoutPolicy {
        try SpreadLayoutPolicy(pageCount: count, readingMode: mode, preferences: ReaderLayoutPreferences(mode: layout, coverAlone: cover), orientation: orientation)
    }
    func testOneToFivePagesBothCoverModesAndDirections() throws {
        let withCover = [[[0]], [[0],[1]], [[0],[1,2]], [[0],[1,2],[3]], [[0],[1,2],[3,4]]]
        let withoutCover = [[[0]], [[0,1]], [[0,1],[2]], [[0,1],[2,3]], [[0,1],[2,3],[4]]]
        for cover in [false, true] {
            for mode in [ReadingMode.leftToRight, .rightToLeft] {
                for count in 1...5 {
                    let p = try policy(count, cover: cover, mode: mode)
                    let expected = (cover ? withCover : withoutCover)[count - 1]
                    XCTAssertEqual(p.spreadCount, expected.count)
                    for (index, pages) in expected.enumerated() {
                        let spread = try p.spread(at: index)
                        XCTAssertEqual(spread.logicalPages.map(\.value), pages)
                        XCTAssertEqual(spread.displayPages.map(\.value), mode == .rightToLeft ? Array(pages.reversed()) : pages)
                    }
                }
            }
        }
    }
    func testDefaultPortraitAndVerticalAlwaysUseSinglePagesWithoutErasingPreference() throws {
        let defaultPolicy = try SpreadLayoutPolicy(pageCount: 5, readingMode: .leftToRight, orientation: .landscape)
        XCTAssertFalse(defaultPolicy.usesDoublePage); XCTAssertEqual(defaultPolicy.spreadCount, 5)
        for p in [try policy(5, orientation: .portrait), try policy(5, mode: .vertical), try policy(5, layout: .singlePage)] {
            XCTAssertFalse(p.usesDoublePage); XCTAssertEqual(p.spreadCount, 5)
            for page in 0..<5 { XCTAssertEqual(try p.spread(at: page).logicalPages.map(\.value), [page]) }
        }
        let vertical = try policy(5, mode: .vertical)
        XCTAssertEqual(vertical.preferences.mode, .doublePage); XCTAssertNil(vertical.forwardSwipe)
    }
    func testSecondPageAnchorSurvivesRotationDirectionAndCoverChanges() throws {
        let anchor = try PageIndex(2)
        for mode in [ReadingMode.leftToRight, .rightToLeft] {
            let landscape = try policy(5, mode: mode)
            let before = try landscape.position(for: anchor)
            XCTAssertEqual(before.spread.index, 1); XCTAssertEqual(before.mainPage, anchor)
            let portrait = try policy(5, mode: mode, orientation: .portrait).position(for: before.mainPage)
            XCTAssertEqual(portrait.spread.index, 2); XCTAssertEqual(portrait.mainPage, anchor)
            let restored = try landscape.position(for: portrait.mainPage)
            XCTAssertEqual(restored, before)
            let withoutCover = try policy(5, cover: false, mode: mode).position(for: restored.mainPage)
            XCTAssertEqual(withoutCover.mainPage, anchor); XCTAssertTrue(withoutCover.spread.logicalPages.contains(anchor))
        }
    }
    func testEveryLogicalPageAppearsOnceAndMapsBackToItsSpread() throws {
        for count in 1...64 {
            for cover in [true, false] {
                for mode in [ReadingMode.leftToRight, .rightToLeft] {
                    let p = try policy(count, cover: cover, mode: mode)
                    var seen: [Int] = []
                    for index in 0..<p.spreadCount {
                        let spread = try p.spread(at: index)
                        XCTAssertTrue((1...2).contains(spread.logicalPages.count))
                        for page in spread.logicalPages {
                            seen.append(page.value)
                            XCTAssertEqual(try p.spreadIndex(for: page), index)
                            XCTAssertEqual(try p.position(at: index, preferredMainPage: page), try p.position(for: page))
                        }
                    }
                    XCTAssertEqual(seen, Array(0..<count))
                }
            }
        }
    }
    func testLogicalNavigationAndSwipeDirectionAreIndependent() throws {
        for mode in [ReadingMode.leftToRight, .rightToLeft] {
            let p = try policy(5, mode: mode)
            XCTAssertEqual(p.forwardSwipe, mode == .leftToRight ? .left : .right)
            XCTAssertNil(try p.neighbor(from: PageIndex(0), direction: .previous))
            XCTAssertEqual(try p.neighbor(from: PageIndex(0), direction: .next)?.mainPage.value, 1)
            XCTAssertEqual(try p.neighbor(from: PageIndex(2), direction: .next)?.mainPage.value, 3)
            XCTAssertEqual(try p.neighbor(from: PageIndex(4), direction: .previous)?.mainPage.value, 1)
            XCTAssertNil(try p.neighbor(from: PageIndex(4), direction: .next))
        }
    }
    func testInvalidBoundsAndEmptyGalleryNeverInventPages() throws {
        XCTAssertThrowsError(try policy(-1))
        let empty = try policy(0)
        XCTAssertEqual(empty.spreadCount, 0)
        XCTAssertThrowsError(try empty.spread(at: 0)); XCTAssertThrowsError(try empty.position(for: PageIndex(0)))
        let p = try policy(5)
        XCTAssertThrowsError(try p.spread(at: -1)); XCTAssertThrowsError(try p.spread(at: 3))
        XCTAssertThrowsError(try p.position(for: PageIndex(5)))
        XCTAssertThrowsError(try p.position(at: 1, preferredMainPage: PageIndex(4)))
    }
    func testIntMaxPageCountAndLastPageDoNotOverflowOrAllocateWholeGallery() throws {
        for count in [Int.max - 1, Int.max] {
            for cover in [true, false] {
                let p = try policy(count, cover: cover)
                let last = try PageIndex(count - 1), position = try p.position(for: last)
                XCTAssertEqual(position.spread.index, p.spreadCount - 1)
                XCTAssertEqual(position.spread.logicalPages.last, last)
                XCTAssertLessThanOrEqual(position.spread.logicalPages.count, 2)
                XCTAssertNil(try p.neighbor(from: last, direction: .next))
                XCTAssertEqual(try p.spread(at: 0).logicalPages.first?.value, 0)
            }
        }
    }
    func testLegacyPreferencesPreserveExistingSettingsAndDefaultToSinglePage() throws {
        let data = Data(#"{"theme":"dark","rightToLeft":true,"vertical":false,"cacheMiB":128,"downloadConcurrency":3}"#.utf8)
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: data).validated()
        XCTAssertEqual(prefs.theme, .dark); XCTAssertEqual(prefs.readingMode, .rightToLeft)
        XCTAssertEqual(prefs.cacheMiB, 128); XCTAssertEqual(prefs.downloadConcurrency, 3)
        XCTAssertEqual(prefs.readerLayout, ReaderLayoutPreferences(mode: .singlePage, coverAlone: true))
        XCTAssertEqual(try JSONDecoder().decode(ReaderLayoutPreferences.self, from: Data("{}".utf8)), ReaderLayoutPreferences())
        let partial = try JSONDecoder().decode(ReaderLayoutPreferences.self, from: Data(#"{"mode":"doublePage"}"#.utf8))
        XCTAssertTrue(partial.coverAlone)
    }
    func testIndependentLayoutRoundTripAndExistingReadingModeEncoding() throws {
        var prefs = AppPreferences(); prefs.rightToLeft = true; prefs.vertical = true
        prefs.readerLayout = ReaderLayoutPreferences(mode: .doublePage, coverAlone: false)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs)).validated()
        XCTAssertEqual(restored, prefs); XCTAssertEqual(restored.readingMode, .vertical)
        for mode in [ReadingMode.leftToRight, .rightToLeft, .vertical] {
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(mode), as: UTF8.self), "\"" + mode.rawValue + "\"")
        }
        for json in [#"{"mode":"future"}"#, #"{"coverAlone":1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ReaderLayoutPreferences.self, from: Data(json.utf8)))
        }
    }
    func testProgressPersistsLogicalAnchorRatherThanSpreadOrdinal() throws {
        let p = try policy(5, mode: .rightToLeft)
        let position = try p.position(for: PageIndex(2))
        XCTAssertNotEqual(position.mainPage.value, position.spread.index)
        let progress = ReadingProgress(scope: StorageScope(accountID: AccountID(UUID()), site: .ex), galleryID: try GalleryID(42),
            index: position.mainPage, fraction: try UnitFraction(0.5), readingMode: .rightToLeft, updatedAt: Date(timeIntervalSince1970: 0))
        let restored = try JSONDecoder().decode(ReadingProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(restored, progress); XCTAssertEqual(restored.index.value, 2)
        XCTAssertEqual(try p.position(for: restored.index), position)
    }
}
