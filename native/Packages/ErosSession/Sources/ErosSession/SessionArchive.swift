import Foundation
import ErosCore

public enum ProfileStorageStatus: String, Sendable { case current, legacyFallback }
public enum ProfileError: Error, Sendable { case identityMismatch, duplicateIdentity, invalidProfile, busy, activeProfileRequiresGuest, existingProfile(ProfileID) }

/// Secrets exist only inside the credential store; ProfileRecord is a projection.
struct SessionArchive: Codable {
    var version = 2
    var generation: UInt64 = 1
    var site: Site = .eh
    var account = ProfileIdentity.guestAccount
    var accounts: [String:AccountID] = [:]
    var cookies: [SessionCookie] = []
    var profiles: [ProfileRecord] = []
    var credentials: [String:[SessionCookie]] = [:]
    var activeProfileID: ProfileID?
    var localOnly=false
    var accessEvidence:[String:ProfileAccessEvidence]=[:]
    private enum CodingKeys: CodingKey {case version,generation,site,account,accounts,cookies,profiles,credentials,activeProfileID,localOnly,accessEvidence}
    init() {}
    init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version)
        guard version==1 || version==2 else { throw CredentialStoreError.invalidArchive }
        generation=try c.decode(UInt64.self,forKey:.generation);site=try c.decode(Site.self,forKey:.site)
        account=try c.decode(AccountID.self,forKey:.account);accounts=try c.decode([String:AccountID].self,forKey:.accounts)
        cookies=try c.decode([SessionCookie].self,forKey:.cookies)
        if version==2 {
            profiles=try c.decode([ProfileRecord].self,forKey:.profiles);credentials=try c.decode([String:[SessionCookie]].self,forKey:.credentials)
            activeProfileID=try c.decodeIfPresent(ProfileID.self,forKey:.activeProfileID)
            localOnly=try c.decodeIfPresent(Bool.self,forKey:.localOnly) ?? false
            accessEvidence=try c.decodeIfPresent([String:ProfileAccessEvidence].self,forKey:.accessEvidence) ?? [:]
        }
    }
    var activeProfile: ProfileRecord? { profiles.first{$0.id==activeProfileID} }
    func validate() throws {
        guard generation<UInt64.max,accounts.count<=1024,profiles.count<=128,cookies.count<=200,
              Set(accounts.values).count==accounts.count,
              accounts.allSatisfy({!$0.key.isEmpty && $0.key.count<256 && $0.value != ProfileIdentity.guestAccount}),
              account==ProfileIdentity.guestAccount || accounts.values.contains(account),
              Set(profiles.map(\.id)).count==profiles.count,Set(profiles.map(\.accountID)).count==profiles.count,
              Set(profiles.map(\.credentialReference)).count==profiles.count,
              profiles.allSatisfy({accounts.values.contains($0.accountID)}),
              Set(credentials.keys)==Set(profiles.map{$0.credentialReference.value.uuidString}),
              Set(accessEvidence.keys).isSubset(of:Set(profiles.map{$0.id.value.uuidString})),
              accessEvidence.values.allSatisfy({$0.checkedAt.timeIntervalSince1970.isFinite}),
              credentials.values.allSatisfy({$0.count<=200}) else { throw CredentialStoreError.invalidArchive }
        for jar in [cookies]+Array(credentials.values) {
            guard Set(jar.map(\.key)).count==jar.count else { throw CredentialStoreError.invalidArchive }
            for c in jar { _=try SessionCookie(name:c.name,value:c.value,domain:c.domain,path:c.path,secure:c.secure,httpOnly:c.httpOnly,hostOnly:c.hostOnly,expires:c.expires) }
        }
        if version==2 {
            if account==ProfileIdentity.guestAccount {guard activeProfileID==nil else{throw CredentialStoreError.invalidArchive}}
            else {guard let activeProfile,activeProfile.accountID==account,activeProfile.selectedSite==site,
                        credentials[activeProfile.credentialReference.value.uuidString]==cookies else{throw CredentialStoreError.invalidArchive}}
        }
    }
    mutating func bindCurrent() throws {
        guard account != ProfileIdentity.guestAccount else { activeProfileID=nil;return }
        guard accounts.values.contains(account) else { throw ProfileError.invalidProfile }
        let profile: ProfileRecord
        if let existing=profiles.first(where:{$0.accountID==account}) {profile=try existing.selecting(site)}
        else {profile=try ProfileRecord(id:ProfileID(UUID()),displayName:profiles.isEmpty ? "默认账号" : "账号 \(profiles.count+1)",accountID:account,selectedSite:site,credentialReference:CredentialReference(UUID()),createdAt:Date());profiles.append(profile)}
        activeProfileID=profile.id
        if let i=profiles.firstIndex(where:{$0.id==profile.id}) {profiles[i]=profile}
        credentials[profile.credentialReference.value.uuidString]=cookies
    }
    mutating func prepareForSaving() throws {
        version=2;try bindCurrent();try validate()
    }
    mutating func revokeActiveCredentials() {
        if let profile=activeProfile {credentials[profile.credentialReference.value.uuidString]=[]}
        activeProfileID=nil;account=ProfileIdentity.guestAccount;cookies=[];localOnly=false
    }
}
