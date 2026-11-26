import XCTest
import ErosServices

@MainActor private final class StartupProbe {
    var started=0
    var completed=false
    var cancelled=false
    var continuation:CheckedContinuation<Void,Never>?
    func work() async {
        started += 1
        await withCheckedContinuation { continuation=$0 }
        cancelled=Task.isCancelled;completed=true
    }
    func release() { continuation?.resume();continuation=nil }
}
@MainActor final class AppStartupTaskTests:XCTestCase {
    func testLeavingViewDoesNotCancelStartupAndConcurrentViewJoins() async {
        let owner=AppStartupTask(),probe=StartupProbe()
        let first=Task { await owner.run { await probe.work() } }
        while probe.continuation == nil { await Task.yield() }
        first.cancel()
        var secondEntered=false
        let second=Task { secondEntered=true;await owner.run { probe.started += 100 } }
        while !secondEntered { await Task.yield() }
        probe.release()
        await first.value;await second.value
        XCTAssertEqual(probe.started,1);XCTAssertTrue(probe.completed);XCTAssertFalse(probe.cancelled)
    }
    func testLaterRetryRunsAfterIncompleteAttemptAndCancelledCallerCanStartWork() async {
        let owner=AppStartupTask(),probe=StartupProbe()
        let caller=Task { await owner.run { await probe.work() } }
        caller.cancel()
        while probe.continuation == nil { await Task.yield() }
        probe.release();await caller.value
        XCTAssertFalse(probe.cancelled)
        await owner.run { probe.started += 1 }
        XCTAssertEqual(probe.started,2)
    }
}

extension AppStartupTaskTests {
    func testReadyLocalTabReappearancesNeverPrepareOrLoadEvenWithLegacyOnlineError() async {
        let startup=AppStartupTask();var prepares=0,loads=0
        let context=LibraryStartupContext(initialized:true,permitsNetwork:false,preparationFailed:true,profileSwitching:false)
        for _ in 0..<12 {await startup.runLibrary(context:{context},prepare:{prepares+=1},loadOnline:{loads+=1})}
        XCTAssertEqual(prepares,0);XCTAssertEqual(loads,0);XCTAssertFalse(context.canRequestNetwork)
    }
    func testColdLocalStartupInitializesOnceAndKeepsSubsequentAppearancesIdle() async {
        let startup=AppStartupTask();var initialized=false,prepares=0,loads=0
        for _ in 0..<8 {
            await startup.runLibrary(context:{LibraryStartupContext(initialized:initialized,permitsNetwork:false,preparationFailed:false,profileSwitching:false)},prepare:{prepares+=1;initialized=true},loadOnline:{loads+=1})
        }
        XCTAssertEqual(prepares,1);XCTAssertEqual(loads,0)
    }
    func testOnlineRetryAndProfileSwitchingStillRespectStartupOwnership() async {
        let startup=AppStartupTask();var failed=true,prepares=0,loads=0,switching=true
        let context:@MainActor ()->LibraryStartupContext={LibraryStartupContext(initialized:true,permitsNetwork:true,preparationFailed:failed,profileSwitching:switching)}
        await startup.runLibrary(context:context,prepare:{prepares+=1;failed=false},loadOnline:{loads+=1})
        XCTAssertEqual(prepares,0);XCTAssertEqual(loads,0)
        switching=false
        await startup.runLibrary(context:context,prepare:{prepares+=1;failed=false},loadOnline:{loads+=1})
        await startup.runLibrary(context:context,prepare:{prepares+=1},loadOnline:{loads+=1})
        XCTAssertEqual(prepares,1);XCTAssertEqual(loads,1);XCTAssertTrue(context().canRequestNetwork)
    }
}


extension AppStartupTaskTests {
    func testColdStartCannotOpenLocalNavigationUntilVerificationSettlesDespiteLeavingView() async {
        let startup=AppStartupTask(),verification=StartupProbe()
        var initialized=false,preparing=false,failed=false
        let context:@MainActor ()->LibraryStartupContext={
            LibraryStartupContext(initialized:initialized,permitsNetwork:true,preparationFailed:failed,
                profileSwitching:false,preparing:preparing)
        }
        XCTAssertFalse(context().canOpenLocalLibrary)
        let caller=Task {
            await startup.runLibrary(context:context,prepare:{
                preparing=true
                // Services and a restored session exist, but verification is pending.
                initialized=true
                await verification.work()
                failed=true // Offline verification failure still leaves local access.
                preparing=false
            },loadOnline:{XCTFail("Cold start must prepare first")})
        }
        while verification.continuation == nil {await Task.yield()}
        caller.cancel()
        XCTAssertFalse(context().canOpenLocalLibrary)
        XCTAssertFalse(context().canRequestNetwork)
        if case .none=context().action {} else {XCTFail("Pending preparation must not start another run")}
        verification.release();await caller.value
        XCTAssertTrue(context().canOpenLocalLibrary)
        XCTAssertFalse(context().canRequestNetwork)
        XCTAssertFalse(verification.cancelled)
    }

    func testLocalOnlyAndOnlineErrorsRetainLocalAccessButProfileTransitionsDoNot() {
        let local=LibraryStartupContext(initialized:true,permitsNetwork:false,preparationFailed:true,profileSwitching:false)
        let onlineFailure=LibraryStartupContext(initialized:true,permitsNetwork:true,preparationFailed:true,profileSwitching:false)
        XCTAssertTrue(local.canOpenLocalLibrary);XCTAssertTrue(onlineFailure.canOpenLocalLibrary)
        XCTAssertFalse(local.canRequestNetwork);XCTAssertFalse(onlineFailure.canRequestNetwork)
        let switching=LibraryStartupContext(initialized:true,permitsNetwork:true,preparationFailed:false,profileSwitching:true)
        XCTAssertFalse(switching.canOpenLocalLibrary);XCTAssertFalse(switching.canRequestNetwork)
        let storageFailure=LibraryStartupContext(initialized:false,permitsNetwork:true,preparationFailed:true,profileSwitching:false)
        XCTAssertFalse(storageFailure.canOpenLocalLibrary)
    }
}
