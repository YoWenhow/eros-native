import Foundation
import ErosCore

@MainActor public final class SearchFilterPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func sharedKey(_ account: AccountID) -> String {
        "native.search.filters.v2." + account.value.uuidString
    }
    private func legacyKey(_ scope: StorageScope) -> String {
        "native.search.filters.v1." + scope.accountID.value.uuidString + "." + scope.site.rawValue
    }
    public func load(scope: StorageScope) throws -> SearchFilterSelection {
        let shared = sharedKey(scope.accountID)
        if let data = defaults.data(forKey: shared) {
            return try JSONDecoder().decode(SearchFilterSelection.self, from: data)
        }
        let otherSite: Site = scope.site == .eh ? .ex : .eh
        let other = StorageScope(accountID: scope.accountID, site: otherSite)
        var malformed = false
        for candidate in [scope, other] {
            guard let data = defaults.data(forKey: legacyKey(candidate)) else { continue }
            if let value = try? JSONDecoder().decode(SearchFilterSelection.self, from: data) {
                defaults.set(data, forKey: shared)
                return value
            }
            malformed = true
        }
        if malformed { throw AppError.parseMismatch }
        return SearchFilterSelection()
    }
    public func save(_ selection: SearchFilterSelection, scope: StorageScope) throws {
        defaults.set(try JSONEncoder().encode(selection), forKey: sharedKey(scope.accountID))
    }
}
