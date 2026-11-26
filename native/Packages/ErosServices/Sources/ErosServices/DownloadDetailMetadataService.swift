import Foundation
import ErosCore
import ErosPersistence

/// A ticket belongs to one detail request, account and captured set of existing jobs.
public struct DownloadDetailMetadataTicket: Sendable {
    let reference: GalleryReference
    let scope: SessionScope
    let revisions: [UUID: DownloadLibraryRevision]
}
public struct DownloadDetailMetadataService: Sendable {
    private let database: SQLiteDatabase
    private let sessions: any SessionProvider
    public init(database: SQLiteDatabase, sessions: any SessionProvider) {
        self.database = database; self.sessions = sessions
    }
    public func check(scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
    public func capture(reference: GalleryReference, scope: SessionScope) async throws -> DownloadDetailMetadataTicket {
        try await check(scope: scope); try reference.validate(scope: scope)
        let revisions = try await database.downloadMetadataRevisions(galleryID: reference.key.galleryID, account: scope.storage.accountID)
        try await check(scope: scope)
        return DownloadDetailMetadataTicket(reference: reference, scope: scope, revisions: revisions)
    }
    public func apply(_ metadata: DownloadLibraryMetadata, reference: GalleryReference, ticket: DownloadDetailMetadataTicket) async throws {
        guard reference == ticket.reference, metadata.state == .complete, metadata.sourceSite == reference.key.site else { throw AppError.scopeMismatch }
        for id in ticket.revisions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await check(scope: ticket.scope)
            do {
                try await database.updateMetadata(jobID: id, metadata: metadata, expectedMetadataRevision: ticket.revisions[id]!, account: ticket.scope.storage.accountID)
            } catch DownloadLibraryError.conflict {
                // A newer detail won. Never overwrite it using fetchedAt wall time.
            } catch DownloadLibraryError.jobNotFound {
                // Deletion wins; no INSERT and no retargeting to a re-created job.
            }
        }
        try await check(scope: ticket.scope)
    }
}
