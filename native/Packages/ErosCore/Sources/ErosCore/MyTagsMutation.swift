import Foundation
import SwiftSoup

public struct MyTagsProperties:Codable,Equatable,Sendable {
    public let watched:Bool
    public let hidden:Bool
    public let color:String
    public let weight:Int
    public init(watched:Bool,hidden:Bool,color:String,weight:Int) throws {
        let trimmed=color.trimmingCharacters(in:.whitespacesAndNewlines)
        let color=trimmed.isEmpty ? "" : (trimmed.hasPrefix("#") ? trimmed : "#"+trimmed).uppercased()
        guard !(watched && hidden),(-99...99).contains(weight),color.isEmpty || color.range(of:#"^#[0-9A-F]{6}$"#,options:.regularExpression) != nil else { throw AppError.invalidInput }
        self.watched=watched;self.hidden=hidden;self.color=color;self.weight=weight
    }
    public init(entry:MyTagsEntry) throws {
        guard let watch=entry.watched,let hide=entry.hidden,let weight=entry.weight,let usesDefault=entry.color.usesDefault,
              usesDefault || entry.color.hexRGB != nil else { throw AppError.unsupportedContent }
        try self.init(watched:watch,hidden:hide,color:usesDefault ? "" : entry.color.raw ?? "",weight:weight)
    }
    public func validate() throws { guard try Self(watched:watched,hidden:hidden,color:color,weight:weight)==self else { throw AppError.invalidInput } }
}
public enum MyTagsMutation:Codable,Equatable,Sendable {
    case add(setID:String,namespace:String,original:String,properties:MyTagsProperties)
    case update(base:MyTagsEntry,properties:MyTagsProperties)
    case remove(base:MyTagsEntry)
    public var setID:String { switch self { case .add(let id,_,_,_):id;case .update(let base,_),.remove(let base):base.setID } }
    public var base:MyTagsEntry? { switch self {case .add:nil;case .update(let base,_),.remove(let base):base} }
    public var properties:MyTagsProperties? { switch self {case .add(_,_,_,let props),.update(_,let props):props;case .remove:nil} }
    public var canonical:String { switch self { case .add(_,let ns,let raw,_):ns+":"+raw;case .update(let base,_),.remove(let base):base.canonicalName } }
    public var kind:String { switch self {case .add:"add";case .update:"update";case .remove:"remove"} }
    public func validate() throws {
        try MyTagsIdentity.validate(setID,allowZero:true)
        switch self {
        case .add(_,let ns,let raw,let properties):
            let tag=try TagMutation(namespace:ns,original:raw,direction:1)
            guard tag.original==raw else { throw AppError.invalidInput };try properties.validate()
        case .update(let base,let props):try MyTagsIdentity.validate(base.tagID);_=try MyTagsProperties(entry:base);try props.validate()
        case .remove(let base):try MyTagsIdentity.validate(base.tagID);guard !base.original.isEmpty else { throw AppError.invalidInput }
        }
    }
}
public enum MyTagsMutationReason:String,Codable,Sendable { case changed,alreadyPresent,unavailable,refused,unconfirmed,cancelled }
public enum MyTagsMutationState:String,Codable,Sendable { case draft,submitting,confirmed,rejected,unknown,conflict,cancelled }
public struct MyTagsMutationStep:Codable,Equatable,Sendable,Identifiable {
    public let id:UUID
    public var attemptID:UUID?
    public var action:MyTagsMutation
    public var state:MyTagsMutationState
    public var reason:MyTagsMutationReason?
    public var latest:MyTagsEntry?
    public var confirmedByUser:Bool
    public init(action:MyTagsMutation) { id=UUID();self.action=action;attemptID=nil;state = .draft;reason=nil;latest=nil;confirmedByUser=false }
}
public struct MyTagsMutationBatch:Codable,Equatable,Sendable {
    public let id:UUID
    public var generation:UInt64
    public var steps:[MyTagsMutationStep]
    public init(actions:[MyTagsMutation],generation:UInt64) throws {
        guard !actions.isEmpty,actions.count<=50 else { throw AppError.invalidInput }
        for action in actions { try action.validate() }
        let targets=actions.compactMap{$0.base?.tagID}
        guard Set(targets).count==targets.count else { throw AppError.invalidInput }
        id=UUID();self.generation=generation;steps=actions.map(MyTagsMutationStep.init)
    }
    public init(id:UUID,generation:UInt64,steps:[MyTagsMutationStep]) { self.id=id;self.generation=generation;self.steps=steps }
    public var unresolved:Bool { steps.contains{$0.state == .unknown || $0.state == .submitting} }
    public var hasDrafts:Bool { steps.contains{$0.state == .draft} }
    public var redactedReport:String {
        let rows=steps.map{["operation":$0.id.uuidString,"kind":$0.action.kind,"state":$0.state.rawValue,"confirmedByUser":String($0.confirmedByUser)]}
        return (try? String(decoding:JSONSerialization.data(withJSONObject:["schema":1,"steps":rows],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)) ?? "{}"
    }
}
public struct MyTagsWriteForm:Sendable {
    public let action:URL
    public let hidden:[String:String]
    public let canAdd:Bool
    public let removableIDs:Set<String>
}
public struct MyTagsWriteParser:Sendable {
    public init() {}
    private func document(_ response:HTTPResponse,scope:SessionScope) throws -> Document {
        guard response.finalURL.path=="/mytags" else { throw AppError.accessDenied }
        return try HTMLParsing.document(response,context:RequestContext(scope:scope,queryID:response.requestID),policy:ParsingPolicy())
    }
    public func api(_ response:HTTPResponse,scope:SessionScope) throws -> CommentAPI {
        let doc=try document(response,scope:scope)
        let scripts=try doc.select("script:not([src])").array().filter { element in !element.parents().array().contains{$0.id()=="tagset_outer" || $0.id()=="usertags_outer"} }.map{$0.data()}.joined(separator:"\n")
        guard let uidText=try HTMLParsing.capture(scripts,#"\bapiuid\s*=\s*([0-9]+)"#),let uid=Int64(uidText),uid>0,
              let key=try HTMLParsing.capture(scripts,#"\bapikey\s*=\s*["']([^"']{1,256})["']"#),
              let raw=try HTMLParsing.capture(scripts,#"\bapi_url\s*=\s*["']([^"']+)["']"#),let url=URL(string:raw),url.scheme=="https",url.user==nil,url.password==nil,url.port==nil,
              url.host==(scope.storage.site == .eh ? "api.e-hentai.org" : "s.exhentai.org"),url.path=="/api.php",url.query==nil,url.fragment==nil else { throw AppError.accessDenied }
        return CommentAPI(scope:scope,endpoint:url,userID:uid,key:try SensitiveText(key))
    }
    public func allowsUpdate(_ response:HTTPResponse,scope:SessionScope,tagID:String) throws -> Bool {
        try MyTagsIdentity.validate(tagID);let doc=try document(response,scope:scope)
        guard let row=try doc.select("#usertags_outer > #usertag_"+tagID).first() else { return false }
        for suffix in ["watch","hide","color","weight"] {
            let elements=try row.select("input[id=tag"+suffix+"_"+tagID+"]").array()
            guard elements.count==1,let input=elements.first,!input.hasAttr("disabled"),!input.hasAttr("readonly") else { return false }
        }
        return true
    }
    public func form(_ response:HTTPResponse,scope:SessionScope) throws -> MyTagsWriteForm {
        let doc=try document(response,scope:scope)
        guard let form=try doc.select("form#usertag_form").first(),try form.attr("method").lowercased()=="post",
              try form.attr("enctype").isEmpty || form.attr("enctype").lowercased()=="application/x-www-form-urlencoded" else { throw AppError.accessDenied }
        let raw=try form.attr("action"),target=raw.isEmpty ? response.finalURL : try ParsingPolicy().siteURL(raw,base:response.finalURL,site:scope.storage.site)
        var parts=URLComponents(url:target,resolvingAgainstBaseURL:false);parts?.fragment=nil
        guard let action=parts?.url,action.path==response.finalURL.path,action.query==response.finalURL.query else { throw AppError.accessDenied }
        var hidden:[String:String]=[:]
        for input in try form.select("input[type=hidden]").array() {
            let name=try input.attr("name"),value=try input.attr("value")
            guard !name.isEmpty,name.utf8.count<=128,value.utf8.count<=4096,hidden.count<32,hidden[name]==nil,!name.hasPrefix("tagset_") else { throw AppError.parseMismatch };hidden[name]=value
        }
        guard hidden["usertag_action"] != nil else { throw AppError.parseMismatch }
        let add=try form.select("#tagsave_0").first()?.attr("onclick").range(of:#"^\s*do_usertags_post\(['"]add['"]\)\s*;?\s*(?:return\s+false;?)?\s*$"#,options:.regularExpression) != nil
        if add {
            for id in ["tagname_new","tagwatch_0","taghide_0","tagcolor_0","tagweight_0"] {
                guard let input=try form.select("#"+id).first(),!input.hasAttr("disabled"),!input.hasAttr("readonly") else {throw AppError.accessDenied}
            }
        }
        var ids=Set<String>()
        for input in try form.select("input[name='modify_usertags[]']").array() {
            let id=try input.attr("value");try MyTagsIdentity.validate(id)
            guard try input.attr("type").lowercased()=="checkbox",!input.hasAttr("disabled"),input.parents().array().contains(where:{$0.id()=="usertag_"+id}),ids.insert(id).inserted else { throw AppError.parseMismatch }
        }
        guard try form.select("select#usertag_target option[value=0]").first() != nil else { throw AppError.accessDenied }
        return MyTagsWriteForm(action:action,hidden:hidden,canAdd:add,removableIDs:ids)
    }
    public func updateReceipt(_ body:Data,tagID:String) throws -> Bool {
        struct Receipt:Decodable { let tagid:FlexibleID }
        let value=try JSONDecoder().decode(Receipt.self,from:body);return value.tagid.value==tagID
    }
}
private struct FlexibleID:Decodable {
    let value:String
    init(from decoder:any Decoder) throws {
        let c=try decoder.singleValueContainer()
        if let number=try? c.decode(Int64.self),number>0 { value=String(number);return }
        let text=try c.decode(String.self);try MyTagsIdentity.validate(text);value=text
    }
}
