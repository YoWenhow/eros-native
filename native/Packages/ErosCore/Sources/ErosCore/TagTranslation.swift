import Foundation

public enum TagTranslationError: Error, Equatable, Sendable {
    case invalidKey, invalidText, invalidManifest, unsupportedSchema, duplicateKey
}

/// Original server identity; localized names never participate in this key.
public struct TagTranslationKey: Hashable, Sendable {
    public let namespace: String
    public let original: String
    public init(namespace: String, original: String) throws {
        let allowed = ["reclass", "language", "parody", "character", "group", "artist", "cosplayer", "male", "female", "mixed", "other", "location"]
        guard allowed.contains(namespace), !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.utf8.count <= 1024, !original.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TagTranslationError.invalidKey
        }
        self.namespace = namespace; self.original = original
    }
}

/// Text-only presentation values. Render with plain Text, never HTML/WebView/Markdown.
/// Import-time sanitization and attribution retention belong to F08b.
public struct TagTranslationEntry: Equatable, Sendable {
    public let key: TagTranslationKey
    public let localizedText: String
    public let description: String?
    public init(namespace: String, original: String, localizedText: String, description: String? = nil) throws {
        key = try TagTranslationKey(namespace: namespace, original: original)
        guard !localizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              localizedText.utf8.count <= 4096, (description?.utf8.count ?? 0) <= 65536 else {
            throw TagTranslationError.invalidText
        }
        self.localizedText = localizedText; self.description = description?.isEmpty == true ? nil : description
    }

    /// Builds an exact-key contract index, rejecting conflicting duplicates rather than overwriting.
    /// This is not the persistent database or an update transaction.
    public static func index(_ entries: [Self]) throws -> [TagTranslationKey: Self] {
        var result: [TagTranslationKey: Self] = [:]
        for entry in entries {
            guard result.updateValue(entry, forKey: entry.key) == nil else { throw TagTranslationError.duplicateKey }
        }
        return result
    }
}

/// Pinned source contract. Hash syntax validation does not authenticate downloaded bytes.
/// F08b must compute SHA-256 and compare BEFORE importing or publishing a new version.
public struct TranslationManifest: Equatable, Sendable {
    public static let maximumByteCount = 16 * 1024 * 1024
    public let version: String
    public let hash: String
    public let schemaVersion: Int
    public let byteCount: Int
    public let sourceURL: URL
    public init(version: String, hash: String, schemaVersion: Int, byteCount: Int, sourceURL: URL) throws {
        guard schemaVersion == 7 else { throw TagTranslationError.unsupportedSchema }
        guard version.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
              (1...Self.maximumByteCount).contains(byteCount),
              sourceURL.absoluteString == "https://github.com/EhTagTranslation/Database/releases/download/\(version)/db.text.json" else {
            throw TagTranslationError.invalidManifest
        }
        self.version = version; self.hash = hash; self.schemaVersion = schemaVersion
        self.byteCount = byteCount; self.sourceURL = sourceURL
    }
}
