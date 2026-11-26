import Foundation
import SwiftSoup

public enum MyTagsIdentity {
    public static func validate(_ value:String,allowZero:Bool=false) throws {
        guard let number=Int64(value),number >= (allowZero ? 0 : 1),String(number)==value else { throw AppError.invalidInput }
    }
}
public struct MyTagsSet:Codable,Equatable,Sendable,Identifiable {
    public let id:String
    public let name:String
    public let tagCount:Int?
}
public struct MyTagsColor:Codable,Equatable,Sendable {
    public let raw:String?
    public let usesDefault:Bool?
    public var hexRGB:String? {
        guard let raw,raw.range(of:#"^#[0-9A-Fa-f]{6}$"#,options:.regularExpression) != nil else { return nil };return raw
    }
}
public struct MyTagsEntry:Codable,Equatable,Sendable,Identifiable {
    public let setID:String
    public let tagID:String
    public let namespace:String?
    public let original:String
    public let watched:Bool?
    public let hidden:Bool?
    public let color:MyTagsColor
    public let weight:Int?
    public var id:String { setID+":"+tagID }
    public var canonicalName:String { (namespace.map{$0+":"} ?? "")+original }
}
public struct MyTagsPage:Codable,Equatable,Sendable {
    public let site:Site
    public let sets:[MyTagsSet]
    public let selectedSetID:String
    public let enabled:Bool?
    public let defaultColor:MyTagsColor
    public let entries:[MyTagsEntry]
    /// No pagination protocol is invented when the server returns only a subset.
    public var matchesDeclaredCount:Bool? { sets.first{$0.id==selectedSetID}?.tagCount.map{$0==entries.count} }
    public func validate() throws {
        try MyTagsIdentity.validate(selectedSetID,allowZero:true)
        guard !sets.isEmpty,sets.count<=200,entries.count<=20_000,Set(sets.map(\.id)).count==sets.count,
              sets.contains(where:{$0.id==selectedSetID}),Set(entries.map(\.tagID)).count==entries.count else { throw AppError.parseMismatch }
        for set in sets { try MyTagsIdentity.validate(set.id,allowZero:true);guard !set.name.isEmpty,set.name.utf8.count<=4096,set.tagCount.map({$0>=0}) ?? true else { throw AppError.parseMismatch } }
        for entry in entries {
            try MyTagsIdentity.validate(entry.tagID)
            guard entry.setID==selectedSetID,!entry.original.isEmpty,entry.original.utf8.count<=4096,entry.namespace.map({!$0.isEmpty && $0.utf8.count<=128}) ?? true,
                  (entry.color.raw?.utf8.count ?? 0)<=256 else { throw AppError.parseMismatch }
        }
        guard (defaultColor.raw?.utf8.count ?? 0)<=256 else { throw AppError.parseMismatch }
    }
}
public struct MyTagsSnapshot:Codable,Equatable,Sendable {
    public let page:MyTagsPage
    public let fetchedAt:Date
    public init(page:MyTagsPage,fetchedAt:Date) { self.page=page;self.fetchedAt=fetchedAt }
}
public struct MyTagsParser:Sendable {
    public init() {}
    public func parse(_ response:HTTPResponse,scope:SessionScope,requestedSetID:String?=nil) throws -> MyTagsPage {
        if let requestedSetID { try MyTagsIdentity.validate(requestedSetID,allowZero:true) }
        guard response.scope==scope else { throw AppError.staleSession }
        guard response.body.count<=8*1024*1024 else { throw AppError.unsupportedContent }
        let doc=try HTMLParsing.document(response,context:RequestContext(scope:scope,queryID:response.requestID),policy:ParsingPolicy())
        guard response.finalURL.path=="/mytags",response.finalURL.fragment==nil else { throw AppError.parseMismatch }
        let query=URLComponents(url:response.finalURL,resolvingAgainstBaseURL:false)?.queryItems ?? []
        guard query.count<=1,query.allSatisfy({$0.name=="tagset" && (try? MyTagsIdentity.validate($0.value ?? "",allowZero:true)) != nil}) else { throw AppError.parseMismatch }
        guard let outer=try doc.select("#tagset_outer").first(),let selector=try outer.select("select[onchange]").first(),
              try selector.attr("onchange").range(of:#"^\s*change_tagset\(this\.value\)\s*;?\s*$"#,options:.regularExpression) != nil,
              let rows=try doc.select("#usertags_outer").first() else { throw AppError.parseMismatch }
        let options=try selector.select("option").array();guard !options.isEmpty,options.count<=200 else { throw AppError.parseMismatch }
        var sets:[MyTagsSet]=[];var selected:[String]=[]
        for option in options {
            let id=try option.attr("value"),label=try option.text().trimmingCharacters(in:.whitespacesAndNewlines)
            try MyTagsIdentity.validate(id,allowZero:true)
            let countText=try HTMLParsing.capture(label,#"\(([0-9]+)\)\s*$"#)
            let count=countText.flatMap(Int.init)
            if countText != nil && count==nil { throw AppError.parseMismatch }
            let name=countText==nil ? label : label.replacingOccurrences(of:#"\s*\([0-9]+\)\s*$"#,with:"",options:.regularExpression)
            sets.append(MyTagsSet(id:id,name:name,tagCount:count))
            if option.hasAttr("selected") { selected.append(id) }
        }
        guard selected.count<=1,let selectedID=selected.first ?? sets.first?.id,requestedSetID.map({$0==selectedID}) ?? true else { throw AppError.parseMismatch }
        func field(_ root:Element,_ id:String) throws -> Element? {
            let found=try root.select("input[id="+id+"]").array();guard found.count<=1 else { throw AppError.parseMismatch };return found.first
        }
        func checked(_ root:Element,_ id:String) throws -> Bool? {
            guard let input=try field(root,id),try input.attr("type").lowercased()=="checkbox" else { return nil };return input.hasAttr("checked")
        }
        func color(_ root:Element,_ id:String) throws -> MyTagsColor {
            guard let input=try field(root,id),input.hasAttr("value") else { return MyTagsColor(raw:nil,usesDefault:nil) }
            let text=try input.attr("value");guard text.utf8.count<=256 else { throw AppError.unsupportedContent }
            return MyTagsColor(raw:text.isEmpty ? nil : text,usesDefault:text.isEmpty)
        }
        var entries:[MyTagsEntry]=[]
        for row in rows.children().array() {
            try Task.checkCancellation();let raw=row.id();guard raw.hasPrefix("usertag_") else { continue }
            let id=String(raw.dropFirst(8));try MyTagsIdentity.validate(id,allowZero:true);if id=="0" { continue }
            guard entries.count<20_000 else { throw AppError.unsupportedContent }
            let links=try row.select("a[href]").array().compactMap { anchor -> URL? in
                let value=try anchor.attr("href")
                guard let url=URL(string:value,relativeTo:response.finalURL)?.absoluteURL,url.path.hasPrefix("/tag/") else { return nil }
                guard url.scheme=="https",url.host==ParsingPolicy().host(for:scope.storage.site),url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil else { throw AppError.accessDenied };return url
            }
            guard links.count==1,let url=links.first else { throw AppError.parseMismatch }
            // URL.path is percent-decoded by Foundation. Use encoded path for one
            // decoding pass so literal %2B cannot become a separator space.
            let encoded=URLComponents(url:url,resolvingAgainstBaseURL:false)?.percentEncodedPath ?? ""
            guard let key=String(encoded.dropFirst(5)).replacingOccurrences(of:"+",with:" ").removingPercentEncoding,!key.isEmpty,!key.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw AppError.parseMismatch }
            let colon=key.firstIndex(of:":")
            let ns=colon.map{String(key[..<$0])}
            let original=colon.map{String(key[key.index(after:$0)...])} ?? key
            let weight=try field(row,"tagweight_"+id).flatMap { input -> Int? in
                guard input.hasAttr("value") else { return nil };return Int(try input.attr("value").trimmingCharacters(in:.whitespacesAndNewlines))
            }
            entries.append(MyTagsEntry(setID:selectedID,tagID:id,namespace:ns,original:original,watched:try checked(row,"tagwatch_"+id),hidden:try checked(row,"taghide_"+id),color:try color(row,"tagcolor_"+id),weight:weight))
        }
        if entries.isEmpty { guard sets.first(where:{$0.id==selectedID})?.tagCount==0 else { throw AppError.parseMismatch } }
        let page=MyTagsPage(site:scope.storage.site,sets:sets,selectedSetID:selectedID,enabled:try checked(outer,"tagset_enable"),defaultColor:try color(outer,"tagcolor"),entries:entries)
        try page.validate();return page
    }
}
