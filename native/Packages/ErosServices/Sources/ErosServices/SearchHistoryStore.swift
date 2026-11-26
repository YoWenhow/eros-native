import Foundation
import ErosCore

@MainActor public final class SearchHistoryStore {
    private let defaults:UserDefaults
    public init(defaults:UserDefaults = .standard) { self.defaults=defaults }
    private func key(_ account: AccountID) -> String { "native.search.history.v2." + account.value.uuidString }
    private func legacy(_ scope: StorageScope) -> [String] {
        let old = "native.search.history.v1." + scope.accountID.value.uuidString + "." + scope.site.rawValue
        return defaults.stringArray(forKey: old) ?? []
    }
    public func load(scope: StorageScope) -> [String] {
        let key = key(scope.accountID)
        if let saved = defaults.stringArray(forKey: key) { return Array(saved.prefix(50)) }
        let other = StorageScope(accountID: scope.accountID, site: scope.site == .eh ? .ex : .eh)
        var seen = Set<String>()
        let merged = Array((legacy(scope) + legacy(other)).filter { seen.insert($0).inserted }.prefix(50))
        defaults.set(merged, forKey: key)
        return merged
    }
    public func record(_ terms:String,scope:StorageScope) {
        let value=terms.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count<=4096 else { return }
        defaults.set(Array(([value]+load(scope:scope).filter{$0 != value}).prefix(50)),forKey:key(scope.accountID))
    }
    public func remove(_ terms:String,scope:StorageScope) { defaults.set(load(scope:scope).filter{$0 != terms},forKey:key(scope.accountID)) }
    public func clear(scope:StorageScope) { defaults.set([String](), forKey: key(scope.accountID)) }
}
