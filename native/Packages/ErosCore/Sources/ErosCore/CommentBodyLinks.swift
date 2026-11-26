import Foundation

public enum CommentLinkOrigin:String,Codable,Equatable,Sendable {case detected,anchor}

public enum CommentBodySegment:Codable,Equatable,Sendable {
    case text(String)
    case link(label:String,target:URL,origin:CommentLinkOrigin? = nil)
    public var text:String {switch self {case .text(let s):s;case .link(let s,_,_):s}}
    public var target:URL? {if case .link(_,let url,_)=self{return url};return nil}
    public var origin:CommentLinkOrigin? {if case .link(_,_,let origin)=self{return origin};return nil}
}
public enum CommentLinkAction:Equatable,Sendable {
    case gallery(ExternalLinkTarget)
    case browser(URL)
    case inert
}
public enum CommentLinkPolicy {
    public static func webURL(_ raw:String,relativeTo base:URL? = nil) -> URL? {
        guard !raw.isEmpty,raw.count<=2048,raw.rangeOfCharacter(from:.controlCharacters)==nil,!raw.contains("\\"),
              let url=URL(string:raw,relativeTo:base)?.absoluteURL,
              let p=URLComponents(url:url,resolvingAgainstBaseURL:false),
              ["http","https"].contains(p.scheme?.lowercased() ?? ""),p.user==nil,p.password==nil,
              let host=p.host?.lowercased(),!host.isEmpty,url.absoluteString.count<=2048 else{return nil}
        let trusted=["e-hentai.org","exhentai.org"]
        if trusted.contains(where:{host.contains($0) && host != $0 && !host.hasSuffix("."+$0)}) {return nil}
        if trusted.contains(host),
           (p.queryItems ?? []).contains(where:{["act","action","method"].contains($0.name.lowercased())}) {return nil}
        return url
    }
    public static func action(_ url:URL) -> CommentLinkAction {
        guard let safe=webURL(url.absoluteString) else{return .inert}
        if let target=try? ExternalLinkParser.parse(safe.absoluteString) {return .gallery(target)}
        return .browser(safe)
    }
}
/// Literal URLs only: never interpret user Markdown or recover a lost href from its label.
public enum BareWebLinks {
    public static func segments(_ text:String) -> [CommentBodySegment] {
        guard text.utf8.count<=100_000,text.range(of:"http",options:.caseInsensitive) != nil,
              let tokens=LiteralURLTokens.scan(text,maximum:CommentBodyPresentation.maximumLinks) else{return [.text(text)]}
        var result:[CommentBodySegment]=[];var cursor=text.startIndex
        for token in tokens {
            guard let url=CommentLinkPolicy.webURL(token.text) else{continue}
            if cursor<token.range.lowerBound {result.append(.text(String(text[cursor..<token.range.lowerBound])))}
            result.append(.link(label:String(text[token.range]),target:url,origin:.detected));cursor=token.range.upperBound
        }
        if cursor<text.endIndex {result.append(.text(String(text[cursor...])))}
        return result.isEmpty ? [.text(text)] : result
    }
    public static func trimURL(_ text:String) -> String {
        var s=text
        let pairs:[Character:Character]=[")":"(","]":"[","}":"{","）":"（","】":"【","》":"《","」":"「"]
        var counts:[Character:Int]=[:]
        for c in s where pairs[c] != nil || pairs.values.contains(c) {counts[c,default:0]+=1}
        while let last=s.last {
            if let opening=pairs[last] {
                guard counts[last,default:0]>counts[opening,default:0] else{break}
                counts[last,default:0]-=1;s.removeLast()
            } else if ".,;!，。；！".contains(last) {s.removeLast()}
            else {break}
        }
        return s
    }
}
public enum CommentBodyPresentation {
    public static let maximumLinks=64
    public static let maximumSegments=512
    // Old caches have no origin metadata. Preserve ambiguous Unicode href values;
    // only known encoded boundaries or a complete gallery/image prefix establish repair.
    private static func mayRepairLegacy(_ label:String) -> Bool {
        guard label.unicodeScalars.contains(where:{!$0.isASCII}) else{return true}
        guard let first=LiteralURLTokens.scan(label,maximum:maximumLinks)?.first else{return false}
        return first.hasEncodedBoundary || (try? ExternalLinkParser.parse(first.text)) != nil
    }
    public static func segments(for comment:GalleryComment) -> [CommentBodySegment] {
        guard let saved=comment.bodySegments else{return BareWebLinks.segments(comment.body)}
        guard saved.count<=maximumSegments,saved.filter({$0.target != nil}).count<=maximumLinks,
              saved.map(\.text).joined()==comment.body else{return [.text(comment.body)]}
        var result:[CommentBodySegment]=[]
        for segment in saved {
            let parts:[CommentBodySegment]
            if case .link(let label,let url,let origin)=segment,origin != .anchor,
               CommentLinkPolicy.webURL(url.absoluteString) != nil,
               label.lowercased().hasPrefix("http"),URL(string:label)==url,
               origin == .detected || mayRepairLegacy(label) {
                // Repair detected/legacy literal runs; explicit href and different labels stay authoritative.
                parts=BareWebLinks.segments(label)
            } else if case .link(let label,let url,_)=segment,CommentLinkPolicy.webURL(url.absoluteString)==nil {
                parts=[.text(label)]
            } else {parts=[segment]}
            guard result.count+parts.count<=maximumSegments else{return [.text(comment.body)]}
            result+=parts
        }
        guard result.filter({$0.target != nil}).count<=maximumLinks else{return [.text(comment.body)]}
        return result
    }
}
