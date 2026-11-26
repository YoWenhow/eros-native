import Foundation

/// A credential/preference entry. Business storage always remains AccountID-owned.
public struct ProfileID: ValidatedValue {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}
public struct CredentialReference: ValidatedValue {
    public let value: UUID
    public init(_ value: UUID) { self.value = value }
}
public enum ProfileIdentity {
    public static let guestAccount = AccountID(UUID(uuidString: "00000000-0000-0000-0000-000000000018")!)
}
public struct ProfileRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: ProfileID
    public let displayName: String
    public let username: String?
    public let profileName: String?
    public let avatarURL: URL?
    public let prefersEHDetails: Bool
    public let accountID: AccountID
    public let selectedSite: Site
    public let credentialReference: CredentialReference
    public let createdAt: Date
    public init(id: ProfileID, displayName: String, accountID: AccountID, selectedSite: Site,
                credentialReference: CredentialReference, createdAt: Date, username: String? = nil, avatarURL: URL? = nil,
                prefersEHDetails: Bool = true, profileName: String? = nil) throws {
        guard accountID != ProfileIdentity.guestAccount, !displayName.isEmpty, displayName.count <= 80,
              displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              username.map(Self.validUsername) ?? true,
              profileName.map(Self.validUsername) ?? true,
              avatarURL.map(Self.validAvatarURL) ?? true,
              createdAt.timeIntervalSince1970.isFinite else { throw AppError.invalidInput }
        self.username = username
        self.profileName = profileName
        self.avatarURL = avatarURL
        self.prefersEHDetails = prefersEHDetails
        self.id=id; self.displayName=displayName; self.accountID=accountID; self.selectedSite=selectedSite
        self.credentialReference=credentialReference; self.createdAt=createdAt
    }
    public func selecting(_ site: Site) throws -> Self {
        try Self(id:id,displayName:displayName,accountID:accountID,selectedSite:site,credentialReference:credentialReference,createdAt:createdAt,username:username,avatarURL:avatarURL,prefersEHDetails:prefersEHDetails,profileName:profileName)
    }
    public func preferringEHDetails(_ enabled: Bool) throws -> Self {
        try Self(id: id, displayName: displayName, accountID: accountID, selectedSite: selectedSite,
                 credentialReference: credentialReference, createdAt: createdAt, username: username,
                 avatarURL: avatarURL, prefersEHDetails: enabled, profileName: profileName)
    }

    public static func validUsername(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    public static func validAvatarURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "forums.e-hentai.org", url.port == nil, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/uploads/"),
              !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let components = url.path.split(separator: "/")
        return components.count >= 2 && !components.contains(".") && !components.contains("..") && !url.path.contains("\\")
    }

    private enum CodingKeys: CodingKey { case id,displayName,accountID,selectedSite,credentialReference,createdAt,username,avatarURL,prefersEHDetails,profileName }
    public init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:c.decode(ProfileID.self,forKey:.id),displayName:c.decode(String.self,forKey:.displayName),
            accountID:c.decode(AccountID.self,forKey:.accountID),selectedSite:c.decode(Site.self,forKey:.selectedSite),
            credentialReference:c.decode(CredentialReference.self,forKey:.credentialReference),createdAt:c.decode(Date.self,forKey:.createdAt),
            username:c.decodeIfPresent(String.self,forKey:.username),
            avatarURL:c.decodeIfPresent(URL.self,forKey:.avatarURL),
            prefersEHDetails:c.decodeIfPresent(Bool.self,forKey:.prefersEHDetails) ?? true,
            profileName:c.decodeIfPresent(String.self,forKey:.profileName))
    }
}

/// F16 freezes order and recovery. F17 must supply real scheduler/WebKit/UI adapters.
/// This value alone performs no switch, persistence, cancellation or network I/O.
public struct ProfileSwitchTransaction: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case prepared, newSchedulingPaused, foregroundCancelled, webContextCleared, committed, ready, rolledBack, offlineOnly
    }
    public let id: UUID
    public let source: SessionScope
    public let sourceProfileID: ProfileID?
    public let target: ProfileRecord
    public private(set) var phase: Phase = .prepared
    public private(set) var committedScope: SessionScope?
    public init(source: SessionScope, sourceProfileID: ProfileID?, target: ProfileRecord) {
        id=UUID();self.source=source;self.sourceProfileID=sourceProfileID;self.target=target
    }
    public mutating func advance(to next: Phase, committedScope: SessionScope? = nil) throws {
        let expected: Phase
        switch phase {
        case .prepared: expected = .newSchedulingPaused
        case .newSchedulingPaused: expected = .foregroundCancelled
        case .foregroundCancelled: expected = .webContextCleared
        case .webContextCleared: expected = .committed
        default: throw AppError.invalidInput
        }
        guard next == expected else { throw AppError.invalidInput }
        if next == .committed {
            guard let committedScope, committedScope.storage.accountID == target.accountID,
                  committedScope.storage.site == target.selectedSite, committedScope.generation > source.generation else { throw AppError.scopeMismatch }
            self.committedScope=committedScope
        } else if committedScope != nil { throw AppError.invalidInput }
        phase=next
    }
    /// A target verified as a different owner must never be silently rebound.
    public mutating func finish(verifiedOwner: AccountID?) throws {
        guard phase == .committed else { throw AppError.invalidInput }
        phase = verifiedOwner == target.accountID ? .ready : .offlineOnly
        if let verifiedOwner, verifiedOwner != target.accountID { throw AppError.scopeMismatch }
    }
    public mutating func fail() throws {
        switch phase {
        case .prepared,.newSchedulingPaused,.foregroundCancelled,.webContextCleared: phase = .rolledBack
        case .committed: phase = .offlineOnly
        default: throw AppError.invalidInput
        }
    }
    public var mayStartTargetRequests: Bool { phase == .ready }
    public static let downloadHandoffMessage = "新请求已暂停，已提交传输可完成"
}
