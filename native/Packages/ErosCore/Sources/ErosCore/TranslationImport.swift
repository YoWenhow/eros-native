import Foundation
import SwiftSoup

public struct TranslationInstallation: Codable, Equatable, Sendable {
    public let version: String
    public let hash: String
    public let entryCount: Int
    public let sourceCommit: String
    public let license: String
    public let attribution: [String: String]
    public let namespaceNames: [String: String]
    public init(version: String, hash: String, entryCount: Int, sourceCommit: String, license: String, attribution: [String:String], namespaceNames: [String:String]) {
        self.version=version; self.hash=hash; self.entryCount=entryCount; self.sourceCommit=sourceCommit
        self.license=license; self.attribution=attribution; self.namespaceNames=namespaceNames
    }
}
public struct TranslationDataset: Sendable {
    public let installation: TranslationInstallation
    public let entries: [TagTranslationEntry]
    public init(installation: TranslationInstallation, entries: [TagTranslationEntry]) { self.installation=installation; self.entries=entries }
}

public enum TranslationImporter {
    private struct Document: Decodable { let repo: String; let head: Head; let version: Int; let data: [Group] }
    private struct Head: Decodable { let sha: String }
    private struct Group: Decodable { let namespace: String; let count: Int; let frontMatters: Front; let data: [String: Item] }
    private struct Front: Decodable { let copyright: String? }
    private struct Item: Decodable { let name: String; let intro: String; let links: String }
    public static func plainText(_ raw: String) throws -> String {
        guard raw.utf8.count <= 262144, !raw.contains("\0") else { throw TagTranslationError.invalidText }
        // The text variant may contain literal angle brackets. Parse only when a tag-like token exists.
        guard raw.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil else { return raw }
        let document = try SwiftSoup.parseBodyFragment(raw)
        try document.select("script,style,iframe,object,embed,img,svg,math,link,meta").remove()
        return try document.body()?.text() ?? ""
    }
    public static func parse(_ data: Data, manifest: TranslationManifest, license: String) throws -> TranslationDataset {
        try Task.checkCancellation()
        guard data.count == manifest.byteCount, data.count <= TranslationManifest.maximumByteCount,
              TranslationDigest.sha256(data) == manifest.hash else { throw TagTranslationError.invalidManifest }
        guard license.utf8.count <= 131072, license.contains("署名-非商业性使用-相同方式共享 3.0 中国大陆") else { throw TagTranslationError.invalidManifest }
        try TranslationJSONValidation.validate(data)
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.version == 7 else { throw TagTranslationError.unsupportedSchema }
        guard doc.repo == "https://github.com/EhTagTranslation/Database", doc.head.sha.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil,
              !doc.data.isEmpty, doc.data.count <= 13 else { throw TagTranslationError.invalidManifest }
        var namespaces=Set<String>(), entries=[TagTranslationEntry](), attribution=[String:String](), names=[String:String]()
        for group in doc.data {
            try Task.checkCancellation()
            guard namespaces.insert(group.namespace).inserted, group.count == group.data.count else { throw TagTranslationError.duplicateKey }
            guard group.namespace == "rows" || (try? TagTranslationKey(namespace: group.namespace, original: "probe")) != nil else { throw TagTranslationError.invalidKey }
            guard (group.frontMatters.copyright?.utf8.count ?? 0) <= 65536 else { throw TagTranslationError.invalidText }
            attribution[group.namespace] = group.frontMatters.copyright ?? ""
            for (original,item) in group.data {
                try Task.checkCancellation()
                let name = try plainText(item.name)
                if group.namespace == "rows" { names[original]=name; continue }
                let description = try plainText(item.intro)
                entries.append(try TagTranslationEntry(namespace: group.namespace, original: original, localizedText: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original : name, description: description))
                guard entries.count <= 200000 else { throw TagTranslationError.invalidManifest }
            }
        }
        guard !entries.isEmpty else { throw TagTranslationError.invalidManifest }
        return TranslationDataset(installation: TranslationInstallation(version: manifest.version, hash: manifest.hash, entryCount: entries.count, sourceCommit: doc.head.sha, license: license, attribution: attribution, namespaceNames: names), entries: entries)
    }
}

/// Validates JSON grammar and decoded object-key uniqueness before Foundation decoding.
/// Explicit stack depth and input size bounds prevent adversarial recursion.
public enum TranslationJSONValidation {
    public static func validate(_ data: Data) throws {
        guard data.count <= TranslationManifest.maximumByteCount else { throw TagTranslationError.invalidManifest }
        var scanner=Scanner(bytes:Array(data)); try scanner.value(0); scanner.space()
        guard scanner.index == scanner.bytes.count else { throw TagTranslationError.invalidManifest }
    }
    private struct Scanner {
        let bytes:[UInt8]; var index=0
        mutating func space() { while index<bytes.count && [9,10,13,32].contains(bytes[index]) { index+=1 } }
        mutating func take(_ c:UInt8) -> Bool { space(); if index<bytes.count && bytes[index]==c { index+=1; return true }; return false }
        mutating func string() throws -> String {
            space(); let start=index
            guard take(34) else { throw TagTranslationError.invalidManifest }
            while index<bytes.count {
                let c=bytes[index]; index+=1
                if c==92 { guard index<bytes.count else { break }; index+=1 }
                else if c==34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<index])) }
            }
            throw TagTranslationError.invalidManifest
        }
        mutating func value(_ depth:Int) throws {
            try Task.checkCancellation(); guard depth<32 else { throw TagTranslationError.invalidManifest }; space()
            guard index<bytes.count else { throw TagTranslationError.invalidManifest }
            if take(123) {
                var keys=Set<String>(); if take(125) { return }
                repeat { let key=try string(); guard keys.insert(key).inserted else { throw TagTranslationError.duplicateKey }
                    guard take(58) else { throw TagTranslationError.invalidManifest }; try value(depth+1)
                    if take(125) { return }
                } while take(44)
                throw TagTranslationError.invalidManifest
            } else if take(91) {
                if take(93) { return }
                repeat { try value(depth+1); if take(93) { return } } while take(44)
                throw TagTranslationError.invalidManifest
            } else if bytes[index]==34 { _ = try string() }
            else {
                let start=index
                while index<bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index+=1 }
                guard index>start else { throw TagTranslationError.invalidManifest }
                _ = try JSONSerialization.jsonObject(with:Data(bytes[start..<index]),options:.fragmentsAllowed)
            }
        }
    }
}
