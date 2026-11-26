import Foundation

/// Class C files remain available across ordinary locks after the first unlock.
public struct ProtectedStorageAccess: Sendable {
    private var unlockedSinceLaunch = false

    public init() {}

    public mutating func permitsAccess(dataAvailable: Bool, canReadAfterFirstUnlockFile: () -> Bool) -> Bool {
        if !unlockedSinceLaunch {
            unlockedSinceLaunch = dataAvailable || canReadAfterFirstUnlockFile()
        }
        return unlockedSinceLaunch
    }
}

public struct LibraryStartupContext:Sendable {
    public enum Action:Sendable {case prepare,loadOnline,none}
    public let initialized:Bool
    public let permitsNetwork:Bool
    public let preparationFailed:Bool
    public let profileSwitching:Bool
    public let preparing:Bool
    public init(initialized:Bool,permitsNetwork:Bool,preparationFailed:Bool,profileSwitching:Bool,preparing:Bool=false){
        self.initialized=initialized;self.permitsNetwork=permitsNetwork;self.preparationFailed=preparationFailed;self.profileSwitching=profileSwitching;self.preparing=preparing
    }
    public var action:Action {
        if profileSwitching || preparing{return .none}
        if !initialized{return .prepare}
        // A ready local library is a valid mode, even if an older UI still has
        // an online-access error. Tab appearances must not prepare it again.
        if !permitsNetwork{return .none}
        return preparationFailed ? .prepare : .loadOnline
    }
    // Infrastructure alone is insufficient: verification can still advance the scope.
    public var canOpenLocalLibrary:Bool {initialized && !preparing && !profileSwitching}
    public var canRequestNetwork:Bool {canOpenLocalLibrary && permitsNetwork && !preparationFailed}
}

/// App-owned work outlives view task cancellation. Concurrent callers join one run.
@MainActor public final class AppStartupTask {
    private var task:Task<Void,Never>?
    public init() {}
    public func runLibrary(context:@escaping @MainActor ()->LibraryStartupContext,
        prepare:@escaping @MainActor () async->Void,loadOnline:@escaping @MainActor () async->Void) async {
        await run {
            switch context().action {
            case .prepare:await prepare()
            case .loadOnline:await loadOnline()
            case .none:break
            }
        }
    }
    public func run(_ operation:@escaping @MainActor () async -> Void) async {
        if let task { await task.value;return }
        let work=Task { await operation();self.task=nil }
        task=work
        await work.value
    }
}
