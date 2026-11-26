import Foundation
import Observation
import ErosCore

public protocol DownloadEnqueuing: Sendable {
    func enqueue(_ summary: GallerySummary, scope: SessionScope, destinationFolderID: DownloadFolderID?, metadata: DownloadLibraryMetadata) async throws -> EnqueueResult
}
public protocol VariantDownloadEnqueuing: DownloadEnqueuing {
    func enqueue(_ summary: GallerySummary, scope: SessionScope, destinationFolderID: DownloadFolderID?, metadata: DownloadLibraryMetadata, variant: DownloadVariant) async throws -> EnqueueResult
}
extension DownloadCoordinator: VariantDownloadEnqueuing {}

@MainActor @Observable public final class DownloadDestinationModel {
    public private(set) var folders: [DownloadFolder] = []
    public private(set) var selectedFolderID: DownloadFolderID?
    public private(set) var existing: DownloadLibraryItem?
    public private(set) var result: EnqueueResult?
    public private(set) var variant: DownloadVariant = .display
    private var destinationInitialized = false
    public private(set) var loaded=false
    public private(set) var busy=false
    public private(set) var error: String?
    public private(set) var message: String?
    public let scope: SessionScope
    private let store: any DownloadLibraryStore
    private let sessions: any SessionProvider
    private let enqueuer: (any DownloadEnqueuing)?
    private let summary: GallerySummary?
    private let metadata: DownloadLibraryMetadata
    private let folderPreferences: DownloadFolderPreferences?
    public init(store: any DownloadLibraryStore, sessions: any SessionProvider, scope: SessionScope,
                enqueuer: (any DownloadEnqueuing)? = nil, summary: GallerySummary? = nil,
                metadata: DownloadLibraryMetadata = .unknown, folderPreferences: DownloadFolderPreferences? = nil) {
        self.store=store; self.sessions=sessions; self.scope=scope
        self.enqueuer=enqueuer; self.summary=summary; self.metadata=metadata
        self.folderPreferences = folderPreferences
    }
    public var selectedFolderMissing: Bool { selectedFolderID.map { id in !folders.contains { $0.id == id } } ?? false }
    public func select(_ id: DownloadFolderID?) { guard !busy else { return }; selectedFolderID=id; destinationInitialized=true; error=nil; message=nil }
    public func folderName(_ id: DownloadFolderID?) -> String {
        guard let id else { return "未分组" }
        return folders.first { $0.id == id }?.displayName.value ?? "文件夹已删除，请重新选择"
    }
    private func check() async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy=true; error=nil; message=nil; defer { busy=false }
        do { try await check(); try await operation(); try await check(); return true }
        catch is CancellationError { return false }
        catch {
            switch error {
            case AppError.staleSession: self.error="会话已变化，请关闭后重新打开。"
            case AppError.invalidInput: self.error="详情没有可用页数，或当前输入无效，请刷新详情后重试。"
            case DownloadLibraryError.invalidFolderName: self.error=DownloadFolderManagementError.invalidName.message
            case DownloadLibraryError.duplicateFolderName: self.error=DownloadFolderManagementError.duplicateName.message
            case DownloadLibraryError.folderNotFound, DownloadLibraryError.ownershipMismatch: self.error="所选文件夹已不存在或不可用，请刷新并重新选择。"
            case DownloadLibraryError.conflict: self.error="已有下载的归属已变化，请刷新后确认再操作。"
            case AppError.notFound: self.error="已有下载已被删除，请刷新后重试。"
            default: self.error="操作未完成，请刷新核对后重试；不会自动移动已有下载。"
            }
            return false
        }
    }
    private func findExisting() async throws -> DownloadLibraryItem? {
        guard let summary else { return nil }
        return try await store.pageDownloadItem(galleryID: summary.reference.key.galleryID,
                                                account: scope.storage.accountID, variant: variant)
    }
    public var existingDownloadMessage: String? {
        guard let existing else { return nil }
        let quality = existing.variant == .original ? "原图" : "普通图"
        if existing.variant != variant { return "已有\(quality)逐页任务，此次保留原画质。" }
        return "已有\(quality)逐页任务，保留原文件夹和加入时间。"
    }
    public func load() async {
        _ = await perform {
            let folders=try await store.listFolders(account:scope.storage.accountID)
            let initialDefault = destinationInitialized ? nil : try await store.loadDefaultFolder(account: scope.storage.accountID)
            let existing=try await findExisting()
            try await check()
            self.folders=folders; self.existing=existing
            if !destinationInitialized {
                if let folderPreferences {
                    selectedFolderID = folderPreferences.initialFolderID(
                        defaultFolderID: initialDefault, folders: folders, account: scope.storage.accountID)
                } else {
                    selectedFolderID = initialDefault
                }
                destinationInitialized = true
            }
            loaded=true
        }
    }
    public func selectVariant(_ value: DownloadVariant) async {
        guard !busy, variant != value else { return }
        variant=value; existing=nil; result=nil; loaded=false; error=nil; message=nil
        await load()
    }
    public func createFolder(name: String) async -> Bool {
        guard loaded else { return false }
        return await perform {
            let folder=try await store.createFolder(name:DownloadFolderName(name),account:scope.storage.accountID)
            try await check()
            folders.append(folder); selectedFolderID=folder.id; destinationInitialized=true
            message="已创建并选中文件夹；关闭此页面会保留这个空文件夹。"
        }
    }
    private func validateDestination() async throws {
        let latest=try await store.listFolders(account:scope.storage.accountID)
        try await check(); folders=latest
        if let selectedFolderID, !latest.contains(where: { $0.id == selectedFolderID }) { throw DownloadLibraryError.folderNotFound }
    }
    @discardableResult public func start() async -> Bool {
        guard loaded, result == nil, let summary, let enqueuer else { return false }
        return await perform {
            if let found=try await findExisting() {
                try await check(); existing=found; result = .existing(found.jobID)
                message=existingDownloadMessage; return
            }
            guard let count=summary.pageCount, count.value > 0, count.value <= 100_000 else { throw AppError.invalidInput }
            try await validateDestination(); try await check()
            let result: EnqueueResult
            if variant == .original {
                guard let variants=enqueuer as? any VariantDownloadEnqueuing else { throw AppError.originalUnavailable }
                result=try await variants.enqueue(summary,scope:scope,destinationFolderID:selectedFolderID,metadata:metadata,variant:.original)
            } else { result=try await enqueuer.enqueue(summary,scope:scope,destinationFolderID:selectedFolderID,metadata:metadata) }
            try await check(); self.result=result
            if case .inserted = result {
                folderPreferences?.remember(selectedFolderID, account: scope.storage.accountID)
            }
            let found=try await findExisting(); try await check(); existing=found
            switch result {
            case .inserted: message="已加入下载，可打开任务查看进度。"
            case .existing: message=existingDownloadMessage
            }
        }
    }
    public func moveExisting() async {
        guard loaded, let existing else { return }
        _ = await perform {
            try await validateDestination(); try await check()
            try await store.moveItems(expectedMembershipRevisions:[existing.jobID:existing.membershipRevision],destinationFolderID:selectedFolderID,account:scope.storage.accountID)
            try await check()
            let found=try await findExisting(); try await check(); self.existing=found
            message="已移动已有下载，加入时间和图片保持不变。"
        }
    }
    public func saveDefault() async -> Bool {
        guard loaded, summary == nil else { return false }
        return await perform {
            try await validateDestination(); try await check()
            try await store.saveDefaultFolder(folderID:selectedFolderID,account:scope.storage.accountID)
            try await check(); message="默认下载文件夹已保存。"
        }
    }
}
