import Foundation

public enum DownloadLibraryError: String, Error, Codable, Equatable, Sendable {
    case invalidFolderName, duplicateFolderName, folderNotFound, jobNotFound, ownershipMismatch, conflict
    case primaryHasRetainedCopies
}
public struct DownloadFolderID: ValidatedValue {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}
public struct DownloadLibraryRevision: ValidatedValue {
    public let value: Int64
    public init(_ value: Int64) throws {
        guard value > 0 else { throw AppError.invalidInput }
        self.value = value
    }
}
/// UTC Unix milliseconds, never a guessed legacy date. Negative epochs are valid.
public struct DownloadLibraryTimestamp: ValidatedValue {
    public let value: Int64
    public init(_ value: Int64) { self.value = value }
}
public struct DownloadFolderName: ValidatedValue {
    public let value: String
    public var normalizedName: String { DownloadLibraryText.asciiLowercase(value) }
    public init(_ value: String) throws {
        // Reject control/newline characters before trimming. Preserve emoji joiners.
        guard !value.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }), !value.contains("/"), !value.contains("\\") else { throw DownloadLibraryError.invalidFolderName }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...60).contains(name.count), name != "全部下载", name != "未分组" else { throw DownloadLibraryError.invalidFolderName }
        self.value = name
    }
}
public enum DownloadLibraryTarget: Codable, Hashable, Sendable {
    case all, unfiled, unfinished, folder(DownloadFolderID)

    /// The unfinished collection filters All Downloads and shares its saved sort.
    public var storageKey: String {
        switch self {
        case .all, .unfinished: "all"
        case .unfiled: "unfiled"
        case .folder(let id): "folder:" + id.value.uuidString
        }
    }
}
public enum DownloadSortField: String, Codable, CaseIterable, Sendable { case artist, group, addedAt }
public enum DownloadSortDirection: String, Codable, CaseIterable, Sendable { case ascending, descending }
public struct DownloadSort: Codable, Equatable, Sendable {
    public let field: DownloadSortField
    public let direction: DownloadSortDirection
    public init(field: DownloadSortField = .addedAt, direction: DownloadSortDirection? = nil) {
        self.field = field
        self.direction = direction ?? (field == .addedAt ? .descending : .ascending)
    }
}
public enum DownloadMetadataState: String, Codable, Sendable { case unknown, complete }
public enum DownloadCompletionTimePolicy: String, Codable, Sendable { case preserveLegacyUnknown, recordFirstObserved }
public enum DownloadCompletionTimeOrigin: String, Codable, Sendable { case unknown, nativeObserved }
public enum EnqueueResult: Codable, Equatable, Sendable { case inserted(UUID), existing(UUID) }

public struct DownloadFolder: Codable, Equatable, Sendable {
    public let id: DownloadFolderID
    public let accountID: AccountID
    public let displayName: DownloadFolderName
    public let position: NonnegativeCount
    public let createdAt: DownloadLibraryTimestamp
    public let updatedAt: DownloadLibraryTimestamp
    public let revision: DownloadLibraryRevision
    public init(id: DownloadFolderID, accountID: AccountID, displayName: DownloadFolderName, position: NonnegativeCount, createdAt: DownloadLibraryTimestamp, updatedAt: DownloadLibraryTimestamp, revision: DownloadLibraryRevision) throws {
        self.id = id
        self.accountID = accountID
        self.displayName = displayName
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }
    private enum CodingKeys: String, CodingKey { case id, accountID, displayName, position, createdAt, updatedAt, revision }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(DownloadFolderID.self, forKey: .id),
            accountID: c.decode(AccountID.self, forKey: .accountID),
            displayName: c.decode(DownloadFolderName.self, forKey: .displayName),
            position: c.decode(NonnegativeCount.self, forKey: .position),
            createdAt: c.decode(DownloadLibraryTimestamp.self, forKey: .createdAt),
            updatedAt: c.decode(DownloadLibraryTimestamp.self, forKey: .updatedAt),
            revision: c.decode(DownloadLibraryRevision.self, forKey: .revision)
        )
    }
}

