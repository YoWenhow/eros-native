#if canImport(WebKit)
import Foundation
import WebKit
import ErosCore

/// Only app-created ephemeral stores register here. Never touches Safari/default stores.
@MainActor public final class WebSessionContexts {
    public static let shared=WebSessionContexts()
    private struct Entry {let store:WKWebsiteDataStore;let stop:@MainActor () async -> Void}
    private var entries:[UUID:Entry]=[:]
    private var clearing=false
    private init(){}
    public func register(store:WKWebsiteDataStore,stop:@escaping @MainActor () async -> Void) throws -> UUID {
        guard !clearing,!store.isPersistent else{throw AppError.staleSession}
        let id=UUID();entries[id]=Entry(store:store,stop:stop);return id
    }
    public func unregister(_ id:UUID){entries.removeValue(forKey:id)}
    public func clearAll() async throws {
        guard !clearing else{throw ProfileError.busy};clearing=true;defer{clearing=false}
        let captured=Array(entries.values)
        for entry in captured{await entry.stop()}
        for entry in captured{await entry.store.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast)}
    }
}
#endif
