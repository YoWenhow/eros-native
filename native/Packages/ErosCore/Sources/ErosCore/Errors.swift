import Foundation

public enum ReaderAccessStage: String, Sendable {
    case mediaAddress = "R_MEDIA_ADDRESS"
    case redirectAddress = "R_MEDIA_REDIRECT_ADDRESS"
    case redirectHost = "R_MEDIA_REDIRECT_HOST"
    case redirectLimit = "R_MEDIA_REDIRECT_LIMIT"
    case mediaResponse = "R_MEDIA_DENIED"
    case pageResolution = "R_PAGE_DENIED"
}
public struct ReaderAccessFailure: Error, Equatable, Sendable {
    public let stage: ReaderAccessStage
    public init(_ stage: ReaderAccessStage) { self.stage = stage }
}

/// Associated values are codes/durations, never raw server text, URLs, or credentials.
public enum AppError: Error, Codable, Equatable, Sendable {
    case transport(code: Int)
    case httpStatus(Int)
    case authenticationRequired
    case accessDenied
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case parseMismatch
    case imageExpired
    case storageFull
    case cancelled
    case unsupportedContent
    case invalidInput
    case scopeMismatch
    case staleSession
    case notFound
    case originalUnavailable
    case originalOutcomeUnknown
}
