import XCTest
import ErosServices

final class SpreadReaderGeometryTests: XCTestCase {
    func testPortraitPairUsesFullHeightAndTouchesAtCenter() {
        let frames = SpreadReaderGeometry(width: 900, height: 400, aspectRatios: [0.7, 0.7]).frames
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].height, 400); XCTAssertEqual(frames[0].minY, 0)
        XCTAssertEqual(frames[0].maxX, frames[1].minX, accuracy: 0.000001)
        XCTAssertEqual(frames[0].maxX, 450, accuracy: 0.000001)
    }
    func testMixedRatiosFitBothWithoutGutterCroppingOrDistortion() {
        for ratios in [[0.6, 1.8], [1.8, 0.6], [0.1, 10.0]] {
            for size in [(900.0,400.0), (400.0,900.0)] {
                let f = SpreadReaderGeometry(width: size.0, height: size.1, aspectRatios: ratios).frames
                XCTAssertEqual(f[0].maxX, f[1].minX, accuracy: 0.000001)
                XCTAssertEqual(f[0].height, f[1].height)
                for (i, rect) in f.enumerated() {
                    XCTAssertGreaterThanOrEqual(rect.minX, -0.000001); XCTAssertLessThanOrEqual(rect.maxX, size.0 + 0.000001)
                    XCTAssertGreaterThanOrEqual(rect.minY, 0); XCTAssertLessThanOrEqual(rect.maxY, size.1 + 0.000001)
                    XCTAssertEqual(rect.width / rect.height, ratios[i], accuracy: 0.000001)
                }
            }
        }
    }
    func testCoverAndInvalidViewportDoNotInventSecondPage() {
        XCTAssertEqual(SpreadReaderGeometry(width: 900, height: 400, aspectRatios: [0.7]).frames.count, 1)
        for size in [(0.0,400.0), (-1.0,400.0), (Double.infinity,400.0), (900.0,Double.nan)] {
            XCTAssertTrue(SpreadReaderGeometry(width: size.0, height: size.1, aspectRatios: [0.7,0.7]).frames.isEmpty)
        }
        XCTAssertTrue(SpreadReaderGeometry(width: 900, height: 400, aspectRatios: []).frames.isEmpty)
    }
    func testUnknownAndLateDimensionsRemainFiniteAndAdjacent() {
        for ratios in [[Double.nan, -1], [Double.infinity, 0], [Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude], [0.6,0.9]] {
            let f = SpreadReaderGeometry(width: 900, height: 400, aspectRatios: ratios).frames
            XCTAssertEqual(f[0].maxX, f[1].minX, accuracy: 0.000001)
            XCTAssertTrue(f.allSatisfy { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 })
        }
    }
}
