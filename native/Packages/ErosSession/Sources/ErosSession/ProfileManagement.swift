import Foundation
import ErosCore

public enum ProfileSiteAccess:String,Codable,Sendable {case verified,denied,unknown}
public struct ProfileAccessEvidence:Codable,Equatable,Sendable {
    public let eh:ProfileSiteAccess
    public let ex:ProfileSiteAccess
    public let checkedAt:Date
}
public struct ProfileSummary:Sendable,Identifiable {
    public var id:ProfileID {record.id}
    public let record:ProfileRecord
    public let isCurrent:Bool
    public let hasSavedCookies:Bool
    public let lastAccess:ProfileAccessEvidence?
}
public enum ProfileLoginIntent: Equatable, Sendable { case signIn, add, reauthenticate(ProfileID) }
public struct VerifiedProfileCandidate:Equatable,Sendable {
    public let id:UUID
    public let accountID:AccountID
    public let existingProfileID:ProfileID?
}
public enum ProfileSwitchTarget:Sendable {
    case stored(ProfileID)
    case guest(clearCurrentCredentials:Bool)
    case removeActive(ProfileID)
    case candidate(VerifiedProfileCandidate)
}
public enum ProfileSwitchMode:Sendable {case online,localOnly}
public struct ProfileSwitchTicket:Sendable {
    public let id:UUID
    public let source:SessionScope
    public let sourceProfileID:ProfileID?
    public let targetProfile:ProfileRecord?
    public let targetAccountID:AccountID
    let lockedScope:SessionScope
}
public enum ProfileSwitchOutcome:String,Sendable {case online,guest,localOnly,needsLogin,identityMismatch}
public struct ProfileSwitchResult:Sendable {
    public let snapshot:SessionSnapshot
    public let outcome:ProfileSwitchOutcome
}
/// Adapters only: no Cookie material passes into the UI coordinator.
public protocol ProfileSwitchEffects:Sendable {
    func pauseNewRequests() async throws
    func clearWebContexts() async throws
    func resume(snapshot:SessionSnapshot) async
}

/// Owns one switch at a time. A caller's cancellation before commit rolls back;
/// after commit the target stays bound and can be used locally.
public actor ProfileSwitchCoordinator {
    private let manager:SessionManager
    private let effects:any ProfileSwitchEffects
    private var busy=false
    public init(manager:SessionManager,effects:any ProfileSwitchEffects){self.manager=manager;self.effects=effects}
    public func activate(_ target:ProfileSwitchTarget,mode:ProfileSwitchMode = .online) async throws -> ProfileSwitchResult {
        try await perform(target,mode:mode,verifier:nil)
    }
    func perform(_ target:ProfileSwitchTarget,mode:ProfileSwitchMode,verifier:(any SessionVerifier)?) async throws -> ProfileSwitchResult {
        guard !busy else{throw ProfileError.busy};busy=true;defer{busy=false}
        try Task.checkCancellation()
        let ticket=try await manager.prepareProfileSwitch(target)
        var transaction=ticket.targetProfile.map{ProfileSwitchTransaction(source:ticket.source,sourceProfileID:ticket.sourceProfileID,target:$0)}
        var committed=false
        do {
            try await effects.pauseNewRequests();try transaction?.advance(to:.newSchedulingPaused);try Task.checkCancellation()
            try await manager.cancelProfileForeground(ticket);try transaction?.advance(to:.foregroundCancelled)
            try await effects.clearWebContexts();try transaction?.advance(to:.webContextCleared);try Task.checkCancellation()
            let initial=try await manager.commitProfileSwitch(ticket);committed=true
            try transaction?.advance(to:.committed,committedScope:initial.state.scope)
            var outcome:ProfileSwitchOutcome = .localOnly
            if ticket.targetProfile == nil {outcome = .guest}
            else if initial.status == .authenticated && !initial.localOnly {outcome = .online}
            else if mode == .online,initial.cookieCount>0 {
                do {
                    if let verifier{try await manager.verify(using:verifier)}else{try await manager.verifyCurrentSession()}
                    let checked=try await manager.snapshot()
                    outcome=checked.status == .authenticated && !checked.localOnly ? .online : .localOnly
                } catch ProfileError.identityMismatch {outcome = .identityMismatch}
                catch {outcome = .localOnly}
            } else if initial.cookieCount==0 {outcome = .needsLogin}
            let final=try await manager.finishProfileSwitch(ticket)
            try transaction?.finish(verifiedOwner:outcome == .online ? final.state.scope.storage.accountID : nil)
            await effects.resume(snapshot:final)
            return ProfileSwitchResult(snapshot:final,outcome:outcome)
        } catch {
            if !committed {try? transaction?.fail();await manager.abortProfileSwitch(ticket)}
            else {_ = try? await manager.finishProfileSwitch(ticket)}
            if let snapshot=try? await manager.snapshot(){await effects.resume(snapshot:snapshot)}
            throw error
        }
    }
}
