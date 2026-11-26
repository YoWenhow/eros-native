import Foundation
import Observation

/// A source-owned action: duplicate taps merge, cancelled or stale completions cannot commit.
@MainActor @Observable public final class LinkOpenCoordinator<Value> {
    public private(set) var busy=false
    private var request:UUID?
    private var work:Task<Void,Never>?
    public init() {}
    @discardableResult public func start(resolve:@escaping @MainActor () async throws -> Value,
        current:@escaping @MainActor () -> Bool,commit:@escaping @MainActor (Value) -> Void,
        failed:@escaping @MainActor (any Error) -> Void) -> Bool {
        guard !busy else{return false}
        let id=UUID();request=id;busy=true
        work=Task {
            defer {if request==id {busy=false;work=nil;request=nil}}
            do {
                let value=try await resolve()
                try Task.checkCancellation()
                guard request==id,current() else{return}
                commit(value)
            } catch is CancellationError {} catch {
                if request==id,current(),!Task.isCancelled {failed(error)}
            }
        }
        return true
    }
    public func cancel() {request=nil;work?.cancel();work=nil;busy=false}
}
