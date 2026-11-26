import XCTest
import ErosCore

final class TransferProgressTests:XCTestCase {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    func testKnownUnknownLengthClampAndFinishedExpiry() throws {
        let monitor=TransferProgress(),owner=TransferOwner.reader(scope,try GalleryID(1),try PageIndex(0))
        monitor.begin(id:"a",owner:owner,now:10)
        monitor.update(id:"a",received:25,expected:100,delta:25,now:10.5)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:10.5).fraction,0.25)
        monitor.update(id:"a",received:120,expected:100,delta:95,now:11)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:11).fraction,1)
        monitor.finish(id:"a",now:11)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:11.1).fraction,1)
        XCTAssertNil(monitor.snapshot(owner:owner,now:14).fraction)
        monitor.begin(id:"b",owner:owner,now:15)
        monitor.update(id:"b",received:10,expected:-1,delta:10,now:16)
        XCTAssertNil(monitor.snapshot(owner:owner,now:16).fraction)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:16).received,10)
    }
    func testSpeedAggregatesParallelPagesAndDecaysAndIsolatesOwner() throws {
        let monitor=TransferProgress(),owner=TransferOwner.download(scope.storage,UUID()),other=TransferOwner.download(scope.storage,UUID())
        monitor.begin(id:"a",owner:owner,now:10);monitor.begin(id:"b",owner:owner,now:10)
        monitor.update(id:"a",received:1000,expected:5000,delta:1000,now:11)
        monitor.update(id:"b",received:2000,expected:5000,delta:2000,now:11)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:11).bytesPerSecond,3000)
        XCTAssertEqual(monitor.snapshot(owner:other,now:11).bytesPerSecond,0)
        monitor.finish(id:"a",now:11)
        monitor.update(id:"a",received:5000,expected:5000,delta:4000,now:11.5)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:14).bytesPerSecond,0)
    }
    func testRestoredTransferCountsOnlyNewBytesAndSessionIsolation() throws {
        let monitor=TransferProgress(),owner=TransferOwner.reader(scope,try GalleryID(1),try PageIndex(0))
        monitor.begin(id:"r",owner:owner,now:10)
        monitor.begin(id:"r",owner:owner,replacing:false,now:10.5)
        monitor.update(id:"r",received:10000,expected:20000,delta:100,now:11)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:11).bytesPerSecond,100)
        let next=SessionScope(storage:scope.storage,generation:2)
        XCTAssertNil(monitor.snapshot(owner:.reader(next,try GalleryID(1),try PageIndex(0)),now:11).fraction)
    }
    func testEstimatedArchiveProgressRemainsBelowCompleteUntilJobFinishes() {
        let monitor=TransferProgress(),owner=TransferOwner.download(scope.storage,UUID())
        monitor.begin(id:"archive",owner:owner,now:10)
        monitor.update(id:"archive",received:25,expected:100,delta:25,estimated:true,now:10.5)
        let first=monitor.snapshot(owner:owner,now:10.5)
        XCTAssertEqual(first.expected,100)
        XCTAssertTrue(first.isEstimated)
        XCTAssertEqual(first.fraction,0.25)
        XCTAssertEqual(first.bytesPerSecond,50)
        monitor.update(id:"archive",received:120,expected:100,delta:95,estimated:true,now:11)
        XCTAssertEqual(monitor.snapshot(owner:owner,now:11).fraction,0.99)
        monitor.begin(id:"archive",owner:owner,now:12)
        let restarted=monitor.snapshot(owner:owner,now:12)
        XCTAssertEqual(restarted.received,0)
        XCTAssertNil(restarted.expected)
        XCTAssertEqual(restarted.bytesPerSecond,0)
    }
}
