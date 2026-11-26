import Foundation

/// Memory-only context, bound to the entire reference and session generation.
public struct ImageResolutionContext: Sendable {
    public let reference: GalleryReference
    public let scope: SessionScope
    public let showKey: SensitiveText?
    public let sourceID: SensitiveText?
    public let sourcePage: ReaderPageKey
    private let image: ResolvedImage
    public init(parsed: ParsedImagePage) {
        image = parsed.image
        reference = parsed.image.page.reference; scope = parsed.image.scope
        showKey = parsed.showKey; sourceID = parsed.sourceID; sourcePage = parsed.image.page.id
    }
    fileprivate init(parsed: ParsedImagePage, retaining key: SensitiveText?) {
        image = parsed.image
        reference = parsed.image.page.reference; scope = parsed.image.scope
        showKey = key; sourceID = parsed.sourceID; sourcePage = parsed.image.page.id
    }

    public func resolvedImage(for request: ImageResolutionRequest) -> ResolvedImage? {
        guard scope == request.scope, reference == request.page.reference, sourcePage == request.page.id,
              image.page.pageURL.path == request.page.pageURL.path else { return nil }
        return image
    }
}

/// Actions contain sensitive request material: never log URLs or bodies.
public enum ImageResolutionAction: Sendable {
    case html(URL)
    case showPage(url: URL, body: Data)
}

/// One value per resolution operation. At most one API attempt plus one HTML fallback.
/// Transport/session checks and binary decoding remain T15/T23 responsibilities.
public struct ImageResolutionPolicy: Sendable {
    public let request: ImageResolutionRequest
    public private(set) var context: ImageResolutionContext?
    public private(set) var attempts = 0
    private let parsing: ParsingPolicy
    private var awaitingAPI = false
    private var pending = false
    private var finished = false
    public init(request: ImageResolutionRequest, context: ImageResolutionContext? = nil, parsing: ParsingPolicy = ParsingPolicy()) throws {
        _ = try ImageParsing.pageKey(request.page, policy: parsing)
        self.request = request; self.parsing = parsing
        self.context = context.flatMap { $0.scope == request.scope && $0.reference == request.page.reference ? $0 : nil }
    }
    public mutating func start() throws -> ImageResolutionAction {
        try Task.checkCancellation()
        guard attempts == 0, !finished else { throw AppError.invalidInput }
        if request.reason == .initial, let key = context?.showKey {
            let body = try JSONSerialization.data(withJSONObject: ["method": "showpage", "gid": request.page.reference.key.galleryID.value,
                "page": request.page.index.displayNumber, "imgkey": ImageParsing.pageKey(request.page, policy: parsing), "showkey": key.value])
            attempts = 1; awaitingAPI = true; pending = true
            return .showPage(url: URL(string: "https://" + parsing.host(for: request.scope.storage.site) + "/api.php")!, body: body)
        }
        return try html()
    }
    private mutating func html() throws -> ImageResolutionAction {
        var parts = URLComponents(url: request.page.pageURL, resolvingAgainstBaseURL: false)!
        // Preserve unrelated parameters but never replay an old source selector.
        var query = parts.queryItems?.filter { $0.name != "nl" } ?? []
        if request.reason == .changeSource || request.reason == .retryDownloadSource {
            if let context, context.resolvedImage(for: request) != nil, let source = context.sourceID {
                query.append(URLQueryItem(name: "nl", value: source.value))
            } else if request.reason == .changeSource {
                finished = true
                throw AppError.invalidInput
            }
        }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw AppError.invalidInput }
        context = nil; awaitingAPI = false; attempts += 1; pending = true
        return .html(url)
    }
    public mutating func accept(_ response: HTTPResponse, resolvedAt: Date, diagnostics: Bool = false) throws -> ParsedImagePage {
        guard pending, !finished else { throw AppError.invalidInput }
        // On a thrown parser error, caller must call recover exactly once or discard this value.
        let result = try awaitingAPI
            ? ShowPageParser(policy: parsing).parse(response, request: request, resolvedAt: resolvedAt)
            : (diagnostics ? ImagePageParser(policy: parsing).parseDetailed(response, request: request, resolvedAt: resolvedAt)
                : ImagePageParser(policy: parsing).parse(response, request: request, resolvedAt: resolvedAt))
        context = awaitingAPI ? ImageResolutionContext(parsed: result, retaining: context?.showKey) : ImageResolutionContext(parsed: result)
        pending = false; finished = true
        return result
    }
    public mutating func recover(from error: AppError) throws -> ImageResolutionAction {
        try Task.checkCancellation()
        guard pending, !finished else { throw AppError.invalidInput }
        pending = false
        if awaitingAPI, attempts == 1, error == .imageExpired || error == .accessDenied || error == .unsupportedContent {
            return try html()
        }
        context = nil; finished = true
        throw error
    }
    /// A downloaded HTML/JSON error body must never reach an image decoder as success.
    /// Full image decoding/signature validation and CDN authorization belong to the image pipeline.
    public static func validateImageResponse(_ response: HTTPResponse, scope: SessionScope) throws {
        try Task.checkCancellation()
        guard response.scope == scope else { throw AppError.staleSession }
        switch response.status {
        case 200: break
        case 403, 404, 410: throw AppError.imageExpired
        case 401: throw AppError.authenticationRequired
        case 429: throw AppError.rateLimited(retryAfter: nil)
        case 509: throw AppError.quotaExceeded
        default: throw AppError.httpStatus(response.status)
        }
        let mime = HTMLParsing.header("content-type", response)?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        guard ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif"].contains(mime), !response.body.isEmpty else { throw AppError.unsupportedContent }
        let prefix = String(decoding: response.body.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.hasPrefix("<"), !prefix.hasPrefix("{"), !prefix.hasPrefix("[") else { throw AppError.unsupportedContent }
    }
}
