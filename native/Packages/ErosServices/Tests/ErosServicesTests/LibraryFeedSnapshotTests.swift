import Testing
import ErosServices

struct LibraryFeedSnapshotTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
        var title: String
        init(_ id: Int, _ title: String = "same") { self.id = id; self.title = title }
    }

    @Test func removingOnlyTrailingPagesNeverReconfiguresTheVisibleFirstPage() {
        var snapshot = LibraryFeedSnapshot<Row>()
        let firstPage = (0..<20).map { Row($0) }
        let pages = (0..<100).map { Row($0) }
        #expect(snapshot.begin(pages) == [])
        snapshot.finish()
        #expect(snapshot.begin(firstPage) == [])
        #expect(snapshot[99] == Row(99))
        #expect(snapshot[0] == firstPage[0])
        snapshot.finish()
        #expect(snapshot[99] == nil)
        #expect(snapshot.begin(firstPage) == nil)
    }

    @Test func reorderedAndInsertedRowsKeepStableHostsAndOnlyEditedIDsReconfigure() {
        var snapshot = LibraryFeedSnapshot<Row>()
        _ = snapshot.begin([Row(1), Row(2), Row(3)])
        snapshot.finish()
        #expect(snapshot.begin([Row(4), Row(2), Row(1, "updated")]) == [1])
        #expect(snapshot[4] == Row(4))
        #expect(snapshot[1]?.title == "updated")
        #expect(snapshot[3] == Row(3))
        snapshot.finish()
        #expect(snapshot[3] == nil)
    }

    @Test func anInFlightDiffKeepsBothPopulationsUntilItCommitsAndThenAcceptsLatestInput() {
        var snapshot = LibraryFeedSnapshot<Row>()
        _ = snapshot.begin([Row(1)])
        snapshot.finish()
        _ = snapshot.begin([Row(2)])
        let latest = [Row(3)]
        #expect(snapshot.begin(latest) == nil)
        #expect(snapshot[1] == Row(1) && snapshot[2] == Row(2) && snapshot[3] == nil)
        snapshot.finish()
        #expect(snapshot.begin(latest) == [])
        snapshot.finish()
        #expect(snapshot[1] == nil && snapshot[2] == nil && snapshot[3] == Row(3))
    }
}
