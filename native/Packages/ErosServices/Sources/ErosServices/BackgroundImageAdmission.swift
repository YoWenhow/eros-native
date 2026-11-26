import Foundation
import ErosCore
import ErosNetworking

/// Kept in memory after a same-page response has passed the image-page parser.
public struct BackgroundImageResolution: Sendable {
    public let image: ResolvedImage
    let receivedFromReloadPage: Bool
}

/// Adds one authorized origin-image address to an individual background transfer.
public struct BackgroundImageAdmission: Sendable {
    public let ticket: BackgroundTransferTicket
    public let url: URL
    public let reloadImageSHA256: String?

    public init(resolution: BackgroundImageResolution, ticket: BackgroundTransferTicket, policy: NetworkPolicy) throws {
        let image = resolution.image
        guard image.scope.storage == ticket.storage, image.page.index == ticket.index else { throw AppError.scopeMismatch }
        self.ticket = ticket
        url = image.url
        if resolution.receivedFromReloadPage, HathReaderURL.allowsOriginImage(image.url) {
            reloadImageSHA256 = Self.fingerprint(url: image.url, ticket: ticket)
        } else {
            try policy.validate(image.url, scope: image.scope, allowMedia: true)
            reloadImageSHA256 = nil
        }
    }

    /// The stored fingerprint is scoped to the ticket and never contains a raw address.
    public static func validateResponse(_ url: URL, record: BackgroundDownloadInbox.Record, policy: NetworkPolicy) throws {
        if let fingerprint = record.reloadImageSHA256, HathReaderURL.allowsOriginImage(url),
           fingerprint == Self.fingerprint(url: url, ticket: record.ticket) {
            return
        }
        let scope = SessionScope(storage: StorageScope(accountID: record.ticket.storage.accountID, site: record.site), generation: 0)
        try policy.validate(url, scope: scope, allowMedia: true)
    }

    private static func fingerprint(url: URL, ticket: BackgroundTransferTicket) -> String {
        let material = [ticket.key, ticket.storage.accountID.value.uuidString, ticket.storage.site.rawValue, url.absoluteString]
        return TranslationDigest.sha256(Data(material.joined(separator: "\n").utf8))
    }
}
