import Foundation

public enum ArchiveState: String, Codable, Sendable {
    case idle, quoting, quoted, creating, creationUnknown, waiting, ready
    case transferring, verifying, extracting, completed, paused, failed, cancelled
}
public enum ArchiveFailure: String, Codable, Sendable { case denied, quota, unrecognized, network, pollLimit }
public enum ArchiveTransferPhase: String, Codable, Sendable { case preparation, file, importFiles, completion }
public enum ArchiveTransferReason: String, Codable, Sendable {
    case redirect, httpStatus, network, accessDenied, htmlResponse, invalidZip, sizeLimit
    case invalidContent, pageCount, pageOrder, unsupportedFile, noImages, imageDecode
    case storageFull, sessionChanged, interrupted, other
}
/// Only a stage and numeric status/error code are retained. Signed addresses and response text are never persisted.
public struct ArchiveTransferIssue: Codable, Equatable, Sendable {
    public let phase: ArchiveTransferPhase
    public let reason: ArchiveTransferReason
    public let code: Int?
    /// True only when an already downloaded ZIP was kept in the private staging directory.
    public let retainedArchive: Bool?
    public init(phase: ArchiveTransferPhase, reason: ArchiveTransferReason, code: Int? = nil,
                retainedArchive: Bool? = nil) {
        self.phase=phase;self.reason=reason;self.code=code;self.retainedArchive=retainedArchive
    }
}
/// Last local milestone before an uncertain create. No response bytes or server address are persisted.
public enum ArchiveCreationStep: String, Codable, Sendable {
    case attemptRecorded, responseReceived, receiptVerified, addressStored
}
public enum ArchiveContractError: Error, Equatable { case invalidTransition, quoteChanged, unknownPrice, expired, pollNotDue }

/// A price is explicit evidence; missing or unrecognized price is never zero.
public enum ArchivePrice: Equatable, Sendable {
    case unknown
    case free
    case amount(Decimal, currency: String)
    public var isKnown: Bool {
        switch self {
        case .unknown: false
        case .free: true
        case .amount(let value, let currency): value >= 0 && !value.isNaN && !currency.isEmpty
        }
    }
}

/// Ephemeral quote, intentionally not Codable: tokens and signed URLs never enter recovery records.
public struct ArchiveQuote: Equatable, Sendable {
    public let scope: SessionScope
    public let gallery: GalleryID
    public let variant: DownloadVariant
    public let price: ArchivePrice
    public let sizeLabel: String
    public let serverBinding: SensitiveText
    public let acquiredAt: Date
    public let expiresAt: Date
    public init(scope: SessionScope, gallery: GalleryID, variant: DownloadVariant,
                price: ArchivePrice, sizeLabel: String, serverBinding: SensitiveText,
                acquiredAt: Date, expiresAt: Date) throws {
        guard acquiredAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > acquiredAt else { throw AppError.invalidInput }
        self.scope=scope; self.gallery=gallery; self.variant=variant; self.price=price
        self.sizeLabel=sizeLabel; self.serverBinding=serverBinding
        self.acquiredAt=acquiredAt; self.expiresAt=expiresAt
    }
}

