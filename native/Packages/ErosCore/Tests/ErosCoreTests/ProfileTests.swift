import XCTest
import Foundation
@testable import ErosCore

final class ProfileTests: XCTestCase {
    func testSessionNetworkPermissionHasBackwardCompatibleDefaultAndRoundTripsOffline() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let old:[String:Any]=["scope":try JSONSerialization.jsonObject(with:JSONEncoder().encode(scope)),"authentication":"needsVerification"]
        let decoded=try JSONDecoder().decode(SessionState.self,from:JSONSerialization.data(withJSONObject:old));XCTAssertTrue(decoded.permitsNetwork)
        let offline=SessionState(scope:scope,authentication:.needsVerification,permitsNetwork:false)
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self,from:JSONEncoder().encode(offline)),offline)
    }
    func record(owner:AccountID = AccountID(UUID())) throws -> ProfileRecord {
        try ProfileRecord(id:ProfileID(UUID()),displayName:"Default",accountID:owner,selectedSite:.ex,credentialReference:CredentialReference(UUID()),createdAt:Date(timeIntervalSince1970:1))
    }
    func testProfileRoundTripRetainsOwnerAndReferenceAndRejectsInvalidDecodedName() throws {
        let profile=try record(),data=try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ProfileRecord.self,from:data),profile)
        let changed=try profile.selecting(.eh)
        XCTAssertEqual(changed.id,profile.id);XCTAssertEqual(changed.accountID,profile.accountID)
        XCTAssertEqual(changed.credentialReference,profile.credentialReference);XCTAssertEqual(changed.createdAt,profile.createdAt)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);object["displayName"]="\ninvalid"
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileRecord.self,from:JSONSerialization.data(withJSONObject:object)))
        XCTAssertThrowsError(try record(owner:ProfileIdentity.guestAccount))
        XCTAssertEqual(ProfileIdentity.guestAccount.value.uuidString,"00000000-0000-0000-0000-000000000018")
    }
    func testLegacyForumUsernameDoesNotBecomeTheProfileNickname() throws {
        let profile = try record()
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        saved["username"] = "legacy-login"
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ProfileRecord.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(legacy.username, "legacy-login")
        XCTAssertNil(legacy.profileName)

        saved["profileName"] = "合成昵称"
        let refreshed = try decoder.decode(ProfileRecord.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(refreshed.profileName, "合成昵称")
        XCTAssertEqual(refreshed.username, legacy.username)
        XCTAssertEqual(refreshed.id, legacy.id)
        XCTAssertEqual(refreshed.credentialReference, legacy.credentialReference)
        XCTAssertEqual(try refreshed.selecting(.eh).preferringEHDetails(false).profileName, "合成昵称")
    }

    func testSwitchRequiresOrderedQuiesceAndCommitOfBoundOwnerAtNewGeneration() throws {
        let source=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:5),target=try record()
        var transaction=ProfileSwitchTransaction(source:source,sourceProfileID:ProfileID(UUID()),target:target)
        XCTAssertThrowsError(try transaction.advance(to:.committed));XCTAssertFalse(transaction.mayStartTargetRequests)
        try transaction.advance(to:.newSchedulingPaused);try transaction.advance(to:.foregroundCancelled);try transaction.advance(to:.webContextCleared)
        XCTAssertThrowsError(try transaction.advance(to:.committed,committedScope:source))
        let committed=SessionScope(storage:StorageScope(accountID:target.accountID,site:.ex),generation:6)
        try transaction.advance(to:.committed,committedScope:committed);XCTAssertFalse(transaction.mayStartTargetRequests)
        try transaction.finish(verifiedOwner:target.accountID);XCTAssertTrue(transaction.mayStartTargetRequests)
        XCTAssertThrowsError(try transaction.advance(to:.prepared))
    }
    func testPreCommitFailureRollsBackButPostCommitFailureIsBoundOffline() throws {
        let source=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:8),target=try record()
        for advance in 0...3 {
            var transaction=ProfileSwitchTransaction(source:source,sourceProfileID:nil,target:target)
            for phase in [ProfileSwitchTransaction.Phase.newSchedulingPaused,.foregroundCancelled,.webContextCleared].prefix(advance){try transaction.advance(to:phase)}
            try transaction.fail();XCTAssertEqual(transaction.phase,.rolledBack);XCTAssertNil(transaction.committedScope)
        }
        var transaction=ProfileSwitchTransaction(source:source,sourceProfileID:nil,target:target)
        for phase in [ProfileSwitchTransaction.Phase.newSchedulingPaused,.foregroundCancelled,.webContextCleared]{try transaction.advance(to:phase)}
        let scope=SessionScope(storage:StorageScope(accountID:target.accountID,site:.ex),generation:9)
        try transaction.advance(to:.committed,committedScope:scope);try transaction.fail()
        XCTAssertEqual(transaction.phase,.offlineOnly);XCTAssertEqual(transaction.committedScope,scope)
    }
    func testDifferentVerifiedIdentityCannotActivateOrRebindTarget() throws {
        let target=try record();var transaction=ProfileSwitchTransaction(source:SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1),sourceProfileID:nil,target:target)
        for phase in [ProfileSwitchTransaction.Phase.newSchedulingPaused,.foregroundCancelled,.webContextCleared]{try transaction.advance(to:phase)}
        try transaction.advance(to:.committed,committedScope:SessionScope(storage:StorageScope(accountID:target.accountID,site:.ex),generation:2))
        XCTAssertThrowsError(try transaction.finish(verifiedOwner:AccountID(UUID())))
        XCTAssertEqual(transaction.phase,.offlineOnly);XCTAssertFalse(transaction.mayStartTargetRequests);XCTAssertEqual(transaction.target,target)
    }
}
