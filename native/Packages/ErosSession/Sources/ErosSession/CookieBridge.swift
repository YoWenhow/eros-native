#if canImport(WebKit)
import Foundation
import WebKit
import ErosCore

/// Owns one ephemeral WebKit store. No default browser store or Apple credentials are accessed.
@MainActor public final class CookieBridge: NSObject, WKHTTPCookieStoreObserver {
    public let dataStore: WKWebsiteDataStore
    private let manager: SessionManager
    private var listener: Task<Void, Never>?
    private var contextRegistration:UUID?
    private var running = false
    private var clearing = false
    private var pending = false
    private var webChanged = false
    private var applied: SessionSnapshot?
    private var baseline: [SessionCookie] = []
    public private(set) var failed = false
    public init(manager: SessionManager) {
        self.manager = manager; dataStore = .nonPersistent()
        super.init()
    }
    public func start() {
        guard listener == nil else { return }
        if contextRegistration==nil {
            do {contextRegistration=try WebSessionContexts.shared.register(store:dataStore){[weak self] in self?.stop();await self?.clear()}}
            catch {failed=true;return}
        }
        dataStore.httpCookieStore.add(self)
        listener = Task { [weak self, manager] in
            for await _ in await manager.changes() {
                guard !Task.isCancelled else { break }
                self?.schedule(web: false)
            }
        }
    }
    deinit {
        let registration=contextRegistration
        Task{@MainActor in if let registration{WebSessionContexts.shared.unregister(registration)}}
    }
    public func stop() {
        // A stopped but still-live view can retain its WebKit store. Keep that
        // context registered until it is cleared or its owner is deallocated.
        listener?.cancel(); listener = nil
        dataStore.httpCookieStore.remove(self)
    }
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { schedule(web: true) }
    private func schedule(web: Bool) {
        guard !clearing else { return }
        if web { webChanged = true }
        pending = true
        guard !running else { return }
        running = true
        Task {
            while pending && !clearing {
                pending = false
                let capture = webChanged; webChanged = false
                do { try await reconcile(capture: capture); failed = false } catch { failed = true }
            }
            running = false
        }
    }
    private func reconcile(capture: Bool) async throws {
        let before = try await manager.snapshot()
        let actual = await dataStore.httpCookieStore.allCookies()
        if capture, let applied, before.state.scope == applied.state.scope, before.revision == applied.revision {
            var changes: [SessionCookie] = []
            var present: Set<String> = []
            for cookie in actual {
                let normalized = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                let key = cookie.name + "\u{0}" + normalized + "\u{0}" + cookie.path
                let previous = baseline.first { $0.key == key }
                if let record = try? SessionCookie(name: cookie.name, value: cookie.value, domain: cookie.domain,
                    path: cookie.path, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
                    hostOnly: previous?.hostOnly ?? !cookie.domain.hasPrefix("."), expires: cookie.expiresDate) {
                    present.insert(record.key)
                    if record != previous { changes.append(record) }
                }
            }
            for old in baseline where !present.contains(old.key) {
                changes.append(try SessionCookie(name: old.name, value: "", domain: old.domain, path: old.path,
                    secure: old.secure, httpOnly: old.httpOnly, hostOnly: old.hostOnly, expires: .distantPast))
            }
            if !changes.isEmpty { try await manager.merge(changes, scope: before.state.scope) }
        }
        let snapshot = try await manager.snapshot()
        let desired = try await manager.webCookies(scope: snapshot.state.scope)
        // Only this app-owned ephemeral store is cleared/repopulated.
        for cookie in actual where !desired.contains(where: { matches(cookie, $0) }) {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
        for item in desired {
            if actual.contains(where: { matches($0, item) }) { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: item.name, .value: item.value,
                .domain: item.hostOnly ? item.domain : "." + item.domain, .path: item.path]
            if item.secure { properties[.secure] = "TRUE" }
            if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let expires = item.expires { properties[.expires] = expires }
            if let cookie = HTTPCookie(properties: properties) { await dataStore.httpCookieStore.setCookie(cookie) }
        }
        let after = try await manager.snapshot()
        if after.revision == snapshot.revision && after.state.scope == snapshot.state.scope {
            applied = snapshot; baseline = desired
        } else { pending = true; applied = nil }
    }
    private func matches(_ cookie: HTTPCookie, _ item: SessionCookie) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return cookie.name == item.name && cookie.value == item.value && domain == item.domain && cookie.path == item.path
            && cookie.isSecure == item.secure && cookie.isHTTPOnly == item.httpOnly
            && cookie.expiresDate == item.expires
    }
    /// Explicit logout cleanup is awaited before the UI reports completion.
    public func clear() async {
        clearing = true; pending = false; webChanged = false
        while running { try? await Task.sleep(for: .milliseconds(10)) }
        applied = nil; baseline = []
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies { await dataStore.httpCookieStore.deleteCookie(cookie) }
        if let contextRegistration{WebSessionContexts.shared.unregister(contextRegistration)};contextRegistration=nil
        clearing = false
    }
}
#endif
