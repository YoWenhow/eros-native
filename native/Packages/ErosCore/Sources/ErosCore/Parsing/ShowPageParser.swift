import Foundation
import CoreFoundation
import SwiftSoup

public struct ShowPageParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy = policy }
    public func parse(_ response: HTTPResponse, request: ImageResolutionRequest, resolvedAt: Date) throws -> ParsedImagePage {
        try HTMLParsing.mapped {
            try HTMLParsing.validateResponse(response, context: RequestContext(scope: request.scope, queryID: response.requestID), policy: policy)
            _ = try ImageParsing.pageKey(request.page, policy: policy)
            guard response.finalURL.path == "/api.php" else { throw AppError.parseMismatch }
            let mime = HTMLParsing.header("content-type", response)?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
            guard mime == "application/json" else { throw AppError.unsupportedContent }
            guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw AppError.parseMismatch }
            if let error = object["error"] {
                if error as? String == "Key mismatch" { throw AppError.imageExpired }
                throw AppError.parseMismatch
            }
            func positive(_ key: String) -> Int? {
                guard let raw = object[key], !(raw is NSNull) else { return nil }
                let text = String(describing: raw)
                guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text), n > 0 else { return nil }
                // JSON booleans bridge to NSNumber; reject them explicitly.
                if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
                return n
            }
            guard let width = positive("x"), let height = positive("y"), positive("p") == request.page.index.displayNumber,
                  let i3 = object["i3"] as? String, let i5 = object["i5"] as? String,
                  let i6 = object["i6"] as? String else { throw AppError.parseMismatch }
            let imageDoc = try SwiftSoup.parse(i3), galleryDoc = try SwiftSoup.parse(i5), extra = try SwiftSoup.parse(i6)
            try ImageParsing.gallery(galleryDoc, selector: "a[href]", request: request, base: response.finalURL, policy: policy)
            let url = try ImageParsing.media(imageDoc, selector: "img", base: response.finalURL, policy: policy)
            return try ParsedImagePage(image: ImageParsing.result(request: request, url: url, size: PixelSize(width: width, height: height), at: resolvedAt),
                pageCount: nil, showKey: nil, sourceID: ImageParsing.source(extra),
                originalInfo: OriginalImageInfo.parse(extra, base: response.finalURL, policy: policy, reference: request.page.reference, pageImageURL: url, pageDimensions: PixelSize(width: width, height: height)))
        }
    }
}
