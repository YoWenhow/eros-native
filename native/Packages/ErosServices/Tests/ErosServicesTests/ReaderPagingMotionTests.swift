import Testing
@testable import ErosServices

struct ReaderPagingMotionTests {
    @Test func consecutiveFlicksAdvanceEvenBeforeAnyPageSettles() {
        var motion = ReaderPagingMotion(pageCount: 25, index: 4)
        for swipe in 1...8 {
            let start = Double(swipe) * 0.034
            let visible = motion.position
            motion.beginDrag()
            #expect(motion.position == visible)
            #expect(!motion.isSettling)
            motion.drag(by: 23, viewportWidth: 390)
            #expect(motion.endDrag(distance: 23, velocity: 1_500, viewportWidth: 390, at: start) == nil)
            #expect(motion.targetIndex == 4 + swipe)
            #expect(motion.advance(to: start + 0.028) == nil)
        }
        #expect(motion.advance(to: 1) == 12)
        #expect(motion.position == 12)
        #expect(motion.advance(to: 2) == nil)
    }

    @Test func aNewFlickAfterLandingDoesNotWaitForViewUpdates() {
        var motion = ReaderPagingMotion(pageCount: 12, index: 6)
        motion.beginDrag()
        motion.endDrag(distance: 22, velocity: 950, viewportWidth: 390, at: 0)
        #expect(motion.advance(to: 0.22) == 7)
        // No external presentation call occurs between the two swipes.
        motion.beginDrag()
        motion.endDrag(distance: 22, velocity: 950, viewportWidth: 390, at: 0.23)
        #expect(motion.targetIndex == 8)
        #expect(motion.advance(to: 0.46) == 8)
    }

    @Test func reversingAnInFlightTurnUsesItsVisiblePositionAndUpdatesTheTarget() {
        var motion = ReaderPagingMotion(pageCount: 12, index: 6)
        motion.beginDrag()
        motion.endDrag(distance: 21, velocity: 950, viewportWidth: 390, at: 0)
        motion.advance(to: 0.08)
        let visible = motion.position
        #expect(visible > 6 && visible < 7)
        motion.beginDrag()
        motion.drag(by: -20, viewportWidth: 390)
        #expect(abs(motion.position - (visible - 20.0 / 390)) < 0.000_001)
        motion.endDrag(distance: -20, velocity: -1_200, viewportWidth: 390, at: 0.09)
        #expect(motion.targetIndex == 6)
        #expect(motion.advance(to: 0.5) == 6)
    }

    @Test func shortSlowDragAndCancellationKeepTheAlreadyAcceptedPage() {
        var motion = ReaderPagingMotion(pageCount: 10, index: 3)
        motion.beginDrag()
        motion.endDrag(distance: 19, velocity: 850, viewportWidth: 390, at: 0)
        motion.advance(to: 0.04)
        motion.beginDrag()
        motion.endDrag(distance: -16, velocity: -100, viewportWidth: 390, at: 0.08)
        #expect(motion.targetIndex == 4)
        motion.advance(to: 0.10)
        motion.beginDrag()
        motion.drag(by: 200, viewportWidth: 390)
        motion.cancelDrag(at: 0.12)
        #expect(motion.targetIndex == 4)
        #expect(motion.advance(to: 0.45) == 4)
    }

    @Test func lastPageResistanceCanBeInterruptedWithoutJumpingOrTurning() {
        var motion = ReaderPagingMotion(pageCount: 3, index: 2)
        motion.beginDrag()
        motion.endDrag(distance: 190, velocity: 850, viewportWidth: 390, at: 0)
        motion.advance(to: 0.03)
        let visible = motion.position
        #expect(visible > 2 && visible < 2.18)
        motion.beginDrag()
        motion.drag(by: 0, viewportWidth: 390)
        #expect(abs(motion.position - visible) < 0.000_001)
        motion.endDrag(distance: 40, velocity: 1_100, viewportWidth: 390, at: 0.08)
        #expect(motion.targetIndex == 2)
        #expect(motion.advance(to: 0.45) == 2)
    }

    @Test func reduceMotionLandsImmediatelyAndTheNextFlickStillAdvances() {
        var motion = ReaderPagingMotion(pageCount: 8, index: 5)
        motion.beginDrag()
        #expect(motion.endDrag(distance: -18, velocity: -750, viewportWidth: 390, at: 0, reduceMotion: true) == 4)
        #expect(motion.position == 4)
        #expect(!motion.isSettling)
        motion.beginDrag()
        #expect(motion.endDrag(distance: -19, velocity: -850, viewportWidth: 390, at: 0.05, reduceMotion: true) == 3)
        #expect(motion.position == 3)
    }
}
