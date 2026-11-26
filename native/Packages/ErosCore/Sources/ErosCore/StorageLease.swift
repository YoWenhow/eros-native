import Foundation
import Synchronization

/// One service generation. Revocation is permanent. Admitted work must leave
/// before its resources can be checkpointed and closed.
public final class StorageLease: Sendable {
    public let id = UUID()

    private struct State {
        var active = true
        var operations = 0
        var drained: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    public var isActive: Bool { state.withLock { $0.active } }

    public init() {}

    public func check() throws {
        guard isActive else { throw AppError.cancelled }
    }

    public func admit() throws {
        try state.withLock {
            guard $0.active else { throw AppError.cancelled }
            $0.operations += 1
        }
    }

    public func finish() {
        let completions: [CheckedContinuation<Void, Never>] = state.withLock {
            precondition($0.operations > 0)
            $0.operations -= 1
            guard $0.operations == 0 else { return [] }
            let waiters = $0.drained
            $0.drained.removeAll()
            return waiters
        }
        for completion in completions { completion.resume() }
    }

    public func revoke() {
        state.withLock { $0.active = false }
    }

    public func waitForDrain() async {
        await withCheckedContinuation { continuation in
            let drained = state.withLock { state in
                precondition(!state.active)
                if state.operations == 0 { return true }
                state.drained.append(continuation)
                return false
            }
            if drained { continuation.resume() }
        }
    }
}
