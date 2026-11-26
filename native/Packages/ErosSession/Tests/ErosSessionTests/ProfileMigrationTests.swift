import Foundation
import XCTest
import ErosCore
@testable import ErosSession

private final class ProfileTestStore:CredentialStore,@unchecked Sendable {
    private let lock=NSLock()
    private var data:Data?
    private var failSave=false,failLoad=false,afterWrite=false,corruptWrite=false
    init(_ data:Data? = nil){self.data=data}
    func configure(save:Bool=false,load:Bool=false,afterWrite:Bool=false,corrupt:Bool=false){lock.lock();defer{lock.unlock()};failSave=save;failLoad=load;self.afterWrite=afterWrite;corruptWrite=corrupt}
    func load() throws->Data? {lock.lock();defer{lock.unlock()};if failLoad{throw CredentialStoreError.keychain(-1)};return data}
    func save(_ value:Data) throws {lock.lock();defer{lock.unlock()};if failSave{throw CredentialStoreError.keychain(-1)};data=corruptWrite ? Data("corrupt".utf8) : value;if afterWrite{throw CredentialStoreError.keychain(-1)}}
}
private struct LegacyProfileArchive:Codable {
    let version=1
    var generation:UInt64=7
    var site:Site = .ex
    var account:AccountID
    var accounts:[String:AccountID]
    var cookies:[SessionCookie]
}
final class ProfileMigrationTests:XCTestCase,@unchecked Sendable {
    private struct Harness {
        let legacy:ProfileTestStore,first:ProfileTestStore,second:ProfileTestStore,pointer:ProfileTestStore
        let owner:AccountID,original:Data
        var store:ProfileCredentialStore {ProfileCredentialStore(legacy:legacy,first:first,second:second,pointer:pointer)}
    }
    private func make(guest:Bool=false,expired:Bool=false) throws->Harness {
        let owner=guest ? SessionManager.guest : AccountID(UUID())
        let cookies=try [SessionCookie(name:"ipb_pass_hash",value:"SYNTHETIC",domain:"exhentai.org",expires:expired ? .distantPast : nil)]
        let raw=try JSONEncoder().encode(LegacyProfileArchive(account:owner,accounts:guest ? [:] : ["member":owner],cookies:cookies))
        return Harness(legacy:ProfileTestStore(raw),first:ProfileTestStore(),second:ProfileTestStore(),pointer:ProfileTestStore(),owner:owner,original:raw)
    }
    func testV1MigrationPreservesOwnerSiteCookiesAccountsAndDefaultProfileAcrossReopen() async throws {
        let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
        let snapshot=try await manager.snapshot(),profile=try XCTUnwrap(snapshot.activeProfile)
        XCTAssertEqual(snapshot.profileStorage,.current);XCTAssertEqual(snapshot.profileCount,1)
        XCTAssertEqual(snapshot.state.scope.storage.accountID,h.owner);XCTAssertEqual(snapshot.state.scope.storage.site,.ex)
        XCTAssertEqual(snapshot.state.scope.generation,8);XCTAssertEqual(snapshot.cookieCount,1);XCTAssertEqual(snapshot.status,.needsVerification)
        XCTAssertEqual(profile.displayName,"默认账号");XCTAssertEqual(try h.legacy.load(),h.original)
        let restored=SessionManager(store:h.store);try await restored.restore()
        let after=try await restored.snapshot();XCTAssertEqual(after.activeProfile,profile);XCTAssertEqual(after.state.scope.generation,9)
        let owners=try await restored.knownDataOwners();XCTAssertEqual(Set(owners),Set([h.owner,SessionManager.guest]))
        let saved=try JSONDecoder().decode(SessionArchive.self,from:XCTUnwrap(h.store.load()))
        XCTAssertEqual(saved.accounts,["member":h.owner]);XCTAssertEqual(saved.version,2)
        XCTAssertEqual(saved.credentials[profile.credentialReference.value.uuidString],saved.cookies)
    }
    func testGuestUnverifiedCookieMigrationKeepsGuestIDUntilServerProof() async throws {
        let h=try make(guest:true),manager=SessionManager(store:h.store);try await manager.restore()
        let initial=try await manager.snapshot();XCTAssertNil(initial.activeProfile);XCTAssertEqual(initial.state.scope.storage.accountID,SessionManager.guest)
        try await manager.verify(using:Verifier(result:.authenticated(subject:"new")))
        let after=try await manager.snapshot();XCTAssertNotEqual(after.state.scope.storage.accountID,SessionManager.guest);XCTAssertEqual(after.profileCount,1)
    }
    func testExpiredCookieMigrationRetainsDataOwnerAndDoesNotInventGuest() async throws {
        let h=try make(expired:true),manager=SessionManager(store:h.store);try await manager.restore()
        let value=try await manager.snapshot();XCTAssertEqual(value.state.scope.storage.accountID,h.owner);XCTAssertEqual(value.status,.expired)
        XCTAssertEqual(value.cookieCount,0);XCTAssertEqual(value.activeProfile?.accountID,h.owner)
    }
    func testStageFailureFallsBackToExactV1AndExplicitRestoreCanRetryMigration() async throws {
        let h=try make();h.first.configure(save:true)
        let manager=SessionManager(store:h.store);try await manager.restore()
        let value=try await manager.snapshot();XCTAssertEqual(value.profileStorage,.legacyFallback);XCTAssertEqual(value.state.scope.storage.accountID,h.owner)
        XCTAssertEqual(try h.store.load(),h.original);XCTAssertNil(try h.pointer.load())
        h.first.configure();try await manager.restore()
        let next=try await manager.snapshot();XCTAssertEqual(next.profileStorage,.current);XCTAssertEqual(next.activeProfile?.id,value.activeProfile?.id)
    }
    func testPointerFailureNeverAdoptsUncommittedCheckpointOnReopen() async throws {
        let h=try make();h.pointer.configure(save:true)
        let manager=SessionManager(store:h.store);try await manager.restore()
        XCTAssertNotNil(try h.first.load());XCTAssertNil(try h.pointer.load());XCTAssertEqual(try h.store.load(),h.original)
        let reopened=SessionManager(store:h.store);try await reopened.restore()
        let value=try await reopened.snapshot();XCTAssertEqual(value.profileStorage,.legacyFallback);XCTAssertEqual(value.state.scope.storage.accountID,h.owner)
        h.pointer.configure();try await reopened.restore()
        let after=try await reopened.snapshot();XCTAssertEqual(after.profileStorage,.current)
    }
    func testStagedCorruptionDoesNotCommitPointerOrDamageLegacy() async throws {
        let h=try make();h.first.configure(corrupt:true)
        let manager=SessionManager(store:h.store);try await manager.restore()
        let value=try await manager.snapshot();XCTAssertEqual(value.profileStorage,.legacyFallback)
        XCTAssertNil(try h.pointer.load());XCTAssertEqual(try h.legacy.load(),h.original)
    }
    func testErrorAfterAtomicPointerWriteIsResolvedByExactReadback() async throws {
        let h=try make();h.pointer.configure(afterWrite:true)
        let manager=SessionManager(store:h.store);try await manager.restore()
        let value=try await manager.snapshot();XCTAssertEqual(value.profileStorage,.current)
        let restored=SessionManager(store:h.store);try await restored.restore()
        let after=try await restored.snapshot();XCTAssertEqual(after.activeProfile?.id,value.activeProfile?.id)
    }
    func testFailedNextCheckpointOrPointerLeavesPreviouslyCommittedProfileUntouched() async throws {
        for failPointer in [false,true] {
            let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
            let before=try await manager.snapshot(),committed=try h.store.load()
            if failPointer{h.pointer.configure(save:true)}else{h.second.configure(save:true)}
            do{try await manager.select(site:.eh);XCTFail()}catch{}
            let after=try await manager.snapshot();XCTAssertEqual(after.state,before.state);XCTAssertEqual(after.activeProfile,before.activeProfile)
            XCTAssertEqual(try h.store.load(),committed);XCTAssertEqual(try h.legacy.load(),h.original)
        }
    }
    func testCommittedPointerCorruptionOrLockedKeyNeverFallsBackToStaleV1() async throws {
        for corrupt in [false,true] {
            let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
            if corrupt{try h.pointer.save(Data("bad".utf8))}else{h.pointer.configure(load:true)}
            let restored=SessionManager(store:h.store)
            do{try await restored.restore();XCTFail("stale v1 fallback")}catch{}
            do{_=try await restored.current();XCTFail("runtime credentials exposed")}catch{}
            XCTAssertEqual(try h.legacy.load(),h.original)
        }
    }
    func testFutureArchiveOrAmbiguousIdentityIsRejectedWithoutOverwrite() async throws {
        for future in [false,true] {
            let h=try make();var object=try XCTUnwrap(JSONSerialization.jsonObject(with:h.original) as? [String:Any])
            if future{object["version"]=99}else{object["accounts"]=["member":try JSONSerialization.jsonObject(with:JSONEncoder().encode(h.owner)),"other":try JSONSerialization.jsonObject(with:JSONEncoder().encode(h.owner))]}
            let raw=try JSONSerialization.data(withJSONObject:object),store=ProfileTestStore(raw),manager=SessionManager(store:store)
            do{try await manager.restore();XCTFail()}catch{}
            XCTAssertEqual(try store.load(),raw)
        }
    }
    func testReturningIdentityReusesAccountProfileAndCredentialReferenceWithoutDuplicate() async throws {
        let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
        let initial=try await manager.snapshot();let profile=try XCTUnwrap(initial.activeProfile)
        let cookies=try [SessionCookie(name:"ipb_pass_hash",value:"RENEWED_SYNTHETIC",domain:"exhentai.org")]
        for subject in ["member","second","member"] {
            let attempt=try await manager.beginLogin()
            _=try await manager.performLogin(cookies:cookies,site:.ex,attempt:attempt,verifier:Verifier(result:.authenticated(subject:subject)))
        }
        let after=try await manager.snapshot(),records=try await manager.profileRecords()
        XCTAssertEqual(after.activeProfile?.id,profile.id);XCTAssertEqual(after.activeProfile?.credentialReference,profile.credentialReference)
        XCTAssertEqual(after.state.scope.storage.accountID,h.owner);XCTAssertEqual(after.profileCount,2)
        XCTAssertEqual(records.filter{$0.accountID==h.owner}.count,1)
    }
    func testBoundProfileVerificationIdentityMismatchRejectsAndInvalidatesOldScope() async throws {
        let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
        let before=try await manager.snapshot()
        do{try await manager.verify(using:Verifier(result:.authenticated(subject:"different")));XCTFail()}catch ProfileError.identityMismatch{}catch{XCTFail()}
        let after=try await manager.snapshot();XCTAssertEqual(after.status,.rejected);XCTAssertEqual(after.activeProfile,before.activeProfile)
        XCTAssertEqual(after.state.scope.storage.accountID,h.owner);XCTAssertGreaterThan(after.state.scope.generation,before.state.scope.generation)
        let records=try await manager.profileRecords();XCTAssertEqual(records.count,1)
        do{_=try await manager.webCookies(scope:before.state.scope);XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        let header=try await manager.cookieHeader(url:URL(string:"https://exhentai.org/")!,scope:after.state.scope);XCTAssertNil(header)
    }
    func testLogoutRevokesActiveJarButPreservesProfileMappingAndReturningOwner() async throws {
        let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
        let original=try await manager.snapshot();try await manager.logout()
        let guest=try await manager.snapshot();XCTAssertNil(guest.activeProfile);XCTAssertEqual(guest.state.scope.storage.accountID,SessionManager.guest)
        let archive=try JSONDecoder().decode(SessionArchive.self,from:XCTUnwrap(h.store.load()))
        XCTAssertEqual(archive.profiles.count,1);XCTAssertEqual(archive.accounts,["member":h.owner]);XCTAssertTrue(archive.credentials.values.allSatisfy(\.isEmpty))
        let attempt=try await manager.beginLogin()
        _=try await manager.performLogin(cookies:[SessionCookie(name:"ipb_pass_hash",value:"RENEWED",domain:"exhentai.org")],site:.ex,attempt:attempt,verifier:Verifier(result:.authenticated(subject:"member")))
        let after=try await manager.snapshot();XCTAssertEqual(after.activeProfile?.id,original.activeProfile?.id);XCTAssertEqual(after.state.scope.storage.accountID,h.owner)
    }
    func testExpiredBoundProfileRemainsExpiredWhenChangingSite() async throws {
        let h=try make(expired:true),manager=SessionManager(store:h.store);try await manager.restore()
        let before=try await manager.snapshot();try await manager.select(site:.eh)
        let after=try await manager.snapshot()
        XCTAssertEqual(after.status,.expired);XCTAssertEqual(after.state.scope.storage.accountID,h.owner)
        XCTAssertEqual(after.activeProfile?.id,before.activeProfile?.id);XCTAssertEqual(after.activeProfile?.selectedSite,.eh)
        XCTAssertNotEqual(after.state.authentication,.guest)
    }
    func testFallbackMigrationCanRecoverAfterVerificationSaveFailedWithoutReloginOrOwnerLoss() async throws {
        let h=try make();h.first.configure(save:true)
        let manager=SessionManager(store:h.store);try await manager.restore()
        let before=try await manager.snapshot()
        do{try await manager.verify(using:Verifier(result:.authenticated(subject:"member")));XCTFail()}catch{}
        do{_=try await manager.current();XCTFail()}catch{}
        h.first.configure();try await manager.restore()
        let after=try await manager.snapshot()
        XCTAssertEqual(after.profileStorage,.current);XCTAssertEqual(after.status,.needsVerification)
        XCTAssertEqual(after.activeProfile?.id,before.activeProfile?.id);XCTAssertEqual(after.state.scope.storage.accountID,h.owner)
        try await manager.verify(using:Verifier(result:.authenticated(subject:"member")))
        let ready=try await manager.snapshot();XCTAssertEqual(ready.status,.authenticated)
    }
    func testPendingLoginRemainsBoundToOriginalProfileAndCancelledCandidateCannotReplaceIt() async throws {
        let h=try make(),manager=SessionManager(store:h.store);try await manager.restore()
        let initial=try await manager.snapshot(),attempt=try await manager.beginLogin(),verifier=DelayedVerifier()
        let task=Task{try await manager.performLogin(cookies:[SessionCookie(name:"ipb_pass_hash",value:"CANDIDATE",domain:"exhentai.org")],site:.eh,attempt:attempt,verifier:verifier)}
        while !(await verifier.started){await Task.yield()}
        try await manager.select(site:.eh);await verifier.finish()
        do{_=try await task.value;XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        let after=try await manager.snapshot();XCTAssertEqual(after.activeProfile?.id,initial.activeProfile?.id);XCTAssertEqual(after.profileCount,1)
    }
}
