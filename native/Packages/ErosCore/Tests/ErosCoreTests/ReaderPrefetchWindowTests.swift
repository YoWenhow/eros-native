import Testing
import ErosCore

struct ReaderPrefetchWindowTests {
    @Test(arguments: zip(0...5, [[], [8], [8, 9], [8, 9, 10], [8, 9, 10, 11], [8, 9, 10, 11, 12]]))
    func takesExactlyTheConfiguredNumberOfImagePages(_ limit: Int, expected: [Int]) {
        #expect(ReaderPrefetchWindow.pages(after: [7], pageCount: 20, limit: limit) == expected)
    }

    @Test(arguments: [ReadingMode.leftToRight, .rightToLeft])
    func singlePageAndSpreadUseGalleryOrder(_ mode: ReadingMode) throws {
        let preferences = ReaderLayoutPreferences(mode: .doublePage, coverAlone: true)
        let portrait = try SpreadLayoutPolicy(pageCount: 16, readingMode: mode, preferences: preferences, orientation: .portrait)
        let main = try PageIndex(7)
        let single = try portrait.position(for: main).spread.displayPages.map(\.value)
        #expect(single == [7])
        #expect(ReaderPrefetchWindow.pages(after: single, pageCount: portrait.pageCount, limit: 2) == [8, 9])

        let landscape = try SpreadLayoutPolicy(pageCount: 16, readingMode: mode, preferences: preferences, orientation: .landscape)
        let spread = try landscape.position(for: main).spread.displayPages.map(\.value)
        #expect(spread == (mode == .rightToLeft ? [8, 7] : [7, 8]))
        #expect(ReaderPrefetchWindow.pages(after: spread, pageCount: landscape.pageCount, limit: 2) == [9, 10])
        let otherHalf = try landscape.position(for: PageIndex(8)).spread.displayPages.map(\.value)
        #expect(otherHalf == spread)

        let cover = try landscape.spread(at: 0).displayPages.map(\.value)
        #expect(cover == [0])
        #expect(ReaderPrefetchWindow.pages(after: cover, pageCount: landscape.pageCount, limit: 2) == [1, 2])
    }

    @Test func jumpingAndTurningBackRecomputeFromTheNewViewport() {
        #expect(ReaderPrefetchWindow.pages(after: [7], pageCount: 100, limit: 2) == [8, 9])
        #expect(ReaderPrefetchWindow.pages(after: [49], pageCount: 100, limit: 2) == [50, 51])
        #expect(ReaderPrefetchWindow.pages(after: [48], pageCount: 100, limit: 2) == [49, 50])
    }

    @Test func clampsToRemainingPagesAndExcludesVisibleDuplicates() {
        #expect(ReaderPrefetchWindow.pages(after: [98, 97, 98], pageCount: 100, limit: 5) == [99])
        #expect(ReaderPrefetchWindow.pages(after: [99], pageCount: 100, limit: 5).isEmpty)
        #expect(ReaderPrefetchWindow.pages(after: [0], pageCount: 1, limit: 5).isEmpty)
        #expect(ReaderPrefetchWindow.pages(after: [Int.max - 2], pageCount: Int.max, limit: 5) == [Int.max - 1])
    }

    @Test func emptyOrInvalidViewportStartsNoWork() {
        #expect(ReaderPrefetchWindow.pages(after: [], pageCount: 10, limit: 2).isEmpty)
        #expect(ReaderPrefetchWindow.pages(after: [0], pageCount: 0, limit: 2).isEmpty)
        #expect(ReaderPrefetchWindow.pages(after: [0], pageCount: -1, limit: 2).isEmpty)
        #expect(ReaderPrefetchWindow.pages(after: [-1, 2], pageCount: 10, limit: 2).isEmpty)
        #expect(ReaderPrefetchWindow.pages(after: [2, 10], pageCount: 10, limit: 2).isEmpty)
    }

    @Test(arguments: [-1, 6, Int.min, Int.max]) func unsupportedLimitsStartNoWork(_ limit: Int) {
        #expect(ReaderPrefetchWindow.pages(after: [7], pageCount: 20, limit: limit).isEmpty)
    }
}
