import Foundation
import ErosCore
import ErosNetworking
import ErosPersistence

public actor TranslationUpdateService {
    private let fetcher:any TranslationDataFetcher
    public let store:TranslationStore
    private let temporaryDirectory:URL
    private let storageLease: StorageLease?
    private var busy=false
    public init(store:TranslationStore,temporaryDirectory:URL,fetcher:any TranslationDataFetcher=TranslationHTTPFetcher(), storageLease: StorageLease? = nil) {
        self.storageLease = storageLease
        self.store=store; self.temporaryDirectory=temporaryDirectory; self.fetcher=fetcher
    }
    public func check() async throws -> TranslationManifest {
        guard !busy else { throw AppError.invalidInput }; busy=true; defer { busy=false }
        return try await fetchManifest()
    }

    /// Check the public manifest and publish a new catalog only when its digest differs.
    /// The check, comparison, and install share one reservation with manual operations.
    public func updateIfNeeded() async throws -> Bool {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        guard !busy else { throw AppError.invalidInput }; busy=true; defer { busy=false }
        let manifest = try await fetchManifest()
        try storageLease?.check()
        let current = try await store.installation()
        try Task.checkCancellation()
        try storageLease?.check()
        guard current?.hash != manifest.hash else { return false }
        try await installManifest(manifest)
        return true
    }

    private func fetchManifest() async throws -> TranslationManifest {
        try Task.checkCancellation()
        let bytes=try await fetcher.fetch(URL(string:"https://api.github.com/repos/EhTagTranslation/Database/releases/latest")!,maximumBytes:1048576)
        guard bytes.count<=1048576 else { throw TagTranslationError.invalidManifest }
        try TranslationJSONValidation.validate(bytes)
        struct Asset:Decodable { let name:String; let size:Int; let digest:String?; let browser_download_url:URL }
        struct Release:Decodable { let tag_name:String; let draft:Bool; let prerelease:Bool; let assets:[Asset] }
        let release=try JSONDecoder().decode(Release.self,from:bytes)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v7.") else { throw TagTranslationError.unsupportedSchema }
        let assets=release.assets.filter{$0.name=="db.text.json"}
        guard assets.count==1, let asset=assets.first, let digest=asset.digest, digest.hasPrefix("sha256:") else { throw TagTranslationError.invalidManifest }
        try Task.checkCancellation()
        return try TranslationManifest(version:release.tag_name,hash:String(digest.dropFirst(7)),schemaVersion:7,byteCount:asset.size,sourceURL:asset.browser_download_url)
    }
    public func install(_ manifest:TranslationManifest) async throws {
        try storageLease?.admit()
        defer { storageLease?.finish() }
        guard !busy else { throw AppError.invalidInput }; busy=true; defer { busy=false }
        try await installManifest(manifest)
    }

    private func installManifest(_ manifest: TranslationManifest) async throws {
        try Task.checkCancellation()
        try storageLease?.check()
        try FileManager.default.createDirectory(at:temporaryDirectory,withIntermediateDirectories:true)
        let temporary=temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let bytes=try await fetcher.fetch(manifest.sourceURL,maximumBytes:manifest.byteCount)
        try Task.checkCancellation()
        try storageLease?.check()
        guard bytes.count==manifest.byteCount,TranslationDigest.sha256(bytes)==manifest.hash else { throw TagTranslationError.invalidManifest }
        try bytes.write(to:temporary,options:.atomic)
        let licenseURL=URL(string:"https://raw.githubusercontent.com/EhTagTranslation/Database/\(manifest.version)/LICENSE.md")!
        let licenseData=try await fetcher.fetch(licenseURL,maximumBytes:131072)
        try Task.checkCancellation()
        try storageLease?.check()
        guard let license=String(data:licenseData,encoding:.utf8) else { throw TagTranslationError.invalidManifest }
        let dataset=try TranslationImporter.parse(Data(contentsOf:temporary),manifest:manifest,license:license)
        try Task.checkCancellation()
        try await store.replace(with:dataset)
    }
}
