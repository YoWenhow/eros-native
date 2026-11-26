
import Foundation

public enum AppLogLevel: String, CaseIterable, Encodable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    var priority: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }
}

public enum AppLogEvent: String, Sendable {
    case applicationLaunched, applicationForeground, applicationBackground
    case httpResponse, httpFailure
    case libraryOpened, libraryOpenFailed, preferencesApplyFailed, imageCacheCleared, imageCacheClearFailed
    case libraryRefreshControlRetired, libraryRefreshRowShift
    case resolved, addressDenied, response, redirect, transportFailure, mediaRetry, mediaSuccess, imageAPIFallback, readerParseFailure
    case downloadResolve, downloadTransfer, downloadValidate, downloadWrite, downloadCommit, downloadRetry
    case downloadPageCommitted, downloadActivity
    case backgroundSessionConnected, backgroundSessionDeferred, backgroundSessionFailed
    case backgroundSubmitted, backgroundReceived, backgroundFinishedEvents, backgroundTransferFailed
    case backgroundProbeHeld, backgroundProbeResumed, backgroundProbeResult
    case backgroundResolving, backgroundResolved, backgroundInboxHit, backgroundPhaseFailed, backgroundWakeup, backgroundLifecycle

    var category: String {
        switch self {
        case .applicationLaunched, .applicationForeground, .applicationBackground:
            "app"
        case .httpResponse, .httpFailure:
            "network"
        case .libraryOpened, .libraryOpenFailed, .preferencesApplyFailed, .imageCacheCleared, .imageCacheClearFailed:
            "storage"
        case .libraryRefreshControlRetired, .libraryRefreshRowShift:
            "library"
        case .resolved, .addressDenied, .response, .redirect, .transportFailure, .mediaRetry, .mediaSuccess, .imageAPIFallback, .readerParseFailure:
            "reader"
        default:
            "download"
        }
    }

    func level(for status: Int?) -> AppLogLevel {
        switch self {
        case .response, .httpResponse:
            switch status ?? 0 {
            case 500...: .error
            case 400...: .warn
            default: self == .httpResponse ? .info : .debug
            }
        case .resolved, .redirect, .mediaSuccess, .libraryRefreshControlRetired, .libraryRefreshRowShift,
             .backgroundResolving, .backgroundResolved, .backgroundInboxHit, .backgroundLifecycle:
            .debug
        case .addressDenied, .transportFailure, .httpFailure, .mediaRetry, .imageAPIFallback, .downloadRetry,
             .backgroundSessionDeferred, .backgroundTransferFailed:
            .warn
        case .readerParseFailure, .libraryOpenFailed, .preferencesApplyFailed, .imageCacheClearFailed, .downloadResolve,
             .downloadTransfer, .downloadValidate, .downloadWrite, .downloadCommit, .backgroundPhaseFailed,
             .backgroundSessionFailed:
            .error
        default:
            .info
        }
    }
}

public enum AppLogField: String, Sendable {
    case address, attempt, status, milliseconds, transportCode, pageIndex, phase, failureKind, method
    case fromPull, stoppedShort, offset, exposed
    case expectedCount, observedCount
}

/// Shape information safe for the reader log. It carries no site content or identifiers.
public struct ReaderParseIssue: Sendable {
    public let check: StaticString
    public let expected: Int?
    public let observed: Int?

    public init(_ check: StaticString, expected: Int? = nil, observed: Int? = nil) {
        self.check = check
        self.expected = expected
        self.observed = observed
    }
}

/// Shared files accept fixed labels and structured facts. Callers cannot supply arbitrary strings.
public enum AppLogValue: Encodable, Sendable {
    case integer(Int)
    case number(Double)
    case flag(Bool)
    case label(StaticString)
    case address(ReaderAddressFacts)

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .integer(let number): try value.encode(number)
        case .number(let number): try value.encode(number.isFinite ? number : 0)
        case .flag(let flag): try value.encode(flag)
        case .label(let label): try value.encode(String(describing: label))
        case .address(let address): try value.encode(address)
        }
    }
}

/// URL structure only. The complete address, unrecognized host names, paths and values are omitted.
public struct ReaderAddressFacts: Encodable, Sendable {
    public let scheme: String
    public let hostFamily: String
    public let hostLabelLengths: [Int]
    public let port: Int?
    public let pathFamily: String
    public let pathSegments: Int
    public let hasQuery: Bool
    public let hasFragment: Bool
    public let hasUserInfo: Bool
    public let hasControlCharacters: Bool
    public let acceptedHathReader: Bool

    public init(_ url: URL) {
        let rawScheme = url.scheme?.lowercased() ?? ""
        scheme = ["https", "http"].contains(rawScheme) ? rawScheme : "other"
        let host = url.host?.lowercased() ?? ""
        if ["ehgt.org", "s.exhentai.org", "e-hentai.org", "exhentai.org"].contains(host) {
            hostFamily = host
        } else {
            hostFamily = host.hasSuffix(".hath.network") ? "hath.network" : "other"
        }
        hostLabelLengths = host.components(separatedBy: ".").map(\.count)
        port = url.port
        if url.path.hasPrefix("/h/") {
            pathFamily = "h"
        } else if url.path.hasPrefix("/c2/") {
            pathFamily = "c2"
        } else if url.path.hasPrefix("/om/") {
            pathFamily = "om"
        } else {
            pathFamily = "other"
        }
        pathSegments = url.path.split(separator: "/").count
        hasQuery = url.query != nil
        hasFragment = url.fragment != nil
        hasUserInfo = url.user != nil || url.password != nil
        hasControlCharacters = url.path.rangeOfCharacter(from: .controlCharacters) != nil
        acceptedHathReader = HathReaderURL.allows(url)
    }
}
