import Foundation
import XCTest
import ErosCore

final class LibrarySourceSelectionTests: XCTestCase {
    func testPeriodsAndSourceRoundTripsAreBounded() throws {
        XCTAssertEqual(ToplistPeriod.allCases.map(\.rawValue), ["15", "13", "12", "11"])
        XCTAssertEqual(Set(LibrarySourceSelection.all).count, 7)
        for source in LibrarySourceSelection.all {
            XCTAssertEqual(try JSONDecoder().decode(LibrarySourceSelection.self, from: JSONEncoder().encode(source)), source)
            XCTAssertEqual(source.query.terms, ""); XCTAssertEqual(source.query.excludedCategories, [])
            XCTAssertNil(source.query.filters); XCTAssertEqual(source.query.source, source.source)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ToplistPeriod.self, from: Data("\"999\"".utf8)))
    }
    func testToplistSelectionDoesNotEncodeAReadingSite() throws {
        for period in ToplistPeriod.allCases {
            let selection = LibrarySourceSelection.toplist(period)
            XCTAssertEqual(selection.query.source, .toplist(period: period.rawValue))
            let json = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
            XCTAssertFalse(json.contains("site"))
        }
    }
}
