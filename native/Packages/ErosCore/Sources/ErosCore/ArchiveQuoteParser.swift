import Foundation
import SwiftSoup

public struct ArchiveOffer: Sendable {
    public let quote: ArchiveQuote
    public let action: URL
    public let fields: [String: SensitiveText]
    public let priceLabel: String
    public var variant: DownloadVariant { quote.variant }
}

/// Evidence-based local-archive forms only. H@H is a different service, never treated as a local archive.
public struct ArchiveQuoteParser: Sendable {
    public let policy: ParsingPolicy
    public init(policy: ParsingPolicy = ParsingPolicy()) { self.policy=policy }
    public func parse(_ response: HTTPResponse, request: GalleryRequest, now: Date) throws -> [ArchiveOffer] {
        let doc=try HTMLParsing.document(response,context:RequestContext(scope:request.scope,queryID:response.requestID),policy:policy)
        try validate(response.finalURL,request:request)
        var result:[ArchiveOffer]=[]
        for form in try doc.select("#db form").array() {
            guard let control=try form.select("button[name=dlcheck], input[name=dlcheck]").first() else { continue }
            let label=try control.attr("value")
            let variant:DownloadVariant
            switch label {
            case "Download Original Archive": variant = .original
            case "Download Resample Archive": variant = .display
            default: throw AppError.parseMismatch
            }
            guard !control.hasAttr("disabled"),try form.attr("method").lowercased()=="post",
                  !result.contains(where:{$0.variant==variant}),let parent=form.parent() else { throw AppError.parseMismatch }
            let raw=try form.attr("action")
            let action=try policy.siteURL(raw.isEmpty ? response.finalURL.absoluteString : raw,base:response.finalURL,site:request.scope.storage.site)
            try validate(action,request:request)
            guard action==response.finalURL else { throw AppError.parseMismatch }
            let inputs=try form.select("input[type=hidden]").array()
            var fields:[String:SensitiveText]=[:]
            for input in inputs {
                let name=try input.attr("name"),value=try input.attr("value")
                guard name=="dltype",fields[name]==nil,!value.isEmpty,value.utf8.count<=256 else { throw AppError.parseMismatch }
                fields[name]=try SensitiveText(value)
            }
            guard fields["dltype"]?.value == (variant == .original ? "org" : "res") else { throw AppError.parseMismatch }
            fields["dlcheck"]=try SensitiveText(label)
            let strongs=try parent.select("strong").array()
            guard strongs.count==2 else { throw AppError.parseMismatch }
            let priceLabel=try strongs[0].text(),sizeLabel=try strongs[1].text()
            guard sizeLabel.range(of:#"^[0-9]+(?:[.,][0-9]+)?\s*(?:KiB|MiB|GiB|KB|MB|GB|B)$"#,options:.regularExpression) != nil else { throw AppError.parseMismatch }
            let binding=action.absoluteString+"\n"+fields.keys.sorted().map { $0+"="+fields[$0]!.value }.joined(separator:"\n")
            let quote=try ArchiveQuote(scope:request.scope,gallery:request.reference.key.galleryID,variant:variant,
                price:Self.price(priceLabel),sizeLabel:sizeLabel,serverBinding:SensitiveText(binding),acquiredAt:now,
                expiresAt:now.addingTimeInterval(60)) // Conservative client display window, not a server TTL claim.
            result.append(ArchiveOffer(quote:quote,action:action,fields:fields,priceLabel:priceLabel))
        }
        guard !result.isEmpty else { throw AppError.parseMismatch }
        return result
    }
    public static func price(_ label: String) -> ArchivePrice {
        let label=label.trimmingCharacters(in:.whitespacesAndNewlines)
        if ["Free!","Free","免费","免費"].contains(label) { return .free }
        guard let expression=try? NSRegularExpression(pattern:#"^([0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.([0-9]+))?\s+(GP|Credits|Hath)$"#),
              let match=expression.firstMatch(in:label,range:NSRange(label.startIndex...,in:label)),
              let whole=Range(match.range(at:1),in:label),let currency=Range(match.range(at:3),in:label) else { return .unknown }
        var amount=String(label[whole]).replacingOccurrences(of:",",with:"")
        if let fraction=Range(match.range(at:2),in:label) { amount += "."+label[fraction] }
        guard let decimal=Decimal(string:amount,locale:Locale(identifier:"en_US_POSIX")) else { return .unknown }
        return .amount(decimal,currency:String(label[currency]))
    }
    private func validate(_ url: URL, request: GalleryRequest) throws {
        try request.reference.validate(scope:request.scope)
        _=try policy.siteURL(url.absoluteString,base:url,site:request.scope.storage.site)
        let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        guard url.path=="/archiver.php",url.fragment==nil,query.count==2,
              query.filter({$0.name=="gid"}).count==1,query.filter({$0.name=="token"}).count==1,
              query.first(where:{$0.name=="gid"})?.value==String(request.reference.key.galleryID.value),
              query.first(where:{$0.name=="token"})?.value==request.reference.token.value else { throw AppError.parseMismatch }
    }
}
