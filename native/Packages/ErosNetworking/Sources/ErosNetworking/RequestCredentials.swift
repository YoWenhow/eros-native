import Foundation
import ErosCore

/// Credentials never enter caller-supplied HTTPRequest headers or diagnostics.
public protocol RequestCredentials: Sendable {
    func authorize(_ request: HTTPRequest) async throws
    func register(id: UUID, scope: SessionScope, cancel: @escaping @Sendable () -> Void) async throws
    func unregister(id: UUID) async
    func cookieHeader(url: URL, scope: SessionScope) async throws -> String?
    func receive(headers: [String: String], url: URL, scope: SessionScope) async throws
}

extension RequestCredentials {
    public func authorize(_ request: HTTPRequest) async throws {}
}
