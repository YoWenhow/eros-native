
import Foundation
import ErosCore

/// Adapts reader and download diagnostics to the shared application log.
public enum ReaderLog {
    public static func record(
        _ event: AppLogEvent,
        request: UUID,
        url: URL? = nil,
        attempt: Int? = nil,
        status: Int? = nil,
        milliseconds: Int? = nil,
        transportCode: Int? = nil,
        pageIndex: Int? = nil,
        phase: StaticString? = nil,
        failureKind: StaticString? = nil
    ) async {
        var fields: [AppLogField: AppLogValue] = [:]
        fields[.address] = url.map { .address(ReaderAddressFacts($0)) }
        fields[.attempt] = attempt.map(AppLogValue.integer)
        fields[.status] = status.map(AppLogValue.integer)
        fields[.milliseconds] = milliseconds.map(AppLogValue.integer)
        fields[.transportCode] = transportCode.map(AppLogValue.integer)
        fields[.pageIndex] = pageIndex.map(AppLogValue.integer)
        fields[.phase] = phase.map(AppLogValue.label)
        fields[.failureKind] = failureKind.map(AppLogValue.label)
        await AppLog.shared.record(event, request: request, fields: fields)
    }

    public static func failureCode(_ error: any Error) -> Int {
        switch error {
        case AppError.transport(let code), AppError.httpStatus(let code): code
        default: (error as NSError).code
        }
    }

    /// Only fixed categories are written to the shared log.
    public static func failureKind(_ error: any Error) -> StaticString {
        if error is CancellationError { return "cancelled" }
        if let error = error as? ReaderAccessFailure {
            return switch error.stage {
            case .mediaAddress: "R_MEDIA_ADDRESS"
            case .redirectAddress: "R_MEDIA_REDIRECT_ADDRESS"
            case .redirectHost: "R_MEDIA_REDIRECT_HOST"
            case .redirectLimit: "R_MEDIA_REDIRECT_LIMIT"
            case .mediaResponse: "R_MEDIA_DENIED"
            case .pageResolution: "R_PAGE_DENIED"
            }
        }
        if error is ImagePageFailure { return "imagePageParse" }
        if let error = error as? AppError {
            return switch error {
            case .transport: "transport"
            case .httpStatus: "httpStatus"
            case .authenticationRequired: "authenticationRequired"
            case .accessDenied: "accessDenied"
            case .rateLimited: "rateLimited"
            case .quotaExceeded: "quotaExceeded"
            case .parseMismatch: "parseMismatch"
            case .imageExpired: "imageExpired"
            case .storageFull: "storageFull"
            case .cancelled: "cancelled"
            case .unsupportedContent: "unsupportedContent"
            case .invalidInput: "invalidInput"
            case .scopeMismatch: "scopeMismatch"
            case .staleSession: "staleSession"
            case .notFound: "notFound"
            case .originalUnavailable: "originalUnavailable"
            case .originalOutcomeUnknown: "originalOutcomeUnknown"
            }
        }
        return switch (error as NSError).domain {
        case "ErosDownloadImageValidation": "imageValidation"
        case NSURLErrorDomain: "urlLoading"
        case NSCocoaErrorDomain: "cocoa"
        case NSPOSIXErrorDomain: "posix"
        default: "other"
        }
    }
}
