import Foundation
import Observation
import ErosCore

public enum DownloadFolderManagementError: String, Sendable {
    case invalidName, duplicateName, conflict, missing, staleSession, storage
    public var message: String {
        switch self {
        case .invalidName: "名称须为1–60个字符，不能包含换行、斜杠或保留名称。"
        case .duplicateName: "此账号已有同名文件夹，请修改名称。"
        case .conflict: "文件夹已被修改，请重新载入后重试。"
        case .missing: "文件夹已不存在，请返回刷新。"
        case .staleSession: "会话已变化，请返回后重新打开。"
        case .storage: "未能保存，请检查存储空间后重试。"
        }
    }
}
@MainActor @Observable public final class DownloadFolderManagementModel {
    public private(set) var busy=false
    public private(set) var error: DownloadFolderManagementError?
    public let scope: SessionScope
    private let store: any DownloadLibraryStore
    private let sessions: any SessionProvider
    private let preferences: DownloadFolderPreferences
    public init(store: any DownloadLibraryStore, sessions: any SessionProvider, scope: SessionScope,
                preferences: DownloadFolderPreferences = .shared) {
        self.store=store; self.sessions=sessions; self.scope=scope
        self.preferences = preferences
    }
    private func check() async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy=true; error=nil; defer { busy=false }
        do { try await check(); try await operation(); try await check(); return true }
        catch is CancellationError { return false }
        catch {
            switch error {
            case DownloadLibraryError.invalidFolderName: self.error = .invalidName
            case DownloadLibraryError.duplicateFolderName: self.error = .duplicateName
            case DownloadLibraryError.conflict: self.error = .conflict
            case DownloadLibraryError.folderNotFound, DownloadLibraryError.ownershipMismatch: self.error = .missing
            case AppError.staleSession: self.error = .staleSession
            default: self.error = .storage
            }
            return false
        }
    }
    public func save(name: String, folder: DownloadFolder?) async -> Bool {
        await perform {
            let name=try DownloadFolderName(name)
            if let folder {
                guard folder.accountID == scope.storage.accountID else { throw DownloadLibraryError.ownershipMismatch }
                try await store.renameFolder(id:folder.id,name:name,expectedRevision:folder.revision,account:scope.storage.accountID) }
            else { _ = try await store.createFolder(name:name,account:scope.storage.accountID) }
        }
    }
    public func setColor(_ rgb: UInt32?, for folder: DownloadFolder) async -> Bool {
        await perform {
            let account = scope.storage.accountID
            if let rgb, rgb > 0xFFFFFF { throw AppError.invalidInput }
            guard folder.accountID == account else { throw DownloadLibraryError.ownershipMismatch }
            let folders = try await store.listFolders(account: account)
            guard folders.contains(where: { $0.id == folder.id }) else { throw DownloadLibraryError.folderNotFound }
            try await check()
            preferences.setColor(rgb, for: folder.id, account: account)
        }
    }

    public func delete(_ folder: DownloadFolder) async -> Bool {
        await perform {
            guard folder.accountID == scope.storage.accountID else { throw DownloadLibraryError.ownershipMismatch }
            try await store.deleteFolderAndUnfile(id:folder.id,expectedRevision:folder.revision,account:scope.storage.accountID)
            preferences.setColor(nil, for: folder.id, account: folder.accountID)
        }
    }
    public func reorder(_ ids: [DownloadFolderID]) async -> Bool {
        await perform { try await store.reorderFolders(ids:ids,account:scope.storage.accountID) }
    }
    public func reload(_ id: DownloadFolderID) async -> DownloadFolder? {
        var folder: DownloadFolder?
        let success = await perform {
            folder = try await store.listFolders(account:scope.storage.accountID).first { $0.id == id }
            if folder == nil { throw DownloadLibraryError.folderNotFound }
        }
        return success ? folder : nil
    }
}