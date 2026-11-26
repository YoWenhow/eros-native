import XCTest
import Foundation
import ErosCore
@testable import ErosSession

private final class F17Store:CredentialStore,@unchecked Sendable {
    private let lock=NSLock()
    private var data:Data?
    private var failSave=false,failLoad=false,failReadsAfterSave=false
    func configure(save:Bool=false,load:Bool=false,readsAfterSave:Bool=false){lock.lock();defer{lock.unlock()};failSave=save;failLoad=load;failReadsAfterSave=readsAfterSave}
    func load() throws->Data?{lock.lock();defer{lock.unlock()};if failLoad{throw CredentialStoreError.keychain(-1)};return data}
    func save(_ value:Data) throws{lock.lock();defer{lock.unlock()};if failSave{throw CredentialStoreError.keychain(-1)};data=value;if failReadsAfterSave{failLoad=true}}
}
private final class F17Cancellation:@unchecked Sendable {
    private let lock=NSLock();private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    func cancelled()->Bool{lock.lock();defer{lock.unlock()};return value}
}
private actor F17Effects:ProfileSwitchEffects {
    private(set) var calls:[String]=[]
    private(set) var resumes:[SessionSnapshot]=[]
    var held=false
    private var continuation:CheckedContinuation<Void,Never>?
    let failure:String?
    let check:@Sendable () async throws ->Void
    init(failure:String?=nil,check:@escaping @Sendable () async throws ->Void = {}){self.failure=failure;self.check=check}
    func hold(){held=true}
    func waiting()->Bool{continuation != nil}
    func release(){held=false;continuation?.resume();continuation=nil}
    func pauseNewRequests() throws{calls.append("pause");if failure=="pause"{throw AppError.storageFull}}
    func clearWebContexts() async throws {
        calls.append("clear");if held{await withCheckedContinuation{continuation=$0}}
        if failure=="clear"{throw AppError.storageFull};try await check()
    }
    func resume(snapshot:SessionSnapshot){calls.append("resume");resumes.append(snapshot)}
}
private actor F17HeldVerifier:SessionVerifier {
    let subject:String
    private var continuation:CheckedContinuation<Void,Never>?
    init(_ subject:String){self.subject=subject}
    func waiting()->Bool{continuation != nil}
    func release(){continuation?.resume();continuation=nil}
    func verify(scope:SessionScope) async ->SessionVerification{await withCheckedContinuation{continuation=$0};return .authenticated(subject:subject)}
}
private struct F17FailureVerifier:SessionVerifier {
    func verify(scope:SessionScope) throws ->SessionVerification{throw AppError.transport(code:-1009)}
}
private struct F17SaveFailureVerifier:SessionVerifier {
    let store:F17Store
    let subject:String
    func verify(scope:SessionScope)->SessionVerification{store.configure(save:true);return .authenticated(subject:subject)}
}
final class ProfileSwitchTests:XCTestCase,@unchecked Sendable {
    private struct Harness {
        let manager:SessionManager
        let store:F17Store
        let a:ProfileRecord
        let b:ProfileRecord
    }
    private func cookies(_ label:String) throws->[SessionCookie]{[
        try SessionCookie(name:"ipb_member_id",value:"12345",domain:"e-hentai.org"),
        try SessionCookie(name:"ipb_pass_hash",value:"SYNTHETIC_"+label,domain:"e-hentai.org")
    ]}
    private func login(_ manager:SessionManager,_ label:String) async throws {
        let attempt=try await manager.beginLogin()
        _=try await manager.performLogin(cookies:cookies(label),site:.eh,attempt:attempt,verifier:Verifier(result:.authenticated(subject:label)))
    }
    private func make(store:F17Store = F17Store(),manager:SessionManager?=nil) async throws->Harness {
        let manager=manager ?? SessionManager(store:store);try await manager.restore();try await login(manager,"A");try await login(manager,"B")
        let records=try await manager.profileRecords();return Harness(manager:manager,store:store,a:records[0],b:records[1])
    }
    private func stage(_ manager:SessionManager,subject:String,intent:ProfileLoginIntent = .add) async throws->VerifiedProfileCandidate {
        let attempt=try await manager.beginProfileLogin(intent:intent)
        return try await manager.stageProfileLogin(cookies:cookies(subject),site:.eh,attempt:attempt,verifier:Verifier(result:.authenticated(subject:subject)))
    }
    func testSingleAccountSignInRequiresLogoutForAnotherIdentityAndReusesKnownOwner() async throws {
        let h = try await make()
        let switcher = ProfileSwitchCoordinator(manager: h.manager, effects: F17Effects())
        do {
            _ = try await stage(h.manager, subject: "A", intent: .signIn)
            XCTFail("Active identity was replaced")
        } catch ProfileError.identityMismatch {}
        let before = try await h.manager.snapshot()
        XCTAssertEqual(before.activeProfile?.id, h.b.id)

        let loggedOut = try await switcher.activate(.guest(clearCurrentCredentials: true))
        XCTAssertNil(loggedOut.snapshot.activeProfile)
        let candidate = try await stage(h.manager, subject: "B", intent: .signIn)
        let returned = try await switcher.activate(.candidate(candidate))
        XCTAssertEqual(returned.snapshot.activeProfile?.id, h.b.id)
        XCTAssertEqual(returned.snapshot.state.scope.storage.accountID, h.b.accountID)
        XCTAssertEqual(returned.outcome, .online)
    }

    func testRapidSequentialAtoBtoAUsesOwnJarAndMonotonicScopes() async throws {
        let h=try await make(),effects=F17Effects(),switcher=ProfileSwitchCoordinator(manager:h.manager,effects:effects)
        var previous=try await h.manager.current().scope
        for (record,subject) in [(h.a,"A"),(h.b,"B"),(h.a,"A")] {
            let result=try await switcher.perform(.stored(record.id),mode:.online,verifier:Verifier(result:.authenticated(subject:subject)))
            XCTAssertEqual(result.outcome,.online);XCTAssertEqual(result.snapshot.activeProfile?.id,record.id)
            XCTAssertEqual(result.snapshot.state.scope.storage.accountID,record.accountID);XCTAssertGreaterThan(result.snapshot.state.scope.generation,previous.generation)
            let header=try await h.manager.cookieHeader(url:URL(string:"https://e-hentai.org/")!,scope:result.snapshot.state.scope)
            XCTAssertEqual(header,"ipb_member_id=12345; ipb_pass_hash=SYNTHETIC_"+subject)
            do{_=try await h.manager.webCookies(scope:previous);XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
            previous=result.snapshot.state.scope
        }
        let calls=await effects.calls;XCTAssertEqual(calls,["pause","clear","resume","pause","clear","resume","pause","clear","resume"])
    }
    func testPreparationRevokesOldCallbacksAndCancelsBeforeWebContextClear() async throws {
        let h=try await make(),source=try await h.manager.snapshot(),cancelled=F17Cancellation()
        try await h.manager.register(id:UUID(),scope:source.state.scope){cancelled.cancel()}
        let effects=F17Effects(check:{
            XCTAssertTrue(cancelled.cancelled())
            let preparing=try await h.manager.snapshot();XCTAssertTrue(preparing.profileSwitching);XCTAssertFalse(preparing.state.permitsNetwork)
            do{try await h.manager.merge([],scope:source.state.scope);XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        })
        let result=try await ProfileSwitchCoordinator(manager:h.manager,effects:effects).perform(.stored(h.a.id),mode:.online,verifier:Verifier(result:.authenticated(subject:"A")))
        XCTAssertEqual(result.outcome,.online);XCTAssertFalse(result.snapshot.profileSwitching)
    }
    func testPrecommitPauseOrWebFailurePreservesCommittedOwnerButRevokesOldGeneration() async throws {
        for failure in ["pause","clear"] {
            let h=try await make(),before=try await h.manager.snapshot(),stored=try h.store.load(),effects=F17Effects(failure:failure)
            do{_=try await ProfileSwitchCoordinator(manager:h.manager,effects:effects).perform(.stored(h.a.id),mode:.online,verifier:Verifier(result:.authenticated(subject:"A")));XCTFail()}catch AppError.storageFull{}catch{XCTFail()}
            let after=try await h.manager.snapshot();XCTAssertEqual(after.activeProfile?.id,h.b.id);XCTAssertEqual(after.status,.authenticated)
            XCTAssertGreaterThan(after.state.scope.generation,before.state.scope.generation);XCTAssertFalse(after.profileSwitching);XCTAssertEqual(try h.store.load(),stored)
            let resumes=await effects.resumes;XCTAssertEqual(resumes.count,1);XCTAssertEqual(resumes.first?.activeProfile?.id,h.b.id)
        }
    }
    func testCommitFailureRetainsSourceAndNeverMarksTargetActive() async throws {
        let h=try await make(),before=try await h.manager.snapshot(),stored=try h.store.load(),effects=F17Effects(check:{h.store.configure(save:true)})
        do{_=try await ProfileSwitchCoordinator(manager:h.manager,effects:effects).perform(.stored(h.a.id),mode:.online,verifier:nil);XCTFail()}catch{}
        let after=try await h.manager.snapshot();XCTAssertEqual(after.activeProfile,before.activeProfile);XCTAssertFalse(after.profileSwitching);XCTAssertEqual(try h.store.load(),stored)
        h.store.configure()
    }
    func testUnknownPointerCommitFailsClosedThenExplicitReloadUsesActualCommittedOwnerLocally() async throws {
        let legacy=F17Store(),first=F17Store(),second=F17Store(),pointer=F17Store()
        let vault=ProfileCredentialStore(legacy:legacy,first:first,second:second,pointer:pointer)
        let manager=SessionManager(store:vault),h=try await make(manager:manager)
        pointer.configure(readsAfterSave:true)
        do{_=try await ProfileSwitchCoordinator(manager:manager,effects:F17Effects()).perform(.stored(h.a.id),mode:.online,verifier:nil);XCTFail()}catch CredentialStoreError.commitUncertain{}catch{XCTFail()}
        do{_=try await manager.current();XCTFail("uncertain identity usable")}catch{}
        pointer.configure();try await manager.restore()
        let recovered=try await manager.snapshot();XCTAssertEqual(recovered.activeProfile?.id,h.a.id)
        XCTAssertTrue(recovered.localOnly);XCTAssertFalse(recovered.state.permitsNetwork);XCTAssertEqual(recovered.status,.needsVerification)
    }
    func testNetworkAndRejectedVerificationStayOnTargetBoundLocalOwner() async throws {
        for result in [SessionVerification.expired,.rejected,.unknown] {
            let h=try await make(),effects=F17Effects()
            let value=try await ProfileSwitchCoordinator(manager:h.manager,effects:effects).perform(.stored(h.a.id),mode:.online,verifier:Verifier(result:result))
            XCTAssertEqual(value.snapshot.activeProfile?.id,h.a.id);XCTAssertTrue(value.snapshot.localOnly);XCTAssertFalse(value.snapshot.state.permitsNetwork);XCTAssertEqual(value.outcome,.localOnly)
        }
        let h=try await make()
        let value=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.stored(h.a.id),mode:.online,verifier:F17FailureVerifier())
        XCTAssertEqual(value.snapshot.activeProfile?.id,h.a.id);XCTAssertEqual(value.outcome,.localOnly)
    }
    func testDifferentTargetIdentityDoesNotCreateOrRebindAccount() async throws {
        let h=try await make()
        let result=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.stored(h.a.id),mode:.online,verifier:Verifier(result:.authenticated(subject:"unexpected")))
        XCTAssertEqual(result.outcome,.identityMismatch);XCTAssertEqual(result.snapshot.state.scope.storage.accountID,h.a.accountID)
        XCTAssertTrue(result.snapshot.localOnly);let records=try await h.manager.profileRecords();XCTAssertEqual(records.count,2)
    }
    func testPostcommitVerificationSaveFailureReturnsBoundLocalStateAndCanRetry() async throws {
        let h=try await make()
        let result=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.stored(h.a.id),mode:.online,verifier:F17SaveFailureVerifier(store:h.store,subject:"A"))
        XCTAssertEqual(result.outcome,.localOnly);XCTAssertEqual(result.snapshot.activeProfile?.id,h.a.id);XCTAssertTrue(result.snapshot.localOnly)
        h.store.configure();try await h.manager.verify(using:Verifier(result:.authenticated(subject:"A")))
        let after=try await h.manager.snapshot();XCTAssertEqual(after.status,.authenticated);XCTAssertFalse(after.localOnly)
    }
    func testExplicitLocalOnlyDoesNotVerifySendCookiesOrRegisterAndSurvivesReopen() async throws {
        let h=try await make()
        let value=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.stored(h.a.id),mode:.localOnly,verifier:Verifier(result:.authenticated(subject:"WRONG_NOT_CALLED")))
        XCTAssertEqual(value.outcome,.localOnly);XCTAssertTrue(value.snapshot.localOnly)
        let header=try await h.manager.cookieHeader(url:URL(string:"https://e-hentai.org/")!,scope:value.snapshot.state.scope);XCTAssertNil(header)
        let web=try await h.manager.webCookies(scope:value.snapshot.state.scope);XCTAssertTrue(web.isEmpty)
        do{try await h.manager.register(id:UUID(),scope:value.snapshot.state.scope){};XCTFail()}catch AppError.authenticationRequired{}catch{XCTFail()}
        let reopened=SessionManager(store:h.store);try await reopened.restore();let cold=try await reopened.snapshot()
        XCTAssertEqual(cold.activeProfile?.id,h.a.id);XCTAssertTrue(cold.localOnly);XCTAssertFalse(cold.state.permitsNetwork)
    }
    func testGuestSwitchPreservesSavedJarAndReturningOwnerWhileLogoutRevokesCurrentOnly() async throws {
        let h=try await make(),switcher=ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects())
        let guest=try await switcher.perform(.guest(clearCurrentCredentials:false),mode:.online,verifier:nil)
        XCTAssertEqual(guest.outcome,.guest);XCTAssertEqual(guest.snapshot.state.scope.storage.accountID,SessionManager.guest)
        let records=try await h.manager.profileSummaries();XCTAssertTrue(records.allSatisfy(\.hasSavedCookies))
        _=try await switcher.perform(.stored(h.b.id),mode:.online,verifier:Verifier(result:.authenticated(subject:"B")))
        _=try await switcher.perform(.guest(clearCurrentCredentials:true),mode:.online,verifier:nil)
        let after=try await h.manager.profileSummaries();XCTAssertTrue(try XCTUnwrap(after.first{$0.id==h.a.id}).hasSavedCookies)
        XCTAssertFalse(try XCTUnwrap(after.first{$0.id==h.b.id}).hasSavedCookies)
    }
    func testRenamePreservesBusinessOwnerReferenceAndSiteAndFailedSaveKeepsName() async throws {
        let h=try await make(),before=try await h.manager.snapshot()
        try await h.manager.renameProfile(h.b.id,name:"  Local Name  ")
        let after=try await h.manager.snapshot();XCTAssertEqual(after.activeProfile?.displayName,"Local Name")
        XCTAssertEqual(after.activeProfile?.id,before.activeProfile?.id);XCTAssertEqual(after.activeProfile?.credentialReference,before.activeProfile?.credentialReference)
        XCTAssertEqual(after.state.scope,before.state.scope)
        do{try await h.manager.renameProfile(h.b.id,name:"\n");XCTFail()}catch{}
        h.store.configure(save:true);do{try await h.manager.renameProfile(h.b.id,name:"Not Saved");XCTFail()}catch{}
        let failed=try await h.manager.snapshot();XCTAssertEqual(failed.activeProfile?.displayName,"Local Name");h.store.configure()
    }
    func testInactiveDeleteKeepsAccountMappingAndReaddReusesOwnerWithNewProfile() async throws {
        let h=try await make();try await h.manager.removeInactiveProfile(h.a.id)
        let owner=try await h.manager.snapshot();XCTAssertEqual(owner.activeProfile?.id,h.b.id)
        let candidate=try await stage(h.manager,subject:"A");XCTAssertEqual(candidate.accountID,h.a.accountID);XCTAssertNil(candidate.existingProfileID)
        let value=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.candidate(candidate),mode:.online,verifier:nil)
        XCTAssertEqual(value.snapshot.state.scope.storage.accountID,h.a.accountID);XCTAssertNotEqual(value.snapshot.activeProfile?.id,h.a.id)
    }
    func testActiveDeleteRequiresExplicitGuestTransitionAndKeepsOtherProfile() async throws {
        let h=try await make()
        do{try await h.manager.removeInactiveProfile(h.b.id);XCTFail()}catch ProfileError.activeProfileRequiresGuest{}catch{XCTFail()}
        let value=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.removeActive(h.b.id),mode:.online,verifier:nil)
        XCTAssertEqual(value.snapshot.state.scope.storage.accountID,SessionManager.guest)
        let records=try await h.manager.profileRecords();XCTAssertEqual(records.map(\.id),[h.a.id])
        let candidate=try await stage(h.manager,subject:"B");XCTAssertEqual(candidate.accountID,h.b.accountID)
    }
    func testVerifiedCandidateStaysMemoryOnlyUntilSwitchAndProjectionContainsNoSecrets() async throws {
        let h=try await make(),before=try await h.manager.snapshot(),saved=try h.store.load()
        let candidate=try await stage(h.manager,subject:"C")
        let staged=try await h.manager.snapshot();XCTAssertEqual(staged.state,before.state);XCTAssertEqual(staged.profileCount,2);XCTAssertEqual(try h.store.load(),saved)
        XCTAssertFalse(String(reflecting:candidate).contains("SYNTHETIC"))
        let final=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.candidate(candidate),mode:.online,verifier:F17FailureVerifier())
        XCTAssertEqual(final.outcome,.online);XCTAssertEqual(final.snapshot.state.scope.storage.accountID,candidate.accountID);XCTAssertEqual(final.snapshot.profileCount,3)
    }
    func testDuplicateAddGuidesExistingProfileWithoutReplacingCookiesOrCreatingRecord() async throws {
        let h=try await make(),before=try await h.manager.snapshot(),saved=try h.store.load()
        do{_=try await stage(h.manager,subject:"A");XCTFail()}catch ProfileError.existingProfile(let id){XCTAssertEqual(id,h.a.id)}catch{XCTFail()}
        let after=try await h.manager.snapshot();XCTAssertEqual(after.state,before.state);XCTAssertEqual(after.profileCount,2);XCTAssertEqual(try h.store.load(),saved)
    }
    func testReauthenticationRejectsDifferentSubjectAndCorrectSubjectReusesProfileReference() async throws {
        let h=try await make(),before=try await h.manager.snapshot()
        do{_=try await stage(h.manager,subject:"B",intent:.reauthenticate(h.a.id));XCTFail()}catch ProfileError.identityMismatch{}catch{XCTFail()}
        let unchanged=try await h.manager.snapshot();XCTAssertEqual(unchanged.state,before.state)
        let candidate=try await stage(h.manager,subject:"A",intent:.reauthenticate(h.a.id))
        let value=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.candidate(candidate),mode:.online,verifier:nil)
        XCTAssertEqual(value.snapshot.activeProfile?.id,h.a.id);XCTAssertEqual(value.snapshot.activeProfile?.credentialReference,h.a.credentialReference)
    }
    func testCancelAddBeforeAndAfterVerificationPreservesOriginalStateAndPageScope() async throws {
        let h=try await make(),before=try await h.manager.snapshot(),verifier=F17HeldVerifier("C")
        let attempt=try await h.manager.beginProfileLogin(intent:.add)
        let work=Task{try await h.manager.stageProfileLogin(cookies:cookies("C"),site:.eh,attempt:attempt,verifier:verifier)}
        while !(await verifier.waiting()){await Task.yield()};await h.manager.cancelLogin(attempt);await verifier.release()
        do{_=try await work.value;XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        let after=try await h.manager.snapshot();XCTAssertEqual(after.state,before.state)
        let next=try await h.manager.beginProfileLogin(intent:.add)
        let candidate=try await h.manager.stageProfileLogin(cookies:cookies("C"),site:.eh,attempt:next,verifier:Verifier(result:.authenticated(subject:"C")))
        await h.manager.cancelLogin(next)
        do{_=try await ProfileSwitchCoordinator(manager:h.manager,effects:F17Effects()).perform(.candidate(candidate),mode:.online,verifier:nil);XCTFail()}catch AppError.staleSession{}catch{XCTFail()}
        let final=try await h.manager.snapshot();XCTAssertEqual(final.state,before.state)
    }
    func testConcurrentSwitchRejectedAndPrecommitCancellationResumesOriginalOwner() async throws {
        let h=try await make(),effects=F17Effects(),switcher=ProfileSwitchCoordinator(manager:h.manager,effects:effects);await effects.hold()
        let work=Task{try await switcher.perform(.stored(h.a.id),mode:.online,verifier:Verifier(result:.authenticated(subject:"A")))}
        while !(await effects.waiting()){await Task.yield()}
        do{_=try await switcher.perform(.stored(h.b.id),mode:.online,verifier:nil);XCTFail()}catch ProfileError.busy{}catch{XCTFail()}
        do{try await h.manager.renameProfile(h.b.id,name:"Blocked");XCTFail()}catch ProfileError.busy{}catch{XCTFail()}
        work.cancel();await effects.release()
        do{_=try await work.value;XCTFail()}catch is CancellationError{}catch{XCTFail()}
        let after=try await h.manager.snapshot();XCTAssertEqual(after.activeProfile?.id,h.b.id);XCTAssertFalse(after.profileSwitching)
    }
    func testCancellationAfterCommitNeverRollsBackToSourceOrResumesOnline() async throws {
        let h=try await make(),effects=F17Effects(),verifier=F17HeldVerifier("A"),switcher=ProfileSwitchCoordinator(manager:h.manager,effects:effects)
        let work=Task{try await switcher.perform(.stored(h.a.id),mode:.online,verifier:verifier)}
        while !(await verifier.waiting()){await Task.yield()};work.cancel();await verifier.release()
        let result=try await work.value;XCTAssertEqual(result.snapshot.activeProfile?.id,h.a.id);XCTAssertEqual(result.outcome,.localOnly)
        let resumed=await effects.resumes;XCTAssertEqual(resumed.count,1);XCTAssertEqual(resumed[0].activeProfile?.id,h.a.id)
    }
    func testSiteEvidenceKeepsUnknownSeparateAndNeverInfersEXFromEHProof() async throws {
        let h=try await make();try await h.manager.verify(using:Verifier(result:.authenticated(subject:"B")))
        var records=try await h.manager.profileSummaries();XCTAssertEqual(records.first{$0.id==h.b.id}?.lastAccess?.eh,.verified);XCTAssertEqual(records.first{$0.id==h.b.id}?.lastAccess?.ex,.unknown)
        try await h.manager.select(site:.ex);try await h.manager.verify(using:Verifier(result:.ehAuthenticatedEXDenied(subject:"B")))
        records=try await h.manager.profileSummaries();XCTAssertEqual(records.first{$0.id==h.b.id}?.lastAccess?.ex,.denied)
    }
}
