import Foundation
import ErosCore

/// Used only by F19 explicit original downloads; display transports keep fullimg disabled.
public struct OriginalImageTransferPolicy: Sendable {
    public static let maximumBytes = 24 * 1024 * 1024
    public static let maximumRedirects = 3
    public static let automaticChargedRetries = 0
    public static let acceptedTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heic"]
    public let network: NetworkPolicy
    public init(network: NetworkPolicy = NetworkPolicy()) { self.network = network }
    /// Once a chain leaves the account site it may never re-enter with credentials.
    public func allowsCredentials(at url: URL, scope: SessionScope, previous: URL?, hop: Int) throws -> Bool {
        guard (0...Self.maximumRedirects).contains(hop), (hop == 0) == (previous == nil) else { throw AppError.accessDenied }
        try network.validate(url, scope: scope, allowMedia: true)
        if let previous, previous.host != network.parsing.host(for: scope.storage.site) {
            guard network.allowsMediaRedirect(to: url, scope: scope) else { throw AppError.accessDenied }
            return false
        }
        if url.host == network.parsing.host(for: scope.storage.site) {
            guard OriginalImageEndpoint.matchesPath(url) else { throw AppError.accessDenied }
            return true
        }
        guard network.allowsMediaRedirect(to: url, scope: scope) else { throw AppError.accessDenied }
        return false
    }
    /// Byte decoding, dimensions and actual received-byte cap remain mandatory in the F19 sink.
    public func validateResponse(_ response: HTTPResponse) throws {
        if response.status == 509 { throw AppError.quotaExceeded }
        guard (200...299).contains(response.status) else { throw AppError.unsupportedContent }
        let type = ResponseClassifier.header("Content-Type", in: response)?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard Self.acceptedTypes.contains(type), !response.body.isEmpty, response.body.count <= Self.maximumBytes else { throw AppError.unsupportedContent }
        if let raw = ResponseClassifier.header("Content-Length", in: response) {
            guard let count = Int(raw), count > 0, count <= Self.maximumBytes else { throw AppError.unsupportedContent }
        }
        // A MIME header alone must never turn HTML quota/login/error content into a file.
        let prefix = String(decoding: response.body.prefix(1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.hasPrefix("<!doctype"), !prefix.hasPrefix("<html"), !prefix.hasPrefix("<body"), !prefix.hasPrefix("<p>") else { throw AppError.unsupportedContent }
    }
}
