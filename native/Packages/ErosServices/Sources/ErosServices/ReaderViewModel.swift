import Foundation
import Observation
import ErosCore
import ErosPersistence

public enum ReaderDecodeFailure: String, Error, Sendable {
    case source = "R_DECODE_SOURCE"
    case incomplete = "R_DECODE_INCOMPLETE"
    case dimensions = "R_DECODE_DIMENSIONS"
    case pixels = "R_DECODE_PIXELS"
}

@MainActor @Observable
public final class ReaderViewModel {
    public private(set) var index: PageIndex
    public private(set) var count = 0
    public private(set) var bytes: Data?
    public private(set) var contentDigest: String?
    public private(set) var blockedImage: BlockImageEntry?
    private let imageBlocks: ImageBlockService?
    public private(set) var loading = false
    public private(set) var error: AppError?
    public private(set) var parseFailureCode: String?
    public private(set) var imageFailureCode: String?
    public private(set) var recoveringImage = false
    public private(set) var progressFailed = false
    public var mode: ReadingMode = .leftToRight
    public let document: ReaderDocument
    private let pipeline: ImagePipeline
    private let database: SQLiteDatabase
    private let sessions: SessionGuard
    private let sessionProvider: any SessionProvider
    private var revision = UUID()
    private var displayRevision = UUID()
    private var decodedIndex: PageIndex?
    public var isOffline: Bool { pipeline.isOffline }

