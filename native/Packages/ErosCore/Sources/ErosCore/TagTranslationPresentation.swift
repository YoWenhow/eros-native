import Foundation

public enum TagTranslationDisplayMode: String, Codable, CaseIterable, Sendable {
    case original, translated, both
}
public enum TagTranslationPresentation {
    public static func text(original:String, translated:String?, mode:TagTranslationDisplayMode) -> String {
        guard mode != .original, let translated, !translated.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, translated != original else { return original }
        return mode == .translated ? translated : translated + "（" + original + "）"
    }
    /// Search and download sort keys never use the localized label.
    public static func searchTerms(for key:TagTranslationKey) -> String { key.namespace + ":" + key.original }
    public static func categoryKey(_ category:String) -> TagTranslationKey? {
        let map=["Doujinshi":"doujinshi","Manga":"manga","Artist CG":"artistcg","Game CG":"gamecg","Non-H":"non-h","Image Set":"imageset","Western":"western","Cosplay":"cosplay","Misc":"misc","Asian Porn":"asianporn","Private":"private"]
        guard let canonical=map[category] else { return nil }
        return try? TagTranslationKey(namespace:"reclass",original:canonical)
    }
}

/// Detail-only namespace labels. Original keys and installed tag translations stay unchanged.
public struct DetailTagNamespacePresentation: Sendable {
    public let text: String
    public let accessibilityLabel: String

    private static let translatedNames = [
        "reclass": "分类", "language": "语言", "parody": "原作", "character": "角色",
        "group": "社团", "artist": "作者", "cosplayer": "扮演", "male": "男性",
        "female": "女性", "mixed": "混合", "other": "其他", "location": "地点",
        "misc": "杂项", "temp": "临时"
    ]

    public init(namespace: String?, mode: TagTranslationDisplayMode) {
        let namespace = namespace.flatMap { value in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value }
        let original = namespace ?? "标签"
        let knownName = namespace.flatMap { Self.translatedNames[$0] }
        let translated = knownName ?? (namespace == nil ? "标签" : "其他")
        text = TagTranslationPresentation.text(original: original, translated: translated, mode: mode)

        let fullName = namespace == "cosplayer" ? "角色扮演者" : translated
        // An unknown namespace must remain identifiable even when its visible label is "其他".
        let accessibilityMode: TagTranslationDisplayMode = mode == .translated && namespace != nil && knownName == nil ? .both : mode
        accessibilityLabel = TagTranslationPresentation.text(original: original, translated: fullName, mode: accessibilityMode)
    }
}

public struct TranslationReadSnapshot: Sendable {
    public let installation:TranslationInstallation?
    public let entries:[TagTranslationKey:TagTranslationEntry]
    public init(installation:TranslationInstallation?,entries:[TagTranslationKey:TagTranslationEntry]) { self.installation=installation;self.entries=entries }
}