public struct DownloadLibraryMetadata: Codable, Equatable, Sendable {
    public let artists: [String]
    public let groups: [String]
    public let state: DownloadMetadataState
    public let sourceSite: Site?
    public let fetchedAt: DownloadLibraryTimestamp?
    public init(artists: [String], groups: [String], state: DownloadMetadataState, sourceSite: Site?, fetchedAt: DownloadLibraryTimestamp?) throws {
        switch state {
        case .unknown:
            guard artists.isEmpty, groups.isEmpty, sourceSite == nil, fetchedAt == nil else { throw AppError.invalidInput }
        case .complete:
            guard sourceSite != nil, fetchedAt != nil else { throw AppError.invalidInput }
        }
        self.artists = artists
        self.groups = groups
        self.state = state
        self.sourceSite = sourceSite
        self.fetchedAt = fetchedAt
    }
    private enum CodingKeys: String, CodingKey { case artists, groups, state, sourceSite, fetchedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            artists: c.decode([String].self, forKey: .artists),
            groups: c.decode([String].self, forKey: .groups),
            state: c.decode(DownloadMetadataState.self, forKey: .state),
            sourceSite: c.decodeIfPresent(Site.self, forKey: .sourceSite),
            fetchedAt: c.decodeIfPresent(DownloadLibraryTimestamp.self, forKey: .fetchedAt)
        )
    }
}

extension DownloadLibraryMetadata {
    public static var unknown: Self { try! Self(artists: [], groups: [], state: .unknown, sourceSite: nil, fetchedAt: nil) }
}

public struct DownloadLibraryItem: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let storedBytes: NonnegativeCount
    public let sourceKind: DownloadSourceKind
    public let variant: DownloadVariant
    public let owner: AccountID
    public let folderID: DownloadFolderID?
    public let summary: GallerySummary
    public let state: DownloadJobState
    public let completedPages: NonnegativeCount
    public let totalPages: NonnegativeCount
    public let skippedPages: NonnegativeCount
    public var progressTotal: Int { totalPages.value - skippedPages.value }
    public let addedAt: DownloadLibraryTimestamp?
    public let firstCompletedAt: DownloadLibraryTimestamp?
    public let completionTimePolicy: DownloadCompletionTimePolicy
    public let completionTimeOrigin: DownloadCompletionTimeOrigin
    public let membershipRevision: DownloadLibraryRevision
    public let metadataRevision: DownloadLibraryRevision
    public let metadata: DownloadLibraryMetadata
    public init(jobID: UUID, owner: AccountID, folderID: DownloadFolderID?, summary: GallerySummary, state: DownloadJobState, completedPages: NonnegativeCount, totalPages: NonnegativeCount, addedAt: DownloadLibraryTimestamp?, firstCompletedAt: DownloadLibraryTimestamp?, completionTimePolicy: DownloadCompletionTimePolicy, completionTimeOrigin: DownloadCompletionTimeOrigin, membershipRevision: DownloadLibraryRevision, metadataRevision: DownloadLibraryRevision, metadata: DownloadLibraryMetadata, skippedPages: NonnegativeCount = try! NonnegativeCount(0), sourceKind: DownloadSourceKind = .pages, variant: DownloadVariant = .display, storedBytes: NonnegativeCount = try! NonnegativeCount(0)) throws {
        guard totalPages.value > 0, skippedPages.value <= totalPages.value, completedPages.value <= totalPages.value - skippedPages.value,
              state != .completed || completedPages.value == totalPages.value - skippedPages.value,
              summary.pageCount == nil || summary.pageCount == totalPages,
              (firstCompletedAt == nil) == (completionTimeOrigin == .unknown),
              completionTimePolicy != .preserveLegacyUnknown || firstCompletedAt == nil
        else { throw AppError.invalidInput }
        self.storedBytes = storedBytes
        self.sourceKind = sourceKind; self.variant = variant
        self.jobID = jobID
        self.owner = owner
        self.folderID = folderID
        self.summary = summary
        self.state = state
        self.completedPages = completedPages
        self.totalPages = totalPages
        self.skippedPages = skippedPages
        self.addedAt = addedAt
        self.firstCompletedAt = firstCompletedAt
        self.completionTimePolicy = completionTimePolicy
        self.completionTimeOrigin = completionTimeOrigin
        self.membershipRevision = membershipRevision
        self.metadataRevision = metadataRevision
        self.metadata = metadata
    }
    private enum CodingKeys: String, CodingKey { case jobID, owner, folderID, summary, state, completedPages, totalPages, addedAt, firstCompletedAt, completionTimePolicy, completionTimeOrigin, membershipRevision, metadataRevision, metadata, skippedPages, sourceKind, variant, storedBytes }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            jobID: c.decode(UUID.self, forKey: .jobID),
            owner: c.decode(AccountID.self, forKey: .owner),
            folderID: c.decodeIfPresent(DownloadFolderID.self, forKey: .folderID),
            summary: c.decode(GallerySummary.self, forKey: .summary),
            state: c.decode(DownloadJobState.self, forKey: .state),
            completedPages: c.decode(NonnegativeCount.self, forKey: .completedPages),
            totalPages: c.decode(NonnegativeCount.self, forKey: .totalPages),
            addedAt: c.decodeIfPresent(DownloadLibraryTimestamp.self, forKey: .addedAt),
            firstCompletedAt: c.decodeIfPresent(DownloadLibraryTimestamp.self, forKey: .firstCompletedAt),
            completionTimePolicy: c.decode(DownloadCompletionTimePolicy.self, forKey: .completionTimePolicy),
            completionTimeOrigin: c.decode(DownloadCompletionTimeOrigin.self, forKey: .completionTimeOrigin),
            membershipRevision: c.decode(DownloadLibraryRevision.self, forKey: .membershipRevision),
            metadataRevision: c.decode(DownloadLibraryRevision.self, forKey: .metadataRevision),
            metadata: c.decode(DownloadLibraryMetadata.self, forKey: .metadata),
            skippedPages: c.decodeIfPresent(NonnegativeCount.self, forKey: .skippedPages) ?? NonnegativeCount(0),
            sourceKind: c.decodeIfPresent(DownloadSourceKind.self, forKey: .sourceKind) ?? .pages,
            variant: c.decodeIfPresent(DownloadVariant.self, forKey: .variant) ?? .display,
            storedBytes: c.decodeIfPresent(NonnegativeCount.self, forKey: .storedBytes) ?? NonnegativeCount(0)
        )
    }
}

