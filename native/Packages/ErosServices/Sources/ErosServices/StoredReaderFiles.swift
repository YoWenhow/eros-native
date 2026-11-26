import Foundation
import ErosCore
import ErosPersistence

public struct StoredReaderFiles: LocalReaderFiles {
    public var pinsSelectionPerDocument: Bool { true }
    public let database: SQLiteDatabase
    public let root: URL
    private let storageLease: StorageLease?
    private let publicRoot: PublicDownloadRoot?
    public init(database: SQLiteDatabase, root: URL, storageLease: StorageLease? = nil, publicRoot: PublicDownloadRoot? = nil) {
        self.database = database
        self.root = root
        self.storageLease = storageLease
        self.publicRoot = publicRoot
    }
    public func file(reference: GalleryReference, index: PageIndex, scope: StorageScope) async throws -> URL? {
        try await selection(reference: reference, scope: scope).file(index)
    }
    public func selection(reference: GalleryReference, scope: StorageScope) async throws -> LocalReaderSelection {
        try storageLease?.check()
        let id = try await database.onlineDisplayJobID(galleryID: reference.key.galleryID, account: scope.accountID)
        let loadPage: @Sendable (PageIndex) async throws -> DownloadPage? = { index in
            guard let id else { return nil }
            let page = try await database.completedReaderPage(jobID: id, galleryID: reference.key.galleryID,
                                                              index: index, account: scope.accountID)
            try storageLease?.check()
            return page
        }
        if let publicRoot {
            let readVerified: @Sendable (PageIndex) async throws -> (URL, Data)? = { index in
                guard let id, let page = try await loadPage(index) else { return nil }
                try publicRoot.check()
                let canonical = "\(page.jobID.uuidString)/\(page.index.value).img"
                let url = root.appendingPathComponent(canonical)
                guard page.relativePath?.value == canonical,
                      let bytes = try? StorageDocuments.read(url, maximumBytes: ImagePipeline.maximumBytes),
                      publicRoot.matches(bytes, page: page) else {
                    try? await database.reportDownloadFileReadFailure(jobID: id, account: scope.accountID)
                    return nil
                }
                try publicRoot.check()
                return (url, bytes)
            }
            return LocalReaderSelection(jobID: id, verifiedBytes: { try await readVerified($0)?.1 },
                                        file: { try await readVerified($0)?.0 })
        }
        return LocalReaderSelection(jobID: id) { index in
            guard let page = try await loadPage(index) else { return nil }
            return try ownedFile(page)
        }
    }

    private func ownedFile(_ page: DownloadPage) throws -> URL? {
        guard let path = page.relativePath else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = base.appendingPathComponent(path.value).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw AppError.accessDenied }
        guard let attributes = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.fileSize == page.size?.value else { return nil }
        return target
    }
}