/// Owner-bound recovery metadata only. Never contains form fields, prices with server text, or URLs.
/// Persist creating BEFORE the POST. Cold recovery cannot grant permission to POST again.
public struct ArchiveOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let owner: AccountID
    public let gallery: GalleryID
    public let variant: DownloadVariant
    public let addedAt: Date
    public private(set) var state: ArchiveState = .idle
    public private(set) var failure: ArchiveFailure?
    public private(set) var transferIssue: ArchiveTransferIssue?
    public private(set) var lastConfirmedCreationStep: ArchiveCreationStep?
    public private(set) var purchaseAttempted = false
    public private(set) var pollCount = 0
    public private(set) var nextPollAt: Date?
    public private(set) var downloadJobID: UUID?
    /// Rounded site quote, used only when the file response has no exact byte length.
    public private(set) var estimatedSizeBytes: Int64?
    public var contentKey: DownloadContentKey {
        DownloadContentKey(account:owner,gallery:gallery,sourceKind:.archive,variant:variant)
    }
    public init(id: UUID = UUID(), owner: AccountID, gallery: GalleryID, variant: DownloadVariant, addedAt: Date) throws {
        guard addedAt.timeIntervalSince1970.isFinite else { throw AppError.invalidInput }
        self.id=id; self.owner=owner; self.gallery=gallery; self.variant=variant; self.addedAt=addedAt
    }
    public mutating func beginQuote(scope: SessionScope) throws {
        try check(scope)
        guard !purchaseAttempted, [.idle,.quoted,.failed,.paused].contains(state) else { throw ArchiveContractError.invalidTransition }
        state = .quoting; failure=nil
    }
    public mutating func receiveQuote(_ quote: ArchiveQuote, scope: SessionScope) throws {
        try check(quote, scope:scope)
        guard state == .quoting else { throw ArchiveContractError.invalidTransition }
        state = .quoted
    }
    /// Fresh quote must equal the evidence shown to the user, including price, type, size and server token.
    /// Callers must still persist this transition before sending the actual request.
    public mutating func authorizeCreation(confirmed: ArchiveQuote, fresh: ArchiveQuote, scope: SessionScope, now: Date) throws {
        try check(fresh,scope:scope)
        guard state == .quoted, !purchaseAttempted else { throw ArchiveContractError.invalidTransition }
        guard confirmed.scope == scope, confirmed.gallery == fresh.gallery, confirmed.variant == fresh.variant,
              confirmed.price == fresh.price, confirmed.sizeLabel == fresh.sizeLabel,
              confirmed.serverBinding == fresh.serverBinding else { throw ArchiveContractError.quoteChanged }
        guard fresh.price.isKnown else { throw ArchiveContractError.unknownPrice }
        guard now >= fresh.acquiredAt, now < fresh.expiresAt, now < confirmed.expiresAt else { throw ArchiveContractError.expired }
        estimatedSizeBytes=ArchiveSizeEstimate.bytes(from:fresh.sizeLabel)
        purchaseAttempted=true; state = .creating
    }
    public mutating func creationUncertain(scope: SessionScope, lastConfirmed: ArchiveCreationStep) throws {
        try check(scope)
        guard state == .creating else { throw ArchiveContractError.invalidTransition }
        state = .creationUnknown; lastConfirmedCreationStep = lastConfirmed
    }
    /// Only verified read-back of the SAME server operation can resolve an ambiguous create.
    public mutating func receiveStatus(ready: Bool, scope: SessionScope, now: Date, retryAfter: TimeInterval?) throws {
        try check(scope)
        guard [.creating,.creationUnknown,.waiting,.paused].contains(state), purchaseAttempted else { throw ArchiveContractError.invalidTransition }
        guard now.timeIntervalSince1970.isFinite else { throw AppError.invalidInput }
        if let retryAfter { guard retryAfter.isFinite, retryAfter >= 0 else { throw AppError.invalidInput } }
        state = ready ? .ready : .waiting; failure=nil; lastConfirmedCreationStep=nil
        nextPollAt = ready ? nil : now.addingTimeInterval(max(5,retryAfter ?? 5))
    }
    /// Bounded foreground polling. Retry-After is a minimum and is never clamped down.
    public mutating func beginPoll(scope: SessionScope, now: Date, limit: Int = 60) throws {
        try check(scope)
        guard [.waiting,.creationUnknown].contains(state), limit > 0 else { throw ArchiveContractError.invalidTransition }
        guard nextPollAt.map({now >= $0}) ?? true else { throw ArchiveContractError.pollNotDue }
        guard pollCount < limit else { state = .paused; failure = .pollLimit; throw ArchiveContractError.invalidTransition }
        pollCount += 1; nextPollAt=now.addingTimeInterval(5)
    }
    public mutating func reject(_ reason: ArchiveFailure, scope: SessionScope) throws {
        try check(scope)
        guard [.quoting,.creating,.waiting,.creationUnknown].contains(state) else { throw ArchiveContractError.invalidTransition }
        failure=reason; state = purchaseAttempted && reason == .network ? .creationUnknown : .failed
    }
    public mutating func pause(scope: SessionScope) throws {
        try check(scope)
        guard ![.completed,.cancelled,.failed].contains(state) else { throw ArchiveContractError.invalidTransition }
        state = state == .creating ? .creationUnknown : .paused
    }
    public mutating func cancel(scope: SessionScope) throws {
        try check(scope)
        guard state != .completed else { throw ArchiveContractError.invalidTransition }
        // Cancellation stops local work; purchaseAttempted remains evidence of possible server cost.
        state = .cancelled; nextPollAt=nil
    }
    public mutating func recover(scope: SessionScope) throws {
        try check(scope)
        if state == .creating { state = .creationUnknown; lastConfirmedCreationStep = .attemptRecorded }
        if [.quoting,.quoted,.waiting,.ready,.transferring,.verifying,.extracting].contains(state) { state = .paused }
    }
    /// F21 must attach the same permanent job ID and identity before transfer; never publish completed here.
    public mutating func attachDownload(jobID: UUID, key: DownloadContentKey, scope: SessionScope) throws {
        try check(scope)
        guard key == contentKey, state == .ready, downloadJobID == nil || downloadJobID == jobID else { throw ArchiveContractError.invalidTransition }
        downloadJobID=jobID
    }
    /// Reuses the same job and server operation after an interrupted local
    /// transfer. A completed local copy can be fetched again after deletion;
    /// callers must first prove that its database row is gone.
    public mutating func beginTransfer(jobID: UUID, scope: SessionScope) throws {
        try check(scope)
        guard purchaseAttempted, downloadJobID == jobID,
              [.ready,.paused,.completed].contains(state) else { throw ArchiveContractError.invalidTransition }
        state = .transferring; failure=nil; transferIssue=nil
    }
    public mutating func advanceTransfer(to next: ArchiveState, scope: SessionScope) throws {
        try check(scope)
        guard downloadJobID != nil,
              (state == .transferring && next == .verifying ||
               state == .verifying && next == .extracting) else { throw ArchiveContractError.invalidTransition }
        state = next
    }
    public mutating func interruptTransfer(scope: SessionScope, issue: ArchiveTransferIssue? = nil) throws {
        try check(scope)
        guard downloadJobID != nil, [.transferring,.verifying,.extracting].contains(state) else {
            throw ArchiveContractError.invalidTransition
        }
        state = .paused; transferIssue=issue
    }
    /// Called only after a completed archive job and every published file have
    /// been checked. The two databases cannot commit atomically.
    public mutating func completeTransfer(jobID: UUID, scope: SessionScope) throws {
        try check(scope)
        guard downloadJobID == jobID,
              [.ready,.paused,.transferring,.verifying,.extracting].contains(state) else {
            throw ArchiveContractError.invalidTransition
        }
        state = .completed; failure=nil; transferIssue=nil
    }
    private func check(_ scope: SessionScope) throws {
        guard scope.storage.accountID == owner else { throw AppError.scopeMismatch }
    }
    private func check(_ quote: ArchiveQuote, scope: SessionScope) throws {
        try check(scope)
        guard quote.scope == scope, quote.gallery == gallery, quote.variant == variant else { throw AppError.scopeMismatch }
    }
}