extension DownloadLibraryItem {
    public var sortKeyVersion: Int { DownloadLibrarySort.version }
    public var hasUnknownInformation: Bool { metadata.state == .unknown || summary.sourceTitles == nil }
}

/// Account-level library only. Adapters must check ownership, CAS and cancellation.
/// Moves are atomic; an empty selection is a no-op. Reads must not hide failures.
/// Missing preferences return DownloadSort() / nil; a missing entity is an error.
public protocol DownloadLibraryStore: Sendable {
    func listFolders(account: AccountID) async throws -> [DownloadFolder]
    func createFolder(name: DownloadFolderName, account: AccountID) async throws -> DownloadFolder
    func renameFolder(id: DownloadFolderID, name: DownloadFolderName, expectedRevision: DownloadLibraryRevision, account: AccountID) async throws -> Void
    func reorderFolders(ids: [DownloadFolderID], account: AccountID) async throws -> Void
    func deleteFolderAndUnfile(id: DownloadFolderID, expectedRevision: DownloadLibraryRevision, account: AccountID) async throws -> Void
    func moveItems(expectedMembershipRevisions: [UUID: DownloadLibraryRevision], destinationFolderID: DownloadFolderID?, account: AccountID) async throws -> Void
    func listItems(target: DownloadLibraryTarget, account: AccountID) async throws -> [DownloadLibraryItem]
    func pageDownloadItem(galleryID: GalleryID, account: AccountID, variant: DownloadVariant) async throws -> DownloadLibraryItem?
    func loadSort(target: DownloadLibraryTarget, account: AccountID) async throws -> DownloadSort
    func saveSort(target: DownloadLibraryTarget, sort: DownloadSort, account: AccountID) async throws -> Void
    func loadDefaultFolder(account: AccountID) async throws -> DownloadFolderID?
    func saveDefaultFolder(folderID: DownloadFolderID?, account: AccountID) async throws -> Void
    func updateMetadata(jobID: UUID, metadata: DownloadLibraryMetadata, expectedMetadataRevision: DownloadLibraryRevision, account: AccountID) async throws -> Void
}

public extension DownloadLibraryStore {
    func pageDownloadItem(galleryID: GalleryID, account: AccountID, variant: DownloadVariant) async throws -> DownloadLibraryItem? {
        try await listItems(target: .all, account: account)
            .filter { $0.summary.reference.key.galleryID == galleryID && $0.sourceKind == .pages && $0.variant == variant }
            .min { $0.jobID.uuidString < $1.jobID.uuidString }
    }
}

// A successful complete detail with no matching namespaces is known-empty, not unknown.
extension DownloadLibraryMetadata {
    public static func from(detail: GalleryDetail, fetchedAt: DownloadLibraryTimestamp) throws -> Self {
        try Self(artists: detail.tags.filter { $0.namespace == "artist" }.flatMap(\.tags),
                 groups: detail.tags.filter { $0.namespace == "group" }.flatMap(\.tags),
                 state: .complete, sourceSite: detail.summary.reference.key.site, fetchedAt: fetchedAt)
    }
}
