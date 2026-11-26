import Foundation

/// Two immutable checkpoints plus one atomic commit pointer. The v1 key is read-only.
/// No filesystem/SQLite transaction is needed: AccountID and all business paths stay unchanged.
public final class ProfileCredentialStore: CredentialStore, @unchecked Sendable {
    private struct ArchiveVersion: Decodable {let version:Int}
    private struct Pointer: Codable { let version: Int; let slot: Int; let id: UUID }
    private struct Checkpoint: Codable { let version: Int; let id: UUID; let payload: Data }
    private let legacy: any CredentialStore
    private let slots: [any CredentialStore]
    private let pointer: any CredentialStore
    private let lock=NSLock()
    public init(legacy: any CredentialStore, first: any CredentialStore, second: any CredentialStore, pointer: any CredentialStore) {
        self.legacy=legacy;slots=[first,second];self.pointer=pointer
    }
    private func active() throws -> Pointer? {
        guard let data=try pointer.load() else { return nil }
        guard data.count <= 4096 else { throw CredentialStoreError.invalidArchive }
        let value=try JSONDecoder().decode(Pointer.self,from:data)
        guard value.version==1,(0...1).contains(value.slot) else { throw CredentialStoreError.invalidArchive }
        return value
    }
    private func checkpoint(_ value: Pointer) throws -> Data {
        guard let data=try slots[value.slot].load(),data.count <= 8*1024*1024 else { throw CredentialStoreError.invalidArchive }
        let checkpoint=try JSONDecoder().decode(Checkpoint.self,from:data)
        guard checkpoint.version==1,checkpoint.id==value.id,checkpoint.payload.count <= 4*1024*1024 else { throw CredentialStoreError.invalidArchive }
        guard try JSONDecoder().decode(ArchiveVersion.self,from:checkpoint.payload).version==2 else{throw CredentialStoreError.invalidArchive}
        return checkpoint.payload
    }
    public func load() throws -> Data? {
        lock.lock();defer{lock.unlock()}
        if let active=try active() { return try checkpoint(active) }
        // Staged but uncommitted slot contents are never adopted on restart.
        return try legacy.load()
    }
    public func save(_ data: Data) throws {
        lock.lock();defer{lock.unlock()}
        guard data.count <= 4*1024*1024,try JSONDecoder().decode(ArchiveVersion.self,from:data).version==2 else { throw CredentialStoreError.invalidArchive }
        let oldPointerBytes=try pointer.load()
        let old=try active()
        if let old { _=try checkpoint(old) } // Don't overwrite a committed-but-corrupt state.
        let slot=old.map{1-$0.slot} ?? 0,id=UUID()
        let record=try JSONEncoder().encode(Checkpoint(version:1,id:id,payload:data))
        try slots[slot].save(record)
        let next=Pointer(version:1,slot:slot,id:id)
        guard try checkpoint(next)==data else { throw CredentialStoreError.invalidArchive }
        let commit=try JSONEncoder().encode(next)
        do {
            try pointer.save(commit)
            guard try pointer.load()==commit else { throw CredentialStoreError.invalidArchive }
        } catch {
            // An adapter may report an error after the atomic write. Readback can
            // prove this exact checkpoint committed; otherwise fail closed.
            let observed:Data?
            do{observed=try pointer.load()}catch{throw CredentialStoreError.commitUncertain}
            if observed==commit {
                guard (try? checkpoint(next))==data else{throw CredentialStoreError.commitUncertain};return
            }
            guard observed==oldPointerBytes else{throw CredentialStoreError.commitUncertain}
            throw error
        }
    }
}
#if canImport(Security)
extension KeychainCredentialStore {
    public static func profileArchive() -> ProfileCredentialStore {
        ProfileCredentialStore(legacy:Self(),first:Self(service:"org.erosnative.app.session.v2.slot0"),
            second:Self(service:"org.erosnative.app.session.v2.slot1"),pointer:Self(service:"org.erosnative.app.session.v2.active"))
    }
}
#endif
