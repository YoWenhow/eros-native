import Foundation

public struct GalleryLinkCandidate:Hashable,Sendable,Identifiable {
    public let target:ExternalLinkTarget
    public let url:URL
    public var id:ExternalLinkTarget {target}
    public init(target:ExternalLinkTarget,url:URL) {self.target=target;self.url=url}
}
public enum ClipboardLinkError:Error,Equatable,Sendable {case unavailable,changed,tooLarge,tooMany,noSupportedLink}
public enum ClipboardLinkCandidates {
    public static let maximumUTF8Bytes=16*1024
    public static let maximumCandidates=10
    public static func parse(_ text:String) throws -> [GalleryLinkCandidate] {
        guard text.utf8.count<=maximumUTF8Bytes else{throw ClipboardLinkError.tooLarge}
        let raw:[String]
        if (try? ExternalLinkParser.parse(text)) != nil {raw=[text.trimmingCharacters(in:.whitespacesAndNewlines)]}
        else {
            guard let tokens=LiteralURLTokens.scan(text,maximum:2048) else{throw ClipboardLinkError.tooMany}
            raw=tokens.map(\.text)
        }
        var seen=Set<ExternalLinkTarget>();var result:[GalleryLinkCandidate]=[]
        for value in raw {
            try Task.checkCancellation()
            guard let target=try? ExternalLinkParser.parse(value),seen.insert(target).inserted else{continue}
            let url:URL
            switch target {
            case .gallery(let ref):
                url=URL(string:"https://"+(ref.key.site == .eh ? "e-hentai.org" : "exhentai.org")+"/g/"+String(ref.key.galleryID.value)+"/"+ref.token.value+"/")!
            case .image(_,_,_,let value):url=value
            }
            result.append(GalleryLinkCandidate(target:target,url:url))
            guard result.count<=maximumCandidates else{throw ClipboardLinkError.tooMany}
        }
        guard !result.isEmpty else{throw ClipboardLinkError.noSupportedLink}
        return result
    }
}
