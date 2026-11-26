import Foundation
import ErosCore

/// The media delegate reports whether this transfer received bytes. The
/// address and any reload key stay in the in-memory image resolver.
public struct PageDownloadTransferFailure: Error, Sendable {
    public let cause: AppError
    public let receivedBytes: Bool

    public init(_ cause: AppError, receivedBytes: Bool = false) {
        self.cause = cause
        self.receivedBytes = receivedBytes
    }
}

enum PageDownloadRetry {
    static let backoff: [TimeInterval] = [1, 2, 4, 8]
    static let startWindow: Duration = .seconds(180)

    static func isTransient(_ error: any Error) -> Bool {
        switch error as? AppError {
        case .transport(let value):
            let transient: [URLError.Code] = [.timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .resourceUnavailable, .zeroByteResource]
            return transient.contains { $0.rawValue == value }
        case .httpStatus(let status):
            return status == 408 || [500, 502, 503, 504].contains(status)
        default:
            return false
        }
    }

    static func resolution(after error: any Error, previous: ImageResolutionReason?) -> ImageResolutionReason? {
        guard let transfer = error as? PageDownloadTransferFailure else {
            if (error as NSError).domain == "ErosDownloadImageValidation" { return .retryDownloadSource }
            guard isTransient(error) else { return nil }
            return previous == .retryDownloadSource ? .retryDownloadSource : .expiredURL
        }
        switch transfer.cause {
        case .imageExpired, .unsupportedContent:
            return .retryDownloadSource
        case .transport(let code) where code == URLError.secureConnectionFailed.rawValue:
            // The failure belongs to an image address, so ask the site for a new candidate.
            return .retryDownloadSource
        case .transport where isTransient(transfer.cause):
            // Give the current node a chance after a partial transfer. A second
            // interruption on that address warrants asking the site for another node.
            if transfer.receivedBytes, previous != .retryDownloadAddress { return .retryDownloadAddress }
            return .retryDownloadSource
        default:
            return isTransient(transfer.cause) ? .retryDownloadSource : nil
        }
    }
}
