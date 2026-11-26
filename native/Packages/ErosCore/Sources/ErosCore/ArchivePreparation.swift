import Foundation
import SwiftSoup

/// A signed preparation address is a capability, not a diagnostic or a Codable recovery field.
/// The create/readback adapter must bind it to the original operation before constructing a request.
public struct ArchivePreparationAddress: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url:URL
    public let gallery:GalleryID
    public var description:String { "<archive preparation redacted>" }
    public var debugDescription:String { description }
    public init(url:URL,gallery:GalleryID) throws {
        guard url.scheme=="https",url.user==nil,url.password==nil,url.port==nil || url.port==443,
              url.fragment==nil,url.query==nil,let host=url.host,
              host.range(of:#"^[a-z]{20}\.hath\.network$"#,options:.regularExpression) != nil,
              let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),!parts.percentEncodedPath.contains("%") else { throw AppError.accessDenied }
        let segments=url.path.split(separator:"/",omittingEmptySubsequences:false)
        guard segments.count==6,segments[0].isEmpty,segments[1]=="archive",segments[2]==String(gallery.value),
              segments[3].range(of:#"^[a-f0-9]{40}$"#,options:.regularExpression) != nil,
              segments[4].range(of:#"^[A-Za-z0-9]{1,128}$"#,options:.regularExpression) != nil,
              segments[5].range(of:#"^[0-9]{1,10}$"#,options:.regularExpression) != nil else { throw AppError.accessDenied }
        self.url=url;self.gallery=gallery
    }
    public func request(scope:SessionScope) -> HTTPRequest {
        HTTPRequest(id:UUID(),scope:scope,url:url,method:.get,headers:["Accept":"text/html"])
    }
}

public struct PreparedArchive: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address:ArchivePreparationAddress
    public let downloadURL:URL
    public var description:String { "<prepared archive redacted>" }
    public var debugDescription:String { description }
}

/// Parses the actual user-supplied ready-page shape. Does not interpret an unknown page as waiting,
/// execute scripts, append start=1, guess the variant from a path segment, or fetch ZIP bytes.
public struct ArchivePreparationParser: Sendable {
    public init() {}
    public func parse(_ response:HTTPResponse,request:HTTPRequest,address:ArchivePreparationAddress) throws -> PreparedArchive {
        guard request.url==address.url,request.method == .get,request.body==nil,
              response.requestID==request.id,response.scope==request.scope,response.finalURL==address.url else { throw AppError.staleSession }
        guard response.status==200 else { throw AppError.httpStatus(response.status) }
        guard response.body.count<=2*1024*1024 else { throw AppError.unsupportedContent }
        let mime=response.headers.first(where:{$0.key.lowercased()=="content-type"})?.value.lowercased().split(separator:";").first?.trimmingCharacters(in:.whitespaces)
        guard mime=="text/html" || mime=="application/xhtml+xml",let html=String(data:response.body,encoding:.utf8) else { throw AppError.unsupportedContent }
        let doc=try SwiftSoup.parse(html,address.url.absoluteString)
        let paragraphs=try doc.select("#db > p").array()
        let ready=try paragraphs.filter { try $0.text().hasPrefix("The file was successfully prepared, and is ready for download.") }
        guard ready.count==1,let paragraph=ready.first else { throw AppError.parseMismatch }
        let links=try paragraph.select("a[href]").array()
        guard links.count==1,let link=links.first,try link.text()=="Click Here To Start Downloading",
              let target=URL(string:try link.attr("href"),relativeTo:address.url)?.absoluteURL,
              target.scheme==address.url.scheme,target.host==address.url.host,target.port==address.url.port,
              target.user==nil,target.password==nil,target.fragment==nil,
              let actual=URLComponents(url:target,resolvingAgainstBaseURL:false),
              let expected=URLComponents(url:address.url,resolvingAgainstBaseURL:false),
              actual.percentEncodedPath==expected.percentEncodedPath,
              actual.queryItems==[URLQueryItem(name:"start",value:"1")] else { throw AppError.parseMismatch }
        return PreparedArchive(address:address,downloadURL:target)
    }
}
