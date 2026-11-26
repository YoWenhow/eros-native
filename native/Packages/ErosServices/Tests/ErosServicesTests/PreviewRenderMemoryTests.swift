import XCTest
import ErosServices

@MainActor final class PreviewRenderMemoryTests: XCTestCase {
    func testReenterReusesSameLiveSlotWithoutClearingBitmap() {
        let cache = PreviewRenderMemory<String, String>(maximumCost: 12, maximumCount: 3)
        let cell = cache.entry(for: "page")
        cache.insert("bitmap", for: "page", cost: 4)
        XCTAssertTrue(cache.entry(for: "page") === cell)
        cache.touch("page")
        XCTAssertEqual(cell.value, "bitmap"); XCTAssertEqual(cache.cost, 4)
    }
    func testLRUEvictionClearsImageEvenWhenOffscreenCellRetainsSlot() {
        let cache = PreviewRenderMemory<Int, String>(maximumCost: 12, maximumCount: 3)
        let first = cache.entry(for: 1), second = cache.entry(for: 2)
        cache.insert("first", for: 1, cost: 4); cache.insert("second", for: 2, cost: 4)
        cache.insert("third", for: 3, cost: 4); cache.touch(1)
        cache.insert("fourth", for: 4, cost: 4)
        XCTAssertNil(second.value); XCTAssertEqual(first.value, "first")
        XCTAssertEqual(cache.count, 3); XCTAssertEqual(cache.cost, 12)
    }
    func testPressureClearReleasesHeldImagesAndSameSlotCanReload() {
        let cache = PreviewRenderMemory<Int, String>(maximumCost: 100, maximumCount: 2)
        let cell = cache.entry(for: 1)
        cache.insert("one", for: 1, cost: 10); cache.clear()
        XCTAssertNil(cell.value); XCTAssertEqual(cache.cost, 0); XCTAssertEqual(cache.count, 0)
        cache.insert("reloaded", for: 1, cost: 20)
        XCTAssertTrue(cache.entry(for: 1) === cell); XCTAssertEqual(cell.value, "reloaded")
    }
    func testReplacementOversizeAndDisabledCacheCannotKeepUnaccountedValues() {
        let cache = PreviewRenderMemory<Int, String>(maximumCost: 100, maximumCount: 2)
        let cell = cache.entry(for: 1)
        cache.insert("old", for: 1, cost: 10); cache.insert("replacement", for: 1, cost: 20)
        XCTAssertEqual(cache.cost, 20); XCTAssertEqual(cell.value, "replacement")
        cache.insert("oversize", for: 1, cost: 101)
        XCTAssertNil(cell.value); XCTAssertEqual(cache.cost, 0)
        let disabled = PreviewRenderMemory<Int, String>(maximumCost: 100, maximumCount: 0)
        let empty = disabled.entry(for: 1); disabled.insert("image", for: 1, cost: 1)
        XCTAssertNil(empty.value)
    }
    func testTenThousandRetainedCellSlotsCannotBypassImageBudget() {
        let cache = PreviewRenderMemory<Int, Int>(maximumCost: 64, maximumCount: 16)
        var cells: [PreviewRenderMemory<Int, Int>.Entry] = []
        for page in 0..<10_000 {
            cells.append(cache.entry(for: page)); cache.insert(page, for: page, cost: 4)
            XCTAssertLessThanOrEqual(cache.cost, 64); XCTAssertLessThanOrEqual(cache.count, 16)
        }
        XCTAssertEqual(cells.filter { $0.value != nil }.count, 16)
        cache.clear(); XCTAssertTrue(cells.allSatisfy { $0.value == nil })
    }
    func testEmptySlotRegistryDoesNotOwnDiscardedCell() {
        let cache = PreviewRenderMemory<String, String>(maximumCost: 12, maximumCount: 3)
        weak var weakCell: PreviewRenderMemory<String, String>.Entry?
        var cell: PreviewRenderMemory<String, String>.Entry? = cache.entry(for: "discarded")
        weakCell = cell; XCTAssertNotNil(weakCell); cell = nil
        XCTAssertNil(weakCell)
    }
}
