import Foundation
import SwiftSoup

public enum CommentMutationState: String, Codable, Sendable { case draft, submitting, confirmed, rejected, unknown }
public enum CommentVoteDirection: Int, Codable, Sendable { case down = -1, up = 1 }
public enum CommentAction: Codable, Equatable, Sendable { case post; case vote(id: String, direction: CommentVoteDirection) }
public enum CommentMutationReason: String, Codable, Sendable { case permission, unavailable, rejected, unconfirmed, cancelled }
public enum CommentMutationError: Error, Equatable { case pending, unavailable }
public struct CommentMutation: Sendable {
    public let id: UUID
    public let request: GalleryRequest
    public let action: CommentAction
    public let text: String
    public init(id: UUID = UUID(), request: GalleryRequest, action: CommentAction, text: String) throws {
        try request.reference.validate(scope: request.scope)
        guard text.utf8.count <= 65536 else { throw AppError.invalidInput }
        if case .post = action { guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AppError.invalidInput } }
        if case .vote(let id,_) = action { guard let number = Int64(id), number > 0, String(number) == id else { throw AppError.invalidInput } }
        self.id=id; self.request=request; self.action=action; self.text=text
    }
}
public struct CommentDraft: Codable, Equatable, Sendable {
    public var body: String
    public var state: CommentMutationState
    public var operationID: UUID?
    public var action: CommentAction
    public var generation: UInt64
    public var reason: CommentMutationReason?
    public var confirmedByUser: Bool
    public init(body: String = "", generation: UInt64) {
        self.body=body; self.generation=generation; state = .draft; operationID=nil; action = .post; reason=nil; confirmedByUser=false
    }
}
public struct CommentVoteReceipt: Sendable, Equatable {
    public let id: String
    public let score: Int
    public let vote: Int
    public static func parse(_ body: Data, expected: String) throws -> Self {
        struct Wire: Decodable {
            let comment_id: Int64; let comment_score: Int; let comment_vote: Int
            enum CodingKeys: String,CodingKey { case comment_id,comment_score,comment_vote }
            init(from decoder: any Decoder) throws {
                let c=try decoder.container(keyedBy:CodingKeys.self)
                func integer(_ key: CodingKeys) throws -> Int64 {
                    if (try? c.decode(Bool.self,forKey:key)) != nil { throw AppError.parseMismatch }
                    if let value=try? c.decode(Int64.self,forKey:key) { return value }
                    guard let text=try? c.decode(String.self,forKey:key),text.count<=21,
                          text.range(of:#"^-?[0-9]+$"#,options:.regularExpression) != nil,let value=Int64(text) else { throw AppError.parseMismatch }
                    return value
                }
                comment_id=try integer(.comment_id)
                guard let score=Int(exactly:try integer(.comment_score)),let vote=Int(exactly:try integer(.comment_vote)) else { throw AppError.parseMismatch }
                comment_score=score;comment_vote=vote
            }
        }
        guard let object = try JSONSerialization.jsonObject(with:body) as? [String:Any] else { throw AppError.parseMismatch }
        if object["error"] != nil || object["login"] != nil { throw AppError.accessDenied }
        let wire = try JSONDecoder().decode(Wire.self,from:body)
        guard String(wire.comment_id)==expected else { throw AppError.parseMismatch }
        return Self(id:expected,score:wire.comment_score,vote:wire.comment_vote)
    }
}
public struct CommentMutationResult: Sendable {
    public let draft: CommentDraft
    public let page: CommentPage?
    public let vote: CommentVoteReceipt?
    public init(draft: CommentDraft, page: CommentPage?, vote: CommentVoteReceipt? = nil) { self.draft=draft; self.page=page; self.vote=vote }
}
public struct CommentPostForm: Sendable {
    public let action: URL
    public let fields: [String:SensitiveText]
    public let maximumLength: Int?
}
public struct CommentAPI: Sendable {
    public let scope: SessionScope
    public let endpoint: URL
    public let userID: Int64
    public let key: SensitiveText
    public init(scope:SessionScope,endpoint:URL,userID:Int64,key:SensitiveText) { self.scope=scope;self.endpoint=endpoint;self.userID=userID;self.key=key }
}
public struct CommentWriteParser: Sendable {
    public init() {}
    public func form(_ response: HTTPResponse, request: GalleryRequest) throws -> CommentPostForm {
        let policy = ParsingPolicy(), context = RequestContext(scope:request.scope,queryID:response.requestID)
        let doc = try HTMLParsing.document(response,context:context,policy:policy)
        try HTMLParsing.checkReference(request.reference,response:response)
        for form in try doc.select("#formdiv form").array() {
            guard !form.parents().array().contains(where:{ ((try? $0.attr("class")) ?? "").split(separator:" ").contains("c6") }) else { continue }
            guard let textarea = try form.select("textarea[name=commenttext_new]").first() else { continue }
            guard try form.attr("method").lowercased()=="post" else { throw AppError.parseMismatch }
            let actionText = try form.attr("action")
            let target = actionText.isEmpty ? response.finalURL : try policy.siteURL(actionText,base:response.finalURL,site:request.scope.storage.site)
            var parts=URLComponents(url:target,resolvingAgainstBaseURL:false);parts?.fragment=nil
            guard let action=parts?.url else { throw AppError.parseMismatch }
            guard action.path == response.finalURL.path, action.query == nil, action.fragment == nil else { throw AppError.accessDenied }
            var fields: [String:SensitiveText] = [:]
            for input in try form.select("input[type=hidden]").array() {
                let name = try input.attr("name")
                guard !name.isEmpty, name != "edit_comment", name != "commenttext_edit", fields[name]==nil else { throw AppError.parseMismatch }
                let value = try input.attr("value")
                if !value.isEmpty { fields[name] = try SensitiveText(value) }
            }
            return CommentPostForm(action:action,fields:fields,maximumLength:Int(try textarea.attr("maxlength")))
        }
        throw CommentMutationError.unavailable
    }
    public func api(_ response: HTTPResponse, request: GalleryRequest) throws -> CommentAPI {
        let doc = try HTMLParsing.document(response,context:RequestContext(scope:request.scope,queryID:response.requestID),policy:ParsingPolicy())
        try HTMLParsing.checkReference(request.reference,response:response)
        let script = try doc.select("script").array().filter { element in
            !element.parents().array().contains { $0.id()=="cdiv" }
        }.map { try $0.data() }.joined(separator:"\n")
        guard let uidText = try HTMLParsing.capture(script,#"\bapiuid\s*=\s*([0-9]+)"#), let uid=Int64(uidText), uid>0,
              let key = try HTMLParsing.capture(script,#"\bapikey\s*=\s*["']([^"']{1,256})["']"#),
              let endpointText = try HTMLParsing.capture(script,#"\bapi_url\s*=\s*["']([^"']+)["']"#), let endpoint=URL(string:endpointText),
              endpoint.scheme=="https", endpoint.user==nil, endpoint.password==nil, endpoint.port==nil,
              endpoint.host==(request.scope.storage.site == .eh ? "api.e-hentai.org" : "s.exhentai.org"),
              endpoint.path=="/api.php", endpoint.query==nil, endpoint.fragment==nil else { throw CommentMutationError.unavailable }
        return CommentAPI(scope:request.scope,endpoint:endpoint,userID:uid,key:try SensitiveText(key))
    }
    public func receipt(_ response: HTTPResponse, requestURL: URL) -> String? {
        guard let location=HTMLParsing.header("location",response), let url=URL(string:location,relativeTo:requestURL)?.absoluteURL,
              url.scheme==requestURL.scheme, url.host==requestURL.host, url.port==requestURL.port,
              url.user==nil,url.password==nil,url.path==requestURL.path, let fragment=url.fragment,
              fragment.hasPrefix("comment_"), let id=Int64(fragment.dropFirst(8)),id>0 else { return nil }
        return String(id)
    }
}
