import XCTest
import ErosServices

final class VerticalReaderTests: XCTestCase {
    func testLateDimensionsAndRotationPreservePageFraction() {
        let old = VerticalReaderGeometry(count: 1000, width: 400)
        let location = old.anchor(at: old.offset(index: 37, fraction: 0.4))
        let updated = VerticalReaderGeometry(count: 1000, width: 800, ratios: [0: 8, 35: 0.5, 37: 12])
        let restored = updated.anchor(at: updated.offset(index: location.index, fraction: location.fraction))
        XCTAssertEqual(restored.index, 37)
        XCTAssertEqual(restored.fraction, 0.4, accuracy: 0.0001)
        XCTAssertNotEqual(updated.offset(index: 37), old.offset(index: 37))
    }
    func testRapidJumpsRetainAtMostFivePagesWithoutAccumulation() {
        let layout = VerticalReaderGeometry(count: 10000, width: 400)
        for index in [0, 9999, 20, 4500, 1] {
            let pages = layout.retained(around: index)
            XCTAssertLessThanOrEqual(pages.count, 5)
            XCTAssertTrue(pages.contains(index))
            XCTAssertTrue(pages.allSatisfy { abs($0 - index) <= 2 && $0 >= 0 && $0 < 10000 })
        }
    }
    func testEmptyBoundsAndMixedAspectRatios() {
        let empty = VerticalReaderGeometry(count: 0, width: 0)
        XCTAssertNil(empty.visible(from: 0, to: 100)); XCTAssertTrue(empty.retained(around: 0).isEmpty)
        let layout = VerticalReaderGeometry(count: 4, width: 400, ratios: [0: 0.1, 1: 10, 2: .nan, 3: -1])
        XCTAssertEqual(layout.heights, [120, 4000, 600, 600])
        XCTAssertEqual(layout.anchor(at: -200).index, 0)
        XCTAssertEqual(layout.anchor(at: 999999).index, 3)
        XCTAssertEqual(layout.anchor(at: 999999).fraction, 1)
        XCTAssertEqual(layout.visible(from: 128, to: 3000), 1...1)
    }
}
