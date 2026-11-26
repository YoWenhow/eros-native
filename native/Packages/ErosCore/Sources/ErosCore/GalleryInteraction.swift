import Foundation
import SwiftSoup

public struct RatingMutation: Codable, Equatable, Sendable {
    public let steps: Int
    public init(steps: Int) throws { guard (1...10).contains(steps) else { throw AppError.invalidInput };self.steps=steps }
    public var stars: Double { Double(steps)/2 }
}
public struct TagMutation: Codable, Equatable, Sendable {
    public static let namespaces=["language","parody","character","group","artist","cosplayer","male","female","mixed","other","location","reclass"]
    public let namespace: String
    public let original: String
    public let direction: Int
    public var canonical: String { namespace+":"+original }
    public init(namespace: String, original: String, direction: Int) throws {
        let original=original.trimmingCharacters(in:.whitespacesAndNewlines)
        guard Self.namespaces.contains(namespace),[-1,1].contains(direction),!original.isEmpty,
              !original.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),
              !original.contains(where:{",;:\"$\\[]".contains($0)}),
              (namespace+":"+original).utf16.count<=200 else { throw AppError.invalidInput }
        self.namespace=namespace;self.original=original;self.direction=direction
    }
}
public enum GalleryInteractionAction: Codable, Equatable, Sendable {
    case rating(RatingMutation)
    case tag(TagMutation)
    public func validate() throws {
        switch self {
        case .rating(let v): _=try RatingMutation(steps:v.steps)
        case .tag(let v): guard try TagMutation(namespace:v.namespace,original:v.original,direction:v.direction)==v else { throw AppError.invalidInput }
        }
    }
    public var summary: String {
        switch self {
        case .rating(let value): return String(format:"评分 %.1f 星",value.stars)
        case .tag(let value): return (value.direction==1 ? "标签赞成：" : "标签反对：")+value.canonical
        }
    }
}
public struct GalleryTagVote: Codable, Equatable, Sendable, Identifiable {
    public let namespace: String
    public let original: String
    public let vote: Int?
    public var id: String { namespace+":"+original }
}
public struct GalleryInteractionSnapshot: Codable, Equatable, Sendable {
    public let ratingSteps: [Int]
    public let hasPersonalRating: Bool?
    public let personalRating: Double?
    public let averageRating: Double?
    public let canAddTag: Bool
    public let tags: [GalleryTagVote]
}
public struct GalleryInteractionRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: GalleryInteractionAction
    public let generation: UInt64
    public var state: CommentMutationState
    public var confirmedByUser: Bool
    public init(id: UUID=UUID(),action: GalleryInteractionAction,generation: UInt64,state: CommentMutationState = .submitting) {
        self.id=id;self.action=action;self.generation=generation;self.state=state;confirmedByUser=false
    }
}
public struct GalleryInteractionParser: Sendable {
    public init() {}
    public func snapshot(_ response: HTTPResponse, request: GalleryRequest) throws -> GalleryInteractionSnapshot {
        let doc=try HTMLParsing.document(response,context:RequestContext(scope:request.scope,queryID:response.requestID),policy:ParsingPolicy())
        try HTMLParsing.checkReference(request.reference,response:response)
        func trusted(_ e: Element) -> Bool { !e.parents().array().contains{$0.id()=="cdiv"} }
        let steps=try doc.select("map[name=rating] area[onclick]").array().filter(trusted).compactMap { element -> Int? in
            let text=try element.attr("onclick")
            guard let raw=try HTMLParsing.capture(text,#"^\s*rating_set\(\s*([0-9]+)\s*\)\s*;?\s*$"#),let n=Int(raw),(1...10).contains(n) else { return nil };return n
        }
        let scripts=try doc.select("script:not([src])").array().filter(trusted).map{$0.data()}.joined(separator:"\n")
        func number(_ name: String) throws -> Double? {
            guard let raw=try HTMLParsing.capture(scripts,"\\b"+name+#"\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*;"#),let value=Double(raw),value.isFinite,(0...5).contains(value) else { return nil };return value
        }
        let cls=try doc.select("#rating_image").array().filter(trusted).first?.attr("class") ?? ""
        let own: Bool? = cls=="ir" ? false : cls.range(of:#"^ir[rgby]+$"#,options:.regularExpression) != nil ? true : nil
        let display=try number("display_rating")
        let personal=own==true && display.map({$0>=0.5 && ($0*2).rounded()==$0*2})==true ? display : nil
        let button=try doc.select("#newtagbutton").array().filter(trusted).first
        let add=try button?.attr("onclick").range(of:#"^\s*tag_from_field\(\s*\)\s*;?\s*(?:return\s+false;?)?\s*$"#,options:.regularExpression) != nil && button?.hasAttr("disabled") == false
        return GalleryInteractionSnapshot(ratingSteps:Array(Set(steps)).sorted(),hasPersonalRating:own,personalRating:personal,averageRating:try number("average_rating"),canAddTag:add,tags:try tags(doc))
    }
    private func tags(_ doc: Document) throws -> [GalleryTagVote] {
        var result:[GalleryTagVote]=[];var ids=Set<String>()
        for element in try doc.select("#taglist a[onclick]").array() {
            guard !element.parents().array().contains(where:{$0.id()=="cdiv"}) else { continue }
            let callback=try element.attr("onclick")
            guard let key=try HTMLParsing.capture(callback,#"^\s*return\s+toggle_tagmenu\(\s*[0-9]+\s*,\s*'([^']+)'\s*,\s*this\s*\)\s*;?\s*$"#),let colon=key.firstIndex(of:":") else { continue }
            let ns=String(key[..<colon]),original=String(key[key.index(after:colon)...])
            guard let valid=try? TagMutation(namespace:ns,original:original,direction:1),valid.canonical==key else { continue }
            guard result.count<2000,ids.insert(key).inserted else { throw AppError.parseMismatch }
            let cls=try element.attr("class")
            let vote:Int? = cls.isEmpty ? 0 : cls=="tup" ? 1 : cls=="tdn" ? -1 : nil
            result.append(GalleryTagVote(namespace:ns,original:original,vote:vote))
        }
        return result
    }
    public func tagPane(_ body: Data) throws -> [GalleryTagVote] {
        guard let object=try JSONSerialization.jsonObject(with:body) as? [String:Any],object["error"]==nil,object["login"]==nil,object["redirect"]==nil,
              let html=object["tagpane"] as? String,html.utf8.count<=1024*1024 else { throw AppError.parseMismatch }
        return try tags(SwiftSoup.parse("<div id='taglist'>"+html+"</div>"))
    }
    public func ratingReceipt(_ body: Data, expected: RatingMutation) throws -> Double {
        struct Wire: Decodable { let rating_avg: Double;let rating_usr: Double;let rating_cnt: Int;let rating_cls: String }
        guard let object=try JSONSerialization.jsonObject(with:body) as? [String:Any],object["error"]==nil,object["login"]==nil else { throw AppError.accessDenied }
        let value=try JSONDecoder().decode(Wire.self,from:body)
        guard value.rating_avg.isFinite,(0...5).contains(value.rating_avg),value.rating_usr==expected.stars,value.rating_cnt>=0,
              value.rating_cls.range(of:#"^ir[rgby]+$"#,options:.regularExpression) != nil else { throw AppError.parseMismatch }
        return value.rating_usr
    }
}
