import Foundation
import ErosCore

public actor MyTagsCache {
    private struct Envelope:Codable { let schema:Int;let scope:StorageScope;let selection:String;let snapshot:MyTagsSnapshot }
    private let root:URL
    private let sessions:any SessionProvider
    public init(root:URL,sessions:any SessionProvider) { self.root=root.standardizedFileURL.resolvingSymlinksInPath();self.sessions=sessions }
    private func check(_ scope:SessionScope) async throws {
        try Task.checkCancellation();guard try await sessions.current().scope==scope else { throw AppError.staleSession };try Task.checkCancellation()
    }
    private func files(scope: SessionScope, setID: String?) throws -> AccountFileLocations {
        if let setID { try MyTagsIdentity.validate(setID, allowZero: true) }
        return try AccountFileLocations(root: root, owner: scope.storage.accountID,
            filename: (setID.map { "set-" + $0 } ?? "current") + ".json")
    }

    private func read(_ url: URL, owner: AccountID, site: Site?, setID: String?) throws -> MyTagsSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1024 * 1024 else {
            throw AppError.unsupportedContent
        }
        let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        try value.snapshot.page.validate()
        guard value.schema == (site == nil ? 2 : 1), value.scope.accountID == owner,
              site.map({ value.scope.site == $0 }) ?? true, value.snapshot.page.site == value.scope.site,
              value.selection == (setID ?? "current"),
              setID.map({ $0 == value.snapshot.page.selectedSetID }) ?? true,
              value.snapshot.fetchedAt.timeIntervalSince1970.isFinite else { throw AppError.parseMismatch }
        return value.snapshot
    }

    public func load(scope: SessionScope, setID: String?) async throws -> MyTagsSnapshot? {
        try await check(scope)
        let paths = try files(scope: scope, setID: setID)
        let owner = scope.storage.accountID
        if let current = try read(paths.current, owner: owner, site: nil, setID: setID) { return current }
        let legacy = paths.legacy.compactMap { try? read($0.url, owner: owner, site: $0.site, setID: setID) }
        return legacy.max { $0.fetchedAt < $1.fetchedAt }
    }

    public func save(_ snapshot:MyTagsSnapshot,scope:SessionScope,setID:String?) async throws {
        try await check(scope);try snapshot.page.validate()
        guard snapshot.page.site==scope.storage.site,setID.map({$0==snapshot.page.selectedSetID}) ?? true else { throw AppError.scopeMismatch }
        let selections:[String?]=setID==nil ? [nil,snapshot.page.selectedSetID] : [setID]
        for selection in selections {
            try await check(scope)
            let url = try files(scope: scope, setID: selection).current
            if let stored = try? read(url, owner: scope.storage.accountID, site: nil, setID: selection),
               stored.fetchedAt > snapshot.fetchedAt { continue }
            let bytes=try JSONEncoder().encode(Envelope(schema:2,scope:scope.storage,selection:selection ?? "current",snapshot:snapshot))
            guard bytes.count<=16*1024*1024 else { throw AppError.unsupportedContent }
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            #if os(iOS)
            var excluded=root;var attrs=URLResourceValues();attrs.isExcludedFromBackup=true;try excluded.setResourceValues(attrs)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.deletingLastPathComponent().path)
            #endif
            try bytes.write(to:url,options:.atomic)
        }
        try await check(scope)
    }
    func promoteIfCurrent(_ snapshot:MyTagsSnapshot,scope:SessionScope) async throws {
        let current=try? await load(scope:scope,setID:nil)
        if current?.page.selectedSetID==snapshot.page.selectedSetID { try await save(snapshot,scope:scope,setID:nil) }
    }

}
