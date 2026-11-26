import Foundation
import ErosCore

public enum BackgroundImageResponse {
    public static let textPrefixLimit = 4096

    public static func error(forStatus status: Int) -> AppError? {
        switch status {
        case 200, 206: nil
        case 401: .authenticationRequired
        case 403, 404, 410: .imageExpired
        case 429: .rateLimited(retryAfter: nil)
        case 509: .quotaExceeded
        default: .httpStatus(status)
        }
    }

    public static func error(inTextPrefix data: Data) -> AppError? {
        let text = String(decoding: data.prefix(textPrefixLimit), as: UTF8.self).lowercased()
        if text.contains("you have exceeded your image") || text.contains("you have reached the image limit")
            || (text.contains("requires gp") && text.contains("you do not have enough")) {
            return .quotaExceeded
        }
        if text.contains("your ip address has been banned") || text.contains("this ip address has been banned") {
            return .accessDenied
        }
        return nil
    }

    /// URLSession can report the final range response while handing the delegate an assembled file.
    public static func containsCompleteFile(status: Int, contentRange: String?, fileBytes: Int) -> Bool {
        guard fileBytes > 0 else { return false }
        if status == 200 { return true }
        guard status == 206, let contentRange,
              let range = contentRange.trimmingCharacters(in: .whitespaces).lowercased()
                .wholeMatch(of: #/bytes ([0-9]+)-([0-9]+)/([0-9]+)/#),
              let first = Int(range.1), let last = Int(range.2), let total = Int(range.3),
              total == fileBytes else { return false }
        return first <= last && last == total - 1
    }
}
