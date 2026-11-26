import Foundation
import SwiftSoup

public enum MPVCapability: Sendable, Equatable { case unknown, directoryAvailable }

/// Ephemeral, deliberately not Codable. Never use keys as persistent page identity.
public struct MPVPageLocator: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reference: GalleryReference
    public let scope: SessionScope
    public let index: PageIndex
    public let imageKey: SensitiveText
    public let mpvKey: SensitiveText
    public let endpoint: URL
    public var wirePage: Int { index.displayNumber }
    public var description: String { "<MPVPageLocator redacted>" }
    public var debugDescription: String { description }
}
public struct MPVDirectory: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reference: GalleryReference
    public let scope: SessionScope
    public let endpoint: URL
    private let key: SensitiveText
    private let keys: [SensitiveText]
    public var count: Int { keys.count }
    public var capability: MPVCapability { .directoryAvailable }
    public var description: String { "<MPVDirectory redacted>" }
    public var debugDescription: String { description }
    init(reference: GalleryReference, scope: SessionScope, endpoint: URL, key: SensitiveText, keys: [SensitiveText]) {
        self.reference = reference; self.scope = scope; self.endpoint = endpoint; self.key = key; self.keys = keys
    }
    public func page(at index: PageIndex, scope: SessionScope) throws -> MPVPageLocator {
        guard scope == self.scope else { throw AppError.invalidInput }
        _ = try index.checked(pageCount: count)
        return MPVPageLocator(reference: reference, scope: scope, index: index, imageKey: keys[index.value], mpvKey: key, endpoint: endpoint)
    }
}

/// Parses only observed bootstrap declarations; never executes JavaScript or guesses an entry URL.
public struct MPVDirectoryParser: Sendable {
    public enum Use: Sendable {
        case imageDispatch
        case singlePageLinks
    }

    public let policy: ParsingPolicy
    public let ehAPIHost: String
    public let exAPIHost: String
    public init(policy: ParsingPolicy = ParsingPolicy(), ehAPIHost: String = "api.e-hentai.org", exAPIHost: String = "s.exhentai.org") {
        self.policy = policy; self.ehAPIHost = ehAPIHost; self.exAPIHost = exAPIHost
    }
    public func parse(_ response: HTTPResponse, reference: GalleryReference, context: RequestContext,
                      expectedCount: Int, use: Use = .imageDispatch,
                      onMismatch: ((ReaderParseIssue) -> Void)? = nil) throws -> MPVDirectory {
        func mismatch(_ check: StaticString, expected: Int? = nil, observed: Int? = nil) -> AppError {
            onMismatch?(ReaderParseIssue(check, expected: expected, observed: observed))
            return .parseMismatch
        }
        try Task.checkCancellation()
        guard expectedCount > 0, expectedCount <= 100_000, response.body.count <= 8 * 1024 * 1024 else { throw AppError.invalidInput }
        try reference.validate(scope: context.scope)
        let doc = try HTMLParsing.document(response, context: context, policy: policy)
        let url = try policy.siteURL(response.finalURL.absoluteString, base: response.finalURL, site: reference.key.site)
        guard url.path.split(separator: "/").map(String.init) == ["mpv", String(reference.key.galleryID.value), reference.token.value], url.query == nil else { throw mismatch("directoryURLIdentity") }
        let scripts = try doc.select("script:not([src])").array().map { try $0.html() }.joined(separator: "\n")
        func unique(_ pattern: String, _ check: StaticString) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let matches = regex.matches(in: scripts, range: NSRange(scripts.startIndex..., in: scripts))
            guard matches.count == 1, let match = matches.first, let range = Range(match.range(at: 1), in: scripts) else {
                throw mismatch(check, expected: 1, observed: matches.count)
            }
            return String(scripts[range])
        }
        let gid = try unique(#"\bvar\s+gid\s*=\s*(\d+)\s*;"#, "directoryGIDDeclaration")
        guard Int64(gid) == reference.key.galleryID.value else { throw mismatch("directoryGalleryIdentity") }
        let key = try unique(#"\bvar\s+mpvkey\s*=\s*"([A-Za-z0-9]+)"\s*;"#, "directoryKeyDeclaration")
        let list = try unique(#"\bvar\s+imagelist\s*=\s*(\[.*?\])\s*;"#, "directoryListDeclaration")
        struct Item: Decodable { let n: String; let k: String; let t: String }
        let items: [Item]
        do { items = try JSONDecoder().decode([Item].self, from: Data(list.utf8)) }
        catch {
            let field: String?
            switch error {
            case DecodingError.keyNotFound(let key, _): field = key.stringValue
            case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
                field = context.codingPath.last?.stringValue
            default: field = nil
            }
            let check: StaticString = switch field {
            case "n": "directoryItemName"
            case "k": "directoryItemKey"
            case "t": "directoryItemThumbnail"
            default: "directoryListJSON"
            }
            throw mismatch(check)
        }
        guard items.count == expectedCount else {
            throw mismatch("directoryItemCount", expected: expectedCount, observed: items.count)
        }
        // A single-page URL pairs the image key with the gallery and page number.
        // Repeated images can share a key while remaining distinct page occurrences.
        if case .imageDispatch = use {
            let uniqueKeys = Set(items.map(\.k)).count
            guard uniqueKeys == items.count else {
                throw mismatch("directoryDuplicateKeys", expected: items.count, observed: uniqueKeys)
            }
        }
        guard items.allSatisfy({ !$0.k.isEmpty && $0.k.count <= 256 && $0.k.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { throw mismatch("directoryImageKeyFormat") }
        guard key.count <= 256 else { throw mismatch("directoryKeyLength", observed: key.count) }
        let api = try unique(#"\bvar\s+api_url\s*=\s*"([^"\s]+)"\s*;"#, "directoryAPIDeclaration")
        guard let endpoint = URL(string: api), endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil,
              endpoint.port == nil, endpoint.query == nil, endpoint.fragment == nil, endpoint.path == "/api.php",
              endpoint.host == (reference.key.site == .eh ? ehAPIHost : exAPIHost) else { throw AppError.accessDenied }
        try Task.checkCancellation()
        return try MPVDirectory(reference: reference, scope: context.scope, endpoint: endpoint, key: SensitiveText(key), keys: items.map { try SensitiveText($0.k) })
    }
}
