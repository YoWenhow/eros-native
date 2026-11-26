import XCTest
import ErosServices

final class ReaderMemoryCacheTests: XCTestCase {
    func testCostBoundEvictsLeastRecentlyUsed() {
        var cache = ReaderMemoryCache<Int, String>(maximumCost: 12, maximumCount: 10)
        cache.insert("first", for: 1, cost: 4); cache.insert("second", for: 2, cost: 4)
        cache.insert("third", for: 3, cost: 4)
        XCTAssertEqual(cache.value(for: 1), "first")
        cache.insert("fourth", for: 4, cost: 4)
        XCTAssertNil(cache.value(for: 2)); XCTAssertEqual(cache.value(for: 1), "first")
        XCTAssertEqual(cache.cost, 12); XCTAssertEqual(cache.count, 3)
    }
    func testCountReplacementOversizeAndMemoryPressureClear() {
        var cache = ReaderMemoryCache<Int, String>(maximumCost: 100, maximumCount: 2)
        cache.insert("one", for: 1, cost: 10); cache.insert("two", for: 2, cost: 10)
        cache.insert("replacement", for: 1, cost: 20)
        XCTAssertEqual(cache.cost, 30)
        cache.insert("three", for: 3, cost: 10)
        XCTAssertNil(cache.value(for: 2)); XCTAssertEqual(cache.count, 2)
        cache.insert("oversize", for: 4, cost: 101)
        XCTAssertNil(cache.value(for: 4)); XCTAssertEqual(cache.cost, 30)
        cache.clear(); XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.cost, 0)
    }
    func testSeparateReaderOwnersAndImageVariantsDoNotShareEntries() {
        var first = ReaderMemoryCache<String, String>(maximumCost: 100, maximumCount: 12)
        var other = ReaderMemoryCache<String, String>(maximumCost: 100, maximumCount: 12)
        first.insert("single", for: "0-single", cost: 24)
        first.insert("vertical", for: "0-vertical", cost: 8)
        XCTAssertEqual(first.value(for: "0-single"), "single")
        XCTAssertEqual(first.value(for: "0-vertical"), "vertical")
        XCTAssertNil(other.value(for: "0-single"))
        first.remove("0-single"); XCTAssertEqual(first.cost, 8)
    }
    func testTenThousandMixedPageCostsStayBoundedAndRecoverAfterPressure() {
        let limit = 96 * 1024 * 1024
        var cache = ReaderMemoryCache<Int, Int>(maximumCost: limit, maximumCount: 12)
        for page in 0..<10_000 {
            let cost = [8, 24, 4, 120][page % 4] * 1024 * 1024
            cache.insert(page, for: page, cost: cost)
            XCTAssertLessThanOrEqual(cache.cost, limit); XCTAssertLessThanOrEqual(cache.count, 12)
            if cost > limit { XCTAssertNil(cache.value(for: page)) }
            else { XCTAssertEqual(cache.value(for: page), page) }
            if page % 137 == 0 { cache.clear(); XCTAssertEqual(cache.cost, 0); XCTAssertEqual(cache.count, 0) }
        }
        cache.clear(); cache.insert(1, for: 1, cost: 8)
        XCTAssertEqual(cache.value(for: 1), 1)
    }

    func testPressureTrimKeepsVisibleCostAndRecency() {
        var cache = ReaderMemoryCache<Int, Int>(maximumCost: 10, maximumCount: 3)
        cache.insert(0, for: 0, cost: 3)
        cache.insert(1, for: 1, cost: 4)
        cache.insert(2, for: 2, cost: 2)
        XCTAssertEqual(cache.value(for: 0), 0)
        cache.retain { $0 != 1 }
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.cost, 5)
        XCTAssertNil(cache.value(for: 1))
        cache.insert(3, for: 3, cost: 6)
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.value(for: 0), 0)
        XCTAssertEqual(cache.cost, 9)
    }
}
