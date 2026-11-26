import Foundation
import Observation
import ErosCore

@MainActor @Observable public final class MoveDownloadsModel {
    private enum LoadFailure: Error { case unavailable }
    public let destination: DownloadDestinationModel
    public let jobIDs: Set<UUID>
    public private(set) var busy=false
    public private(set) var ready=false
    public private(set) var moved=false
    public private(set) var error: String?
    private var revisions: [UUID:DownloadLibraryRevision]
    private let validOwners: Bool
    private let initialFolderID: DownloadFolderID?
    private let scope: SessionScope
    private let store: any DownloadLibraryStore
    private let sessions: any SessionProvider
    public init(items: [DownloadLibraryItem], store: any DownloadLibraryStore, sessions: any SessionProvider, scope: SessionScope) {
        self.store=store; self.sessions=sessions; self.scope=scope
        jobIDs=Set(items.map(\.jobID))
        revisions=Dictionary(items.map { ($0.jobID,$0.membershipRevision) },uniquingKeysWith:{ first,_ in first })
        validOwners=items.allSatisfy { $0.owner == scope.storage.accountID }
        let folders=Set(items.map(\.folderID)); initialFolderID=folders.count == 1 ? items.first?.folderID : nil
        destination=DownloadDestinationModel(store:store,sessions:sessions,scope:scope)
    }
    private func check() async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        guard validOwners else { throw DownloadLibraryError.ownershipMismatch }
        guard !jobIDs.isEmpty else { throw AppError.invalidInput }
        try Task.checkCancellation()
    }
    private func perform(_ action: () async throws -> Void) async -> Bool {
        guard !busy, !destination.busy, !moved else { return false }
        busy=true; error=nil; defer { busy=false }
        do { try await check(); try await action(); try await check(); return true }
        catch is CancellationError { return false }
        catch {
            switch error {
            case AppError.staleSession: self.error="会话已变化，请关闭后重新选择任务。"
            case DownloadLibraryError.conflict: self.error="部分任务已被移动，本次未提交；请刷新所选任务后重新确认。"
            case DownloadLibraryError.jobNotFound: self.error="部分任务已被删除，本次未提交；请关闭后重新选择，不能只移动剩余任务。"
            case DownloadLibraryError.folderNotFound: self.error="目标文件夹已删除，本次未提交；请刷新文件夹并重新选择。"
            case DownloadLibraryError.ownershipMismatch: self.error="所选任务不属于当前账号，本次未提交。"
            case AppError.invalidInput: self.error="请先选择至少一个下载任务。"
            default: self.error="移动未能确认，请刷新核对后重试；不会显示部分成功。"
            }
            return false
        }
    }
    public func load() async {
        _ = await perform {
            await destination.load(); try await check()
            guard destination.loaded, destination.error == nil else { throw LoadFailure.unavailable }
            if !ready { destination.select(initialFolderID) }
            ready=true
        }
    }
    /// Explicit conflict recovery; never shrink the user's frozen set of IDs.
    public func refreshMembers() async {
        _ = await perform {
            let items=try await store.listItems(target:.all,account:scope.storage.accountID).filter { jobIDs.contains($0.jobID) }
            try await check()
            guard Set(items.map(\.jobID)) == jobIDs else { throw DownloadLibraryError.jobNotFound }
            revisions=Dictionary(uniqueKeysWithValues:items.map { ($0.jobID,$0.membershipRevision) })
        }
    }
    public func move() async -> Bool {
        guard ready else { return false }
        let target=destination.selectedFolderID
        let success=await perform {
            try await store.moveItems(expectedMembershipRevisions:revisions,destinationFolderID:target,account:scope.storage.accountID)
            try await check()
        }
        if success { moved=true }
        return success
    }
}