    public func pageModel(index: PageIndex) -> ReaderViewModel {
        let model = ReaderViewModel(document: document, pipeline: pipeline, database: database,
            sessions: sessionProvider, index: index, imageBlocks: imageBlocks)
        model.count = count
        return model
    }
    /// Native bitmap cache is scoped to this reader. Recheck session before
    /// accepting a cache hit as displayed content or writing its progress.
    public func restoreDecoded(index: PageIndex, digest: String? = nil) async -> Bool {
        let ticket = UUID(); revision = ticket; displayRevision = UUID()
        self.index = index; bytes = nil; decodedIndex = nil; contentDigest = nil; blockedImage = nil
        error = nil; parseFailureCode = nil; imageFailureCode = nil; loading = false
        do {
            try await sessions.check(document.scope)
            try Task.checkCancellation()
            guard revision == ticket, index.value < count else { return false }
            if let imageBlocks {
                guard let digest else { return false }
                let match = try await imageBlocks.match(digest: digest, owner: document.scope.storage.accountID)
                try await sessions.check(document.scope)
                guard revision == ticket else { return false }
                contentDigest = digest
                blockedImage = match
            }
            decodedIndex = index; return true
        } catch {
            if revision == ticket { self.error = error as? AppError ?? .cancelled }
            return false
        }
    }
    /// Prepare the catalogue count without fetching an image (vertical resume).
    public func prepare() async {
        let ticket = UUID(); revision = ticket; loading = true; error = nil
        defer { if revision == ticket { loading = false } }
        do {
            try await sessions.check(document.scope)
            await document.seed(try await database.gallery(galleryID: document.reference.key.galleryID, scope: document.scope.storage))
            let summary = try await document.prepare()
            try await sessions.check(document.scope)
            guard revision == ticket else { return }
            guard let total = summary.pageCount, index.value < total.value else { throw AppError.invalidInput }
            try await database.saveGallery(summary, scope: document.scope.storage)
            guard revision == ticket else { return }; count = total.value
        } catch is CancellationError {} catch {
            if revision == ticket { self.error = error as? AppError ?? .parseMismatch }
        }
    }
    public init(document: ReaderDocument, pipeline: ImagePipeline, database: SQLiteDatabase, sessions: any SessionProvider,
                index: PageIndex, imageBlocks: ImageBlockService? = nil) {
        self.imageBlocks = imageBlocks
        self.document = document; self.pipeline = pipeline; self.database = database
        self.sessions = SessionGuard(provider: sessions); self.sessionProvider = sessions; self.index = index
    }
    public func load(index: PageIndex, retry: Bool = false) async {
        let ticket = UUID(); revision = ticket
        self.index = index; decodedIndex = nil; bytes = nil; contentDigest = nil; blockedImage = nil; error = nil; parseFailureCode = nil; imageFailureCode = nil; loading = true
        defer { if revision == ticket { loading = false } }
        do {
            try await sessions.check(document.scope)
            // Once prepared, a fixed offline job can read another page without
            // querying and writing the same gallery metadata for each bitmap.
            if !isOffline || count == 0 {
                let cached = try await database.gallery(galleryID: document.reference.key.galleryID, scope: document.scope.storage)
                await document.seed(cached)
                let summary = try await document.prepare()
                try Task.checkCancellation()
                guard revision == ticket else { return }
                count = summary.pageCount!.value
                guard index.value < count else { throw AppError.invalidInput }
                try await database.saveGallery(summary, scope: document.scope.storage)
            }
            guard index.value < count else { throw AppError.invalidInput }
            let data = try await pipeline.load(document: document, index: index, bypassCache: retry)
            try await sessions.check(document.scope)
            guard revision == ticket else { return }
            bytes = data
        } catch is CancellationError {} catch AppError.cancelled {} catch let failure as ReaderAccessFailure {
            if revision == ticket { error = .accessDenied; imageFailureCode = failure.stage.rawValue }
        } catch let failure as ImagePageFailure {
            if revision == ticket { error = .parseMismatch; parseFailureCode = failure.stage.rawValue }
        } catch {
            if revision == ticket { self.error = error as? AppError ?? .unsupportedContent }
        }
    }
    /// Recover a transient response/decode failure once. No retry for cancellation,
    /// session/quota errors or known dimensions outside the decoder's limits.
    public func loadDecoded<Value: Sendable>(index: PageIndex, retry: Bool = false,
        decode: @Sendable (Data) async throws -> Value) async -> Value? {
        let operation = UUID(); displayRevision = operation; recoveringImage = false
        defer { if displayRevision == operation { recoveringImage = false } }
        for attempt in 0...1 {
            guard !Task.isCancelled, displayRevision == operation else { return nil }
            await load(index: index, retry: retry || attempt > 0)
            guard !Task.isCancelled, displayRevision == operation, self.index == index else { return nil }
            if let data = bytes {
                do {
                    let result = try await decode(data)
                    try await sessions.check(document.scope)
                    guard displayRevision == operation, self.index == index else { return nil }
                    if let imageBlocks {
                        do {
                            let digest = try await imageBlocks.digest(data)
                            let match = try await imageBlocks.match(digest: digest, owner: document.scope.storage.accountID)
                            try await sessions.check(document.scope)
                            guard displayRevision == operation, self.index == index else { return nil }
                            contentDigest = digest
                            blockedImage = match
                        } catch is CancellationError { return nil }
                        catch AppError.cancelled { return nil }
                        catch AppError.staleSession { return nil }
                        catch {
                            self.error = .unsupportedContent; imageFailureCode = "R_IMAGE_RULE_CHECK"
                            return nil
                        }
                    }
                    decodedIndex = index
                    return result
                } catch is CancellationError { return nil }
                catch AppError.cancelled { return nil }
                catch AppError.staleSession { return nil }
                catch {
                    guard !Task.isCancelled, displayRevision == operation, self.index == index else { return nil }
                    bytes = nil
                    let failure = error as? ReaderDecodeFailure ?? .pixels
                    try? await pipeline.discardCached(document: document, index: index)
                    guard !Task.isCancelled, displayRevision == operation else { return nil }
                    if attempt == 1 || failure == .dimensions {
                        self.error = .unsupportedContent; imageFailureCode = failure.rawValue; return nil
                    }
                }
            } else if error != .unsupportedContent { return nil }
            else if attempt == 1 {
                imageFailureCode = "R_RESPONSE_FORMAT_OR_LIMIT"; return nil
            }
            recoveringImage = true; error = nil
            try? await pipeline.discardCached(document: document, index: index)
        }
        return nil
    }
    /// Immutable evidence that this page was displayed, captured before an async task is queued.
    public struct DisplayedProgress: Sendable {
        fileprivate let owner: UUID
        fileprivate let revision: UUID
        fileprivate let value: ReadingProgress
        fileprivate let observedAt: ContinuousClock.Instant
    }
    private let progressOwner = UUID()
    public func captureDisplayedProgress(index: PageIndex, fraction: UnitFraction? = nil) -> DisplayedProgress? {
        guard self.index == index, bytes != nil || decodedIndex == index,
              let fraction = fraction ?? (try? UnitFraction(0)) else { return nil }
        return DisplayedProgress(owner: progressOwner, revision: revision,
            value: ReadingProgress(scope: document.scope.storage, galleryID: document.reference.key.galleryID,
                index: index, fraction: fraction, readingMode: mode, updatedAt: Date()), observedAt: .now)
    }
    /// A captured display intent may finish after the view is stopped. It still
    /// belongs to its original reader/scope; the database rejects older intents.
    public func displayed(_ progress: DisplayedProgress) async {
        guard progress.owner == progressOwner else { return }
        let ticket = progress.revision
        do {
            try await sessions.check(document.scope)
            try Task.checkCancellation()
            try await database.saveAccountProgress(progress.value, observedAt: progress.observedAt)
            if revision == ticket { progressFailed = false }
        } catch is CancellationError { return }
        catch AppError.cancelled { return }
        catch { if !Task.isCancelled, revision == ticket { progressFailed = true } }
    }
    /// Only a successfully decoded/displayed current page creates a new intent.
    public func displayed(index: PageIndex, fraction: UnitFraction? = nil) async {
        guard let progress = captureDisplayedProgress(index: index, fraction: fraction) else { return }
        await displayed(progress)
    }
    public func blockCurrentImage(note: String? = nil, expectedDigest: String? = nil) async throws -> BlockImageEntry {
        try await sessions.check(document.scope)
        guard let imageBlocks, decodedIndex == index, let digest = contentDigest else { throw AppError.invalidInput }
        guard expectedDigest == nil || expectedDigest == digest else { throw AppError.invalidInput }
        let entry = try await imageBlocks.add(digest: digest, owner: document.scope.storage.accountID, note: note)
        try await sessions.check(document.scope)
        return entry
    }
    public func removeCurrentImageBlock() async throws {
        try await sessions.check(document.scope)
        guard let imageBlocks, let entry = blockedImage else { throw AppError.invalidInput }
        try await imageBlocks.remove(entry, owner: document.scope.storage.accountID)
        try await sessions.check(document.scope)
    }
    public func decodeFailed(index: PageIndex) {
        guard self.index == index else { return }
        bytes = nil; error = .unsupportedContent
    }
    public func permitsLocalThumbnail(_ data: Data) async throws -> Bool {
        try await sessions.check(document.scope)
        guard let imageBlocks else { return true }
        let digest = try await imageBlocks.digest(data)
        let match = try await imageBlocks.match(digest: digest, owner: document.scope.storage.accountID)
        try await sessions.check(document.scope)
        return match == nil
    }
    public func releaseCompressedBytes() { bytes = nil }
    public func prefetch(index: PageIndex) async -> Bool {
        await pipeline.prefetch(document: document, index: index)
    }
    public func stop() { revision = UUID(); displayRevision = UUID(); bytes = nil; decodedIndex = nil; loading = false; recoveringImage = false }
}
