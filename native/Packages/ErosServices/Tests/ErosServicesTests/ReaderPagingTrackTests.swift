import ErosCore
import Testing
@testable import ErosServices

struct ReaderPagingTrackTests {
    @Test func aSecondSwipeCanReachPastTheFirstWithoutPresentingIt() throws {
        let track = try track(pageCount: 20)
        let original = try #require(track.index(for: 3))
        #expect(track.nearbyIndices(at: Double(original)) == 2...4)
        // A new drag may carry the same native viewport on while SwiftUI still shows page 3.
        #expect(track.visibleIndices(at: 4.2) == 4...5)
        #expect(track.nearbyIndices(at: 4.2) == 3...5)
        let settled = try #require(track.settledIndex(at: 5))
        #expect(track.position(at: settled)?.mainPage.value == 5)
        #expect(track.index(for: 3) == original)
    }

    @Test func interruptionRetainsBothVisiblePagesAndDoesNotReportASettle() throws {
        let track = try track(pageCount: 100_000)
        #expect(track.nearbyIndices(at: 37_611.3) == 37_610...37_612)
        #expect(track.nearbyIndices(at: 37_611.7) == 37_611...37_613)
        #expect(track.visibleIndices(at: 37_611.7) == 37_611...37_612)
        #expect(track.settledIndex(at: 37_611.7) == nil)
        #expect(track.settledIndex(at: 37_611) == 37_611)
    }

    @Test func endBounceAndEmptyTracksHaveNoInventedPage() throws {
        let empty = try track(pageCount: 0)
        #expect(empty.nearbyIndices(at: 0) == nil)
        #expect(empty.settledIndex(at: 0) == nil)
        let only = try track(pageCount: 1)
        #expect(only.nearbyIndices(at: 5) == 0...0)
        #expect(only.position(at: 1) == nil)
        let track = try track(pageCount: 20)
        #expect(track.visibleIndices(at: -0.2) == 0...0)
        #expect(track.nearbyIndices(at: 19.2) == 18...19)
        #expect(track.settledIndex(at: -0.2) == nil)
        #expect(track.settledIndex(at: 19.2) == nil)
        #expect(track.settledIndex(at: .nan) == nil)
    }

    @Test func rightToLeftSpreadsKeepLogicalAnchorsAndCover() throws {
        let track = try track(pageCount: 6, mode: .rightToLeft, doublePage: true)
        #expect(track.count == 4)
        #expect(track.index(for: 0) == 3)
        #expect(track.index(for: 2) == 2)
        #expect(track.position(at: 2)?.mainPage.value == 1)
        #expect(track.position(at: 2)?.spread.displayPages.map(\.value) == [2, 1])
        #expect(track.position(at: 0)?.mainPage.value == 5)
        #expect(track.visibleIndices(at: 1.8) == 1...2)
    }

    private func track(pageCount: Int, mode: ReadingMode = .leftToRight, doublePage: Bool = false) throws -> ReaderPagingTrack {
        ReaderPagingTrack(policy: try SpreadLayoutPolicy(pageCount: pageCount, readingMode: mode,
            preferences: .init(mode: doublePage ? .doublePage : .singlePage, coverAlone: true), orientation: .landscape))
    }
}
