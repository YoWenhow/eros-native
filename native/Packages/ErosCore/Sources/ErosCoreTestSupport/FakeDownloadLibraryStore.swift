import Foundation
import ErosCore

/// Explicit behavior for every operation; never implicitly succeeds.
public struct FakeDownloadLibraryStore: DownloadLibraryStore {
    public let listFoldersHandler: @Sendable (AccountID) async throws -> [DownloadFolder]
    public let createFolderHandler: @Sendable (DownloadFolderName, AccountID) async throws -> DownloadFolder
    public let renameFolderHandler: @Sendable (DownloadFolderID, DownloadFolderName, DownloadLibraryRevision, AccountID) async throws -> Void
    public let reorderFoldersHandler: @Sendable ([DownloadFolderID], AccountID) async throws -> Void
    public let deleteFolderAndUnfileHandler: @Sendable (DownloadFolderID, DownloadLibraryRevision, AccountID) async throws -> Void
    public let moveItemsHandler: @Sendable ([UUID: DownloadLibraryRevision], DownloadFolderID?, AccountID) async throws -> Void
    public let listItemsHandler: @Sendable (DownloadLibraryTarget, AccountID) async throws -> [DownloadLibraryItem]
    public let loadSortHandler: @Sendable (DownloadLibraryTarget, AccountID) async throws -> DownloadSort
    public let saveSortHandler: @Sendable (DownloadLibraryTarget, DownloadSort, AccountID) async throws -> Void
    public let loadDefaultFolderHandler: @Sendable (AccountID) async throws -> DownloadFolderID?
    public let saveDefaultFolderHandler: @Sendable (DownloadFolderID?, AccountID) async throws -> Void
    public let updateMetadataHandler: @Sendable (UUID, DownloadLibraryMetadata, DownloadLibraryRevision, AccountID) async throws -> Void
    public init(
        listFolders: @escaping @Sendable (AccountID) async throws -> [DownloadFolder],
        createFolder: @escaping @Sendable (DownloadFolderName, AccountID) async throws -> DownloadFolder,
        renameFolder: @escaping @Sendable (DownloadFolderID, DownloadFolderName, DownloadLibraryRevision, AccountID) async throws -> Void,
        reorderFolders: @escaping @Sendable ([DownloadFolderID], AccountID) async throws -> Void,
        deleteFolderAndUnfile: @escaping @Sendable (DownloadFolderID, DownloadLibraryRevision, AccountID) async throws -> Void,
        moveItems: @escaping @Sendable ([UUID: DownloadLibraryRevision], DownloadFolderID?, AccountID) async throws -> Void,
        listItems: @escaping @Sendable (DownloadLibraryTarget, AccountID) async throws -> [DownloadLibraryItem],
        loadSort: @escaping @Sendable (DownloadLibraryTarget, AccountID) async throws -> DownloadSort,
        saveSort: @escaping @Sendable (DownloadLibraryTarget, DownloadSort, AccountID) async throws -> Void,
        loadDefaultFolder: @escaping @Sendable (AccountID) async throws -> DownloadFolderID?,
        saveDefaultFolder: @escaping @Sendable (DownloadFolderID?, AccountID) async throws -> Void,
        updateMetadata: @escaping @Sendable (UUID, DownloadLibraryMetadata, DownloadLibraryRevision, AccountID) async throws -> Void
    ) {
        self.listFoldersHandler = listFolders
        self.createFolderHandler = createFolder
        self.renameFolderHandler = renameFolder
        self.reorderFoldersHandler = reorderFolders
        self.deleteFolderAndUnfileHandler = deleteFolderAndUnfile
        self.moveItemsHandler = moveItems
        self.listItemsHandler = listItems
        self.loadSortHandler = loadSort
        self.saveSortHandler = saveSort
        self.loadDefaultFolderHandler = loadDefaultFolder
        self.saveDefaultFolderHandler = saveDefaultFolder
        self.updateMetadataHandler = updateMetadata
    }
    public func listFolders(account: AccountID) async throws -> [DownloadFolder] {
        try Task.checkCancellation()
        return try await listFoldersHandler(account)
    }
    public func createFolder(name: DownloadFolderName, account: AccountID) async throws -> DownloadFolder {
        try Task.checkCancellation()
        return try await createFolderHandler(name, account)
    }
    public func renameFolder(id: DownloadFolderID, name: DownloadFolderName, expectedRevision: DownloadLibraryRevision, account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await renameFolderHandler(id, name, expectedRevision, account)
    }
    public func reorderFolders(ids: [DownloadFolderID], account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await reorderFoldersHandler(ids, account)
    }
    public func deleteFolderAndUnfile(id: DownloadFolderID, expectedRevision: DownloadLibraryRevision, account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await deleteFolderAndUnfileHandler(id, expectedRevision, account)
    }
    public func moveItems(expectedMembershipRevisions: [UUID: DownloadLibraryRevision], destinationFolderID: DownloadFolderID?, account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await moveItemsHandler(expectedMembershipRevisions, destinationFolderID, account)
    }
    public func listItems(target: DownloadLibraryTarget, account: AccountID) async throws -> [DownloadLibraryItem] {
        try Task.checkCancellation()
        return try await listItemsHandler(target, account)
    }
    public func loadSort(target: DownloadLibraryTarget, account: AccountID) async throws -> DownloadSort {
        try Task.checkCancellation()
        return try await loadSortHandler(target, account)
    }
    public func saveSort(target: DownloadLibraryTarget, sort: DownloadSort, account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await saveSortHandler(target, sort, account)
    }
    public func loadDefaultFolder(account: AccountID) async throws -> DownloadFolderID? {
        try Task.checkCancellation()
        return try await loadDefaultFolderHandler(account)
    }
    public func saveDefaultFolder(folderID: DownloadFolderID?, account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await saveDefaultFolderHandler(folderID, account)
    }
    public func updateMetadata(jobID: UUID, metadata: DownloadLibraryMetadata, expectedMetadataRevision: DownloadLibraryRevision, account: AccountID) async throws -> Void {
        try Task.checkCancellation()
        return try await updateMetadataHandler(jobID, metadata, expectedMetadataRevision, account)
    }
}
