import XCTest
import ErosCore
import ErosServices

@MainActor final class NavigationIntentGateTests:XCTestCase {
    private var scope:SessionScope {SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:3)}
    func testConsumeExactlyOnceOnCapturedVisibleStack() throws {
        let gate=NavigationIntentGate(),scope=scope
        gate.select(3)
        let ticket=try XCTUnwrap(gate.begin(stackID:3,scope:scope))
        XCTAssertEqual(ticket.stackID,3)
        XCTAssertNil(gate.begin(stackID:0,scope:scope))
        XCTAssertTrue(gate.consume(ticket,scope:scope));XCTAssertFalse(gate.consume(ticket,scope:scope))
    }
    func testSwitchAwayAndBackCancelsLateCompletion() throws {
        let gate=NavigationIntentGate(),scope=scope
        let ticket=try XCTUnwrap(gate.begin(stackID:0,scope:scope))
        gate.select(1);gate.select(0)
        XCTAssertFalse(gate.consume(ticket,scope:scope))
    }
    func testCancelPathChangeAndAccountGenerationInvalidateCompletion() throws {
        let gate=NavigationIntentGate(),scope=scope
        let cancelled=try XCTUnwrap(gate.begin(stackID:0,scope:scope));gate.cancel(cancelled)
        XCTAssertFalse(gate.consume(cancelled,scope:scope))
        let popped=try XCTUnwrap(gate.begin(stackID:0,scope:scope));gate.invalidate(0)
        XCTAssertFalse(gate.consume(popped,scope:scope))
        let old=try XCTUnwrap(gate.begin(stackID:0,scope:scope))
        XCTAssertFalse(gate.consume(old,scope:try scope.advanced()))
        XCTAssertFalse(gate.consume(old,scope:self.scope))
        gate.invalidateAll()
        XCTAssertFalse(gate.consume(old,scope:scope))
    }
    func testInteractivePopCancellationDoesNotChangeSourceRevision() throws {
        let gate=NavigationIntentGate(),scope=scope
        let ticket=try XCTUnwrap(gate.begin(stackID:0,scope:scope))
        // No path mutation is committed for a cancelled native transition.
        XCTAssertTrue(gate.isCurrent(ticket,scope:scope))
        XCTAssertTrue(gate.consume(ticket,scope:scope))
    }
}
