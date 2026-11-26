import XCTest
import ErosCore
import ErosServices

@MainActor private final class ForegroundProvider:ClipboardLinkProvider {
    var reads=0
    let text:String?
    init(_ text:String?) {self.text=text}
    func snapshot() async -> ClipboardLinkSnapshot {reads+=1;return ClipboardLinkSnapshot(text:text)}
}
@MainActor private final class DelayedForegroundProvider:ClipboardLinkProvider {
    var reads=0
    var continuation:CheckedContinuation<ClipboardLinkSnapshot,Never>?
    func snapshot() async -> ClipboardLinkSnapshot {
        reads+=1;return await withCheckedContinuation{continuation=$0}
    }
    func finish(_ text:String) {continuation?.resume(returning:ClipboardLinkSnapshot(text:text));continuation=nil}
}
private actor ForegroundClock:ErosCore.Clock {
    private var time=0.0
    private var waiters:[UUID:(Double,CheckedContinuation<Void,any Error>)]=[:]
    var pending:Int {waiters.count}
    func now() -> Date {Date(timeIntervalSince1970:time)}
    func sleep(seconds:TimeInterval) async throws {
        let id=UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation{waiters[id]=(time+seconds,$0)}
        } onCancel:{Task{await self.cancel(id)}}
    }
    private func cancel(_ id:UUID) {waiters.removeValue(forKey:id)?.1.resume(throwing:CancellationError())}
    func advance(_ seconds:Double) {
        time+=seconds
        for (id,item) in waiters where item.0<=time {
            waiters.removeValue(forKey:id);item.1.resume()
        }
    }
}
private actor LateForegroundClock:ErosCore.Clock {
    private var waiters:[CheckedContinuation<Void,Never>?]=[]
    var count:Int {waiters.count}
    func now() -> Date {Date(timeIntervalSince1970:0)}
    func sleep(seconds:TimeInterval) async {
        await withCheckedContinuation{waiters.append($0)}
    }
    func fire(_ index:Int) {let value=waiters[index];waiters[index]=nil;value?.resume()}
}
private struct FailingForegroundClock:ErosCore.Clock {
    func now() async -> Date {Date(timeIntervalSince1970:0)}
    func sleep(seconds:TimeInterval) async throws {throw AppError.transport(code:-1)}
}
@MainActor final class ForegroundClipboardPromptTests:XCTestCase {
    private let link="https://exhentai.org/g/42/012345abcd/"
    private func until(_ condition:@MainActor () async -> Bool) async {
        for _ in 0..<10000 {if await condition(){return};await Task.yield()}
        XCTFail("foreground action did not settle")
    }
    func testOneReadPerForegroundAndNoInactivePermissionLoop() async {
        let provider=ForegroundProvider(link),clock=ForegroundClock(),model=ForegroundClipboardPrompt(clock:clock)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        model.phase(.inactive,provider:provider,allowsPresentation:{true})
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{let n=await clock.pending;return !model.checking && n==1}
        XCTAssertEqual(provider.reads,1);XCTAssertEqual(model.candidates.count,1)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        XCTAssertEqual(provider.reads,1)
        model.phase(.background,provider:provider,allowsPresentation:{true})
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{!model.checking}
        XCTAssertEqual(provider.reads,2);model.suppress()
    }
    func testTenSecondExpiryDoesNotRestartOrReread() async {
        let provider=ForegroundProvider(link),clock=ForegroundClock(),model=ForegroundClipboardPrompt(clock:clock)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{let n=await clock.pending;return n==1 && !model.checking}
        await clock.advance(9);await Task.yield();XCTAssertEqual(model.candidates.count,1)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await clock.advance(1);await until{model.candidates.isEmpty}
        XCTAssertEqual(provider.reads,1)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        XCTAssertEqual(provider.reads,1)
    }
    func testReaderSuppressionStillReadsOnlyOnceAndDoesNotReappearOnExit() async {
        let provider=ForegroundProvider(link),model=ForegroundClipboardPrompt()
        var reading=true
        model.phase(.active,provider:provider,allowsPresentation:{!reading})
        await until{!model.checking}
        XCTAssertEqual(provider.reads,1);XCTAssertTrue(model.candidates.isEmpty)
        reading=false
        model.phase(.active,provider:provider,allowsPresentation:{!reading})
        XCTAssertEqual(provider.reads,1);XCTAssertTrue(model.candidates.isEmpty)
    }
    func testBackgroundLateReadCannotReplaceNewForegroundSnapshot() async {
        let old=DelayedForegroundProvider(),fresh=ForegroundProvider(link),model=ForegroundClipboardPrompt()
        model.phase(.active,provider:old,allowsPresentation:{true})
        await until{old.continuation != nil}
        model.phase(.background,provider:old,allowsPresentation:{true})
        model.phase(.active,provider:fresh,allowsPresentation:{true})
        old.finish("https://e-hentai.org/g/43/abcdef0123/")
        await until{!model.checking}
        XCTAssertEqual(old.reads,1);XCTAssertEqual(fresh.reads,1)
        XCTAssertEqual(model.candidates.first?.url.absoluteString,link);model.suppress()
    }
    func testDismissOwnerInvalidationAndTakeDoNotCreateExtraRead() async throws {
        let provider=ForegroundProvider(link),model=ForegroundClipboardPrompt()
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{!model.checking}
        let candidate=try XCTUnwrap(model.candidates.first)
        XCTAssertEqual(model.take(candidate),candidate.target)
        XCTAssertNil(model.take(candidate));XCTAssertTrue(model.candidates.isEmpty)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        XCTAssertEqual(provider.reads,1)
        model.phase(.background,provider:provider,allowsPresentation:{true})
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{!model.checking}
        model.suppress()
        model.phase(.active,provider:provider,allowsPresentation:{true})
        XCTAssertEqual(provider.reads,2);XCTAssertTrue(model.candidates.isEmpty)
    }
    func testInvalidOrUnavailableContentsAreSilentAndNotRetried() async {
        for value in [String?.none,"https://example.net/not-eh","bad"] {
            let provider=ForegroundProvider(value),model=ForegroundClipboardPrompt()
            model.phase(.active,provider:provider,allowsPresentation:{true})
            await until{!model.checking}
            XCTAssertTrue(model.candidates.isEmpty)
            model.phase(.inactive,provider:provider,allowsPresentation:{true})
            model.phase(.active,provider:provider,allowsPresentation:{true})
            XCTAssertEqual(provider.reads,1)
        }
    }
    func testOldUncooperativeExpiryCannotDismissNewForegroundHint() async {
        let provider=ForegroundProvider(link),clock=LateForegroundClock(),model=ForegroundClipboardPrompt(clock:clock)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{await clock.count==1}
        model.phase(.background,provider:provider,allowsPresentation:{true})
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{await clock.count==2}
        await clock.fire(0)
        for _ in 0..<20 {await Task.yield()}
        XCTAssertEqual(model.candidates.count,1);XCTAssertEqual(provider.reads,2)
        model.suppress();await clock.fire(1)
    }
    func testExpiryFailureHidesHintAndDoesNotReread() async {
        let provider=ForegroundProvider(link),model=ForegroundClipboardPrompt(clock:FailingForegroundClock())
        model.phase(.active,provider:provider,allowsPresentation:{true})
        await until{!model.checking && model.candidates.isEmpty}
        XCTAssertEqual(provider.reads,1)
        model.phase(.active,provider:provider,allowsPresentation:{true})
        XCTAssertEqual(provider.reads,1)
    }
    func testReaderRegistryIsPerTabGenerationAndPresentationIdentity() {
        let registry=ReaderPresentationTracker(),generation=UUID(),newGeneration=UUID(),a=UUID(),b=UUID(),other=UUID()
        registry.set(id:a,tab:0,generation:generation,visible:true)
        registry.set(id:b,tab:0,generation:generation,visible:true)
        registry.set(id:other,tab:2,generation:generation,visible:true)
        registry.set(id:a,tab:0,generation:generation,visible:false)
        XCTAssertTrue(registry.isReading(tab:0,generation:generation))
        XCTAssertFalse(registry.isReading(tab:1,generation:generation))
        XCTAssertFalse(registry.isReading(tab:0,generation:newGeneration))
        registry.set(id:b,tab:0,generation:generation,visible:false)
        XCTAssertFalse(registry.isReading(tab:0,generation:generation))
        XCTAssertTrue(registry.isReading(tab:2,generation:generation))
        registry.reset();XCTAssertFalse(registry.isReading(tab:2,generation:generation))
    }
}
