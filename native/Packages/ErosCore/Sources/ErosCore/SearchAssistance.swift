import Foundation

public enum SearchAssistance {
    public static func tokens(_ text:String) -> [String] {
        var values=[String](), token="", quoted=false
        for char in text {
            if char == "\"" { quoted.toggle() }
            if char.isWhitespace && !quoted { if !token.isEmpty { values.append(token); token="" } }
            else { token.append(char) }
        }
        if !token.isEmpty { values.append(token) }; return values
    }
    public static func fragment(_ draft:String) -> String { tokens(draft).last ?? "" }
    public static func namespace(_ value:String) -> String {
        ["画师":"artist","作者":"artist","社团":"group","团体":"group","原作":"parody","作品":"parody","角色":"character","语言":"language","标签":"tag","a":"artist","g":"group","circle":"group","f":"female","m":"male","l":"language","lang":"language","p":"parody","c":"character","char":"character","o":"other","x":"mixed","r":"reclass","cos":"cosplayer"][value.lowercased()] ?? value.lowercased()
    }
    public static func lookupParts(_ text:String) -> (String?,String) {
        var value=text.precomposedStringWithCompatibilityMapping
        while value.first == "-" || value.first == "~" { value.removeFirst() }
        let pair=value.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
        let ns=pair.count == 2 ? namespace(String(pair[0])) : nil
        let term=String(pair.last ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"\"$ "))
        return (ns == "tag" ? nil : ns,term)
    }
    public static func formula(_ key:TagTranslationKey) -> String? {
        guard !key.original.contains("\""), !key.original.contains("\\"), !key.original.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { return nil }
        return key.namespace + ":\"" + key.original + "$\""
    }
    public static func inserting(_ formula:String, into draft:String) -> String {
        var parts=tokens(draft)
        let previous=parts.popLast() ?? ""
        let prefix=previous.first == "-" ? "-" : previous.first == "~" ? "~" : ""
        parts.append(prefix+formula); return parts.joined(separator:" ")
    }
    public static func keys(in terms:String) -> [TagTranslationKey] {
        tokens(terms).compactMap { token in
            let (ns,term)=lookupParts(token)
            guard let ns else { return nil }
            return try? TagTranslationKey(namespace:ns,original:term)
        }
    }
}
