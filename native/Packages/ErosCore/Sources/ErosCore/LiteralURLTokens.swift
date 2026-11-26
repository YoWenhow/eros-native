import Foundation

public struct LiteralURLToken {
    public let range:Range<String.Index>
    public let text:String
    let hasEncodedBoundary:Bool
}
/// Bare URLs use the original Flutter project's ASCII boundary: adjacent Unicode stays prose.
/// Explicit HTML href values do not pass through this scanner. Percent-encoded paths and
/// existing query/action parameter checks remain intact.
public enum LiteralURLTokens {
    public static func scan(_ text:String,maximum:Int) -> [LiteralURLToken]? {
        guard let pattern=try? NSRegularExpression(pattern:#"(?:https?://|erosnative://)[-A-Za-z0-9+&@#/%?=~_|!:,.;$()\[\]{}]+"#,options:.caseInsensitive),
              let encoded=try? NSRegularExpression(pattern:#"&(?:lt|gt|quot|apos|nbsp|NewLine|Tab);|&#(?:0*(?:9|10|13|160|8203|8232|8233|65279)|x0*(?:9|a|d|a0|200b|2028|2029|feff));|%(?:0[ad9]|3[ce])|%e2%80%(?:8b|a8|a9)|%e2%81%a0|%ef%bb%bf"#,options:.caseInsensitive) else{return nil}
        var cursor=text.startIndex;var result:[LiteralURLToken]=[]
        while cursor<text.endIndex,
              let match=pattern.firstMatch(in:text,range:NSRange(cursor..<text.endIndex,in:text)),
              let rawRange=Range(match.range,in:text) {
            var end=rawRange.upperBound
            // Serialized HTML/newline suffixes can occur in URL representations. Only path
            // boundaries are repaired; queries and fragments retain the strict existing policy.
            let raw=String(text[rawRange])
            if let boundary=encoded.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)),
               let range=Range(boundary.range,in:raw),
               !raw[..<range.lowerBound].contains(where:{$0=="?" || $0=="#"}) {
                end=text.index(rawRange.lowerBound,offsetBy:raw.distance(from:raw.startIndex,to:range.lowerBound))
            }
            let clean=BareWebLinks.trimURL(String(text[rawRange.lowerBound..<end]))
            if !clean.isEmpty {
                let cleanEnd=text.index(rawRange.lowerBound,offsetBy:clean.count)
                result.append(LiteralURLToken(range:rawRange.lowerBound..<cleanEnd,text:clean,hasEncodedBoundary:end<rawRange.upperBound))
                if result.count>maximum {return nil}
            }
            cursor=end
        }
        return result
    }
}
