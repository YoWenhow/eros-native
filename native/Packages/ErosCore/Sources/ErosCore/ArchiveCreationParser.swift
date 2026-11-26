import Foundation
import SwiftSoup

/// A signed preparation capability extracted from one matched create response.
/// The response, address and token are never encoded into the operation journal.
public struct ArchiveCreationReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: ArchivePreparationAddress
    public var description: String { "<archive creation receipt redacted>" }
    public var debugDescription: String { description }
}

public struct ArchiveCreationParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy=policy }
    public func parse(_ response: HTTPResponse, submission: HTTPRequest, request: GalleryRequest) throws -> ArchiveCreationReceipt {
        guard submission.method == .post, submission.scope == request.scope,
              submission.url.path == "/archiver.php", submission.url.host == policy.host(for:request.scope.storage.site),
              response.requestID == submission.id, response.scope == request.scope,
              response.finalURL == submission.url else { throw AppError.staleSession }
        guard response.status == 200, response.body.count <= 2*1024*1024 else { throw AppError.parseMismatch }
        let doc=try HTMLParsing.document(response,context:RequestContext(scope:request.scope,queryID:submission.id),policy:policy)
        let paragraphs=try doc.select("#db > p").array()
        guard let first=paragraphs.first,
              try first.text() == "Locating archive server and preparing file for download...",
              let continuation=try doc.select("#db p#continue").first() else { throw AppError.parseMismatch }
        let links=try continuation.select("a[href]").array()
        guard links.count==1, let link=links.first,
              try link.text()=="Click here if your browser does not continue automatically" else { throw AppError.parseMismatch }
        let scripts=try doc.select("#db script").array().map { $0.data() }.joined(separator:"\n")
        let regex=try NSRegularExpression(pattern:#"\bdocument\.location\s*=\s*["']([^"'<>]+)["']"#)
        let matches=regex.matches(in:scripts,range:NSRange(scripts.startIndex...,in:scripts))
        guard matches.count==1,let range=Range(matches[0].range(at:1),in:scripts),
              let destination=URL(string:String(scripts[range]),relativeTo:response.finalURL)?.absoluteURL,
              let linked=URL(string:try link.attr("href"),relativeTo:response.finalURL)?.absoluteURL,
              linked==destination else { throw AppError.parseMismatch }
        let address=try ArchivePreparationAddress(url:destination,gallery:request.reference.key.galleryID)
        return ArchiveCreationReceipt(address:address)
    }
}
