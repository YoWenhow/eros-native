import Foundation
import ErosCore
import ErosNetworking

public struct AccountQuotaStatus: Sendable {
    public let quota: ImageQuota
    public let resetUnconfirmed: Bool
}

public enum QuotaResetError: Error {
    case busy, unconfirmed, quoteChanged
}

public actor AccountOverviewService {
    private let sessions: any SessionProvider
    private let transport: any HTTPTransport
    private let journalRoot: URL
    private var resetting: Set<AccountID> = []
    private let parser = AccountOverviewParser()
    private let classifier = ResponseClassifier(policy: NetworkPolicy(allowImageQuotaReset: true))

    public init(sessions: any SessionProvider, transport: any HTTPTransport, journalRoot: URL) {
        self.sessions = sessions
        self.transport = transport
        self.journalRoot = journalRoot
    }

    public func quota(scope: SessionScope) async throws -> AccountQuotaStatus {
        let response = try await read(AccountOverviewEndpoint.quota, scope: scope)
        return AccountQuotaStatus(quota: try parser.quota(response),
                                  resetUnconfirmed: try hasUnconfirmedReset(scope.storage.accountID))
    }

    public func assets(scope: SessionScope) async throws -> AccountAssets {
        async let gp = read(AccountOverviewEndpoint.gp, scope: scope)
        async let hath = read(AccountOverviewEndpoint.hath, scope: scope)
        return try await parser.assets(gp: gp, hath: hath)
    }

    public func resetQuota(scope: SessionScope, confirmedCost: Int) async throws -> ImageQuota {
        let owner = scope.storage.accountID
        guard resetting.insert(owner).inserted else { throw QuotaResetError.busy }
        defer { resetting.remove(owner) }
        guard try !hasUnconfirmedReset(owner) else { throw QuotaResetError.unconfirmed }
        let before = try await quota(scope: scope).quota
        guard before.used > 0, before.resetCostGP == confirmedCost else { throw QuotaResetError.quoteChanged }
        let request = HTTPRequest(id: UUID(), scope: scope, url: AccountOverviewEndpoint.quota, method: .post,
            headers: ["Accept": "text/html", "Content-Type": "application/x-www-form-urlencoded",
                      "Referer": AccountOverviewEndpoint.quota.absoluteString],
            body: AccountOverviewEndpoint.resetBody)
        try classifier.policy.validate(request)
        try await check(scope)
        let marker = file(for: owner)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        try StorageBackupPolicy.included.apply(toDirectory: journalRoot)
        try Data([1]).write(to: marker, options: .atomic)
        do {
            let response = try await transport.send(request: request)
            try classifier.validate(response, request: request, kind: .html, now: Date())
            try await check(scope)
            let after = try parser.quota(response)
            guard after.used < before.used else { throw QuotaResetError.unconfirmed }
            try FileManager.default.removeItem(at: marker)
            return after
        } catch {
            // The site may have received the POST even if its response was lost.
            throw QuotaResetError.unconfirmed
        }
    }

    public func acknowledgeUnconfirmedReset(scope: SessionScope) async throws {
        try await check(scope)
        let owner = scope.storage.accountID
        guard !resetting.contains(owner) else { throw QuotaResetError.busy }
        if try hasUnconfirmedReset(owner) { try FileManager.default.removeItem(at: file(for: owner)) }
    }

    private func hasUnconfirmedReset(_ owner: AccountID) throws -> Bool {
        do {
            _ = try Data(contentsOf: file(for: owner))
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false
        }
    }

    private func file(for owner: AccountID) -> URL {
        journalRoot.appendingPathComponent(owner.value.uuidString)
    }

    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        let current = try await sessions.current()
        guard current.scope == scope, scope.storage.site == .eh else { throw AppError.staleSession }
        guard current.authentication == .authenticated, current.permitsNetwork else { throw AppError.authenticationRequired }
        try Task.checkCancellation()
    }

    private func read(_ url: URL, scope: SessionScope) async throws -> HTTPResponse {
        try await check(scope)
        let request = HTTPRequest(id: UUID(), scope: scope, url: url, method: .get, headers: ["Accept": "text/html"])
        let response = try await transport.send(request: request)
        try classifier.validate(response, request: request, kind: .html, now: Date())
        try await check(scope)
        return response
    }
}
