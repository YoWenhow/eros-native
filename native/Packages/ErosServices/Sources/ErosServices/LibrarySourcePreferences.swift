import Foundation
import ErosCore

@MainActor public final class LibrarySourcePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private struct Record: Codable {
        let version: Int
        let source: LibrarySourceSelection
        init(source: LibrarySourceSelection) { version = 1; self.source = source }
        enum CodingKeys: String, CodingKey { case version, source }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            guard version == 1 else { throw AppError.invalidInput }
            source = try c.decodeIfPresent(LibrarySourceSelection.self, forKey: .source) ?? .browse
        }
    }
    private func sharedKey(_ account: AccountID) -> String {
        "native.library.source.v2." + account.value.uuidString
    }
    private func legacyKey(_ scope: StorageScope) -> String {
        "native.library.source.v1." + scope.accountID.value.uuidString + "." + scope.site.rawValue
    }
    public func load(scope: StorageScope) throws -> LibrarySourceSelection {
        let shared = sharedKey(scope.accountID)
        if let data = defaults.data(forKey: shared) {
            return try JSONDecoder().decode(Record.self, from: data).source
        }
        let otherSite: Site = scope.site == .eh ? .ex : .eh
        let other = StorageScope(accountID: scope.accountID, site: otherSite)
        var malformed = false
        for candidate in [scope, other] {
            guard let data = defaults.data(forKey: legacyKey(candidate)) else { continue }
            if let value = try? JSONDecoder().decode(Record.self, from: data).source {
                defaults.set(data, forKey: shared)
                return value
            }
            malformed = true
        }
        if malformed { throw AppError.parseMismatch }
        return .browse
    }
    public func save(_ source: LibrarySourceSelection, scope: StorageScope) throws {
        defaults.set(try JSONEncoder().encode(Record(source: source)), forKey: sharedKey(scope.accountID))
    }
}
