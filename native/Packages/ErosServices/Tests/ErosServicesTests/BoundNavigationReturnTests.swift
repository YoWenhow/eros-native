import XCTest
@testable import ErosServices

@MainActor final class BoundNavigationReturnTests: XCTestCase {
    func testCancelledGesturePreservesPathAndAllowsLaterReturn() throws {
        let gate = BoundNavigationReturn<Int>()
        let token = try XCTUnwrap(gate.begin(from: [1, 2], to: [1]))
        gate.cancel(token)
        XCTAssertNil(gate.commit(token, current: [1, 2]))
        XCTAssertTrue(gate.acceptsBinding([1], current: [1, 2]))
    }
    func testLatePopAcknowledgementCannotRemoveNewPage() throws {
        let gate = BoundNavigationReturn<Int>()
        let token = try XCTUnwrap(gate.begin(from: [1, 2], to: [1]))
        XCTAssertEqual(gate.commit(token, current: [1, 2]), [1])
        // A tap on the revealed list pushes 3 before UIKit acknowledges pop 2.
        XCTAssertFalse(gate.acceptsBinding([1], current: [1, 3]))
        XCTAssertFalse(gate.acceptsBinding([1], current: [1, 3]))
        XCTAssertTrue(gate.acceptsBinding([1, 3], current: [1, 3]))
    }
    func testNextUserReturnIsNotSuppressedWhenOldPopHadNoAcknowledgement() throws {
        let gate = BoundNavigationReturn<Int>()
        let old = try XCTUnwrap(gate.begin(from: [1, 2], to: [1]))
        _ = gate.commit(old, current: [1, 2])
        let next = try XCTUnwrap(gate.begin(from: [1, 3], to: [1]))
        XCTAssertNil(gate.commit(old, current: [1, 3]))
        XCTAssertEqual(gate.commit(next, current: [1, 3]), [1])
        XCTAssertTrue(gate.acceptsBinding([1], current: [1]))
    }
    func testNewPushObservationDoesNotErasePriorPopAcknowledgement() throws {
        let gate = BoundNavigationReturn<Int>()
        let old = try XCTUnwrap(gate.begin(from: [1, 2], to: [1]))
        XCTAssertEqual(gate.commit(old, current: [1, 2]), [1])
        // The next push registers for possible reversal before old pop settles.
        let incoming = try XCTUnwrap(gate.begin(from: [1, 3], to: [1]))
        XCTAssertFalse(gate.acceptsBinding([1], current: [1, 3]))
        gate.cancel(incoming) // normal incoming push completes
        XCTAssertFalse(gate.acceptsBinding([1], current: [1, 3]))
    }

    func testControllerTeardownDoesNotEraseCommittedAcknowledgement() throws {
        let gate = BoundNavigationReturn<Int>()
        let ticket = try XCTUnwrap(gate.begin(from: [1, 2], to: [1]))
        XCTAssertEqual(gate.commit(ticket, current: [1, 2]), [1])
        gate.endObservation(ticket)
        XCTAssertFalse(gate.acceptsBinding([1], current: [1, 3]))
    }

    func testFirstAcknowledgementBeforeNewPushDoesNotAdmitDuplicateAcknowledgement() throws {
        let gate = BoundNavigationReturn<Int>()
        let ticket = try XCTUnwrap(gate.begin(from: [1, 2], to: [1]))
        XCTAssertEqual(gate.commit(ticket, current: [1, 2]), [1])
        XCTAssertTrue(gate.acceptsBinding([1], current: [1]))
        XCTAssertFalse(gate.acceptsBinding([1], current: [1, 3]))
    }

    func testChangedPathAndInvalidatedAccountRejectOldCompletion() throws {
        let gate = BoundNavigationReturn<Int>()
        let old = try XCTUnwrap(gate.begin(from: [1, 2], to: []))
        XCTAssertNil(gate.commit(old, current: [8]))
        let current = try XCTUnwrap(gate.begin(from: [8, 9], to: [8]))
        gate.invalidate()
        XCTAssertNil(gate.commit(current, current: [8, 9]))
        XCTAssertTrue(gate.acceptsBinding([], current: [8, 9]))
    }
    func testNonPrefixAndRepeatedCompletionAreRejected() throws {
        let gate = BoundNavigationReturn<Int>()
        XCTAssertNil(gate.begin(from: [1, 2], to: [9]))
        XCTAssertNil(gate.begin(from: [1], to: [1]))
        let token = try XCTUnwrap(gate.begin(from: [1, 2, 3], to: [1]))
        XCTAssertEqual(gate.commit(token, current: [1, 2, 3]), [1])
        XCTAssertNil(gate.commit(token, current: [1, 2, 3]))
    }
}
