import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private actor AccountOverviewWire: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    let quotaCost: Int
    let failPost: Bool
    let mockQuotaPage: String?

    init(quotaCost: Int = 1_000, failPost: Bool = false, mockQuotaPage: String? = nil) {
        self.quotaCost = quotaCost
        self.failPost = failPost
        self.mockQuotaPage = mockQuotaPage
    }

    func send(request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        let body: String
        switch request.url {
        case AccountOverviewEndpoint.quota:
            if request.method == .post, failPost { throw AppError.transport(code: -1001) }
            let used = request.method == .post ? "8" : "1,250"
            body = mockQuotaPage ?? """
            <div class="stuffbox"><h2>Image Limits</h2><div class="homebox">
              <p>You are currently at <strong>\(used)</strong> towards your account limit of <strong>5,000</strong>.</p>
              <p>You can reset your image quota by spending <strong>\(quotaCost)</strong> GP.</p>
              <form action="" method="post"><p><input type="submit" name="reset_imagelimit" value="Reset Quota"></p></form>
            </div><h2>Other</h2><div class="homebox"><form><input type="submit"></form></div></div>
            """
        case AccountOverviewEndpoint.gp, AccountOverviewEndpoint.hath:
            let amount = request.url == AccountOverviewEndpoint.gp ? "4,087 kGP" : "1,050.3 Hath"
            body = """
            <div><form id="buyform"></form></div><div>Available: <b>37,050</b> Credits</div>
            <div><form id="sellform"></form></div><div>Available: <b>\(amount)</b></div>
            <table><tr><td>Price: 100,500</td></tr></table>
            """
        default: throw AppError.accessDenied
        }
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
            headers: ["Content-Type": "text/html"], body: Data(body.utf8), finalURL: request.url)
    }
}

@MainActor final class AccountOverviewTests: XCTestCase {
    private func context() -> (SessionScope, MutableSessionProvider, URL) {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        return (scope, sessions, FileManager.default.temporaryDirectory.appendingPathComponent("quota-" + UUID().uuidString))
    }

    func testReadsConfirmedQuotaAndBalancesFromExpectedFields() async throws {
        let (scope, sessions, root) = context()
        let wire = AccountOverviewWire()
        let service = AccountOverviewService(sessions: sessions, transport: wire, journalRoot: root)
        let status = try await service.quota(scope: scope)
        XCTAssertEqual(status.quota.used, 1250)
        XCTAssertEqual(status.quota.limit, 5000)
        XCTAssertEqual(status.quota.resetCostGP, 1000)
        XCTAssertFalse(status.resetUnconfirmed)
        let assets = try await service.assets(scope: scope)
        XCTAssertEqual(assets.credits, 37050)
        XCTAssertEqual(assets.kiloGP, 4087)
        XCTAssertEqual(assets.hath, Decimal(string: "1050.3"))
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.method == .get && $0.scope == scope })
    }

    func testZeroUsageWithDisabledResetStillReturnsQuota() async throws {
        let (scope, sessions, root) = context()
        for (used, limit) in [(0,"5,000"), (0,"0"), (12,"5,000")] {
            let wire = AccountOverviewWire(mockQuotaPage: """
                <div class="stuffbox"><h2>Image Limits</h2><div class="homebox"><div>
                    <p>You are currently at <strong>\(used)</strong> towards your account limit of <strong>\(limit)</strong>.</p>
                    <form method="post" action="">
                    <fieldset disabled><input type="submit" name="reset_imagelimit" value="Reset Quota"></fieldset>
                    </form></div>
                </div></div>
                """)
            let service = AccountOverviewService(sessions: sessions, transport: wire, journalRoot: root)
            let status = try await service.quota(scope: scope)
            XCTAssertEqual(status.quota.used, used)
            XCTAssertEqual(status.quota.limit, limit == "0" ? 0 : 5000)
            XCTAssertNil(status.quota.resetCostGP)
            let requests = await wire.requests
            XCTAssertEqual(requests.map(\.method), [.get])
        }
    }

    func testChangedQuoteCannotPostAndConfirmedQuotePostsOnce() async throws {
        let (scope, sessions, root) = context()
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = AccountOverviewWire()
        let service = AccountOverviewService(sessions: sessions, transport: wire, journalRoot: root)
        do {
            _ = try await service.resetQuota(scope: scope, confirmedCost: 999)
            XCTFail("Expected changed quote")
        } catch QuotaResetError.quoteChanged {}
        let updated = try await service.resetQuota(scope: scope, confirmedCost: 1_000)
        XCTAssertEqual(updated.used, 8)
        let posts = await wire.requests.filter { $0.method == .post }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.body, AccountOverviewEndpoint.resetBody)
        let status = try await service.quota(scope: scope)
        XCTAssertFalse(status.resetUnconfirmed)
    }

    func testUncertainResetIsRetainedAfterReopenAndBlocksAnotherPost() async throws {
        let (scope, sessions, root) = context()
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = AccountOverviewWire(failPost: true)
        let original = AccountOverviewService(sessions: sessions, transport: wire, journalRoot: root)
        do {
            _ = try await original.resetQuota(scope: scope, confirmedCost: 1_000)
            XCTFail("Expected unconfirmed reset")
        } catch QuotaResetError.unconfirmed {}
        let reopened = AccountOverviewService(sessions: sessions, transport: wire, journalRoot: root)
        let status = try await reopened.quota(scope: scope)
        XCTAssertTrue(status.resetUnconfirmed)
        do {
            _ = try await reopened.resetQuota(scope: scope, confirmedCost: 1_000)
            XCTFail("Expected pending reset barrier")
        } catch QuotaResetError.unconfirmed {}
        let posts = await wire.requests.filter { $0.method == .post }
        XCTAssertEqual(posts.count, 1)
    }

    func testQuotaPostPolicyRequiresExactEHURLAndBody() throws {
        let (scope, _, _) = context()
        let policy = NetworkPolicy(allowImageQuotaReset: true)
        func post(_ url: URL, body: Data = AccountOverviewEndpoint.resetBody) -> HTTPRequest {
            HTTPRequest(id: UUID(), scope: scope, url: url, method: .post,
                headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
        }
        let valid = post(AccountOverviewEndpoint.quota)
        XCTAssertNoThrow(try policy.validate(valid))
        XCTAssertThrowsError(try NetworkPolicy().validate(valid))
        XCTAssertThrowsError(try policy.validate(post(AccountOverviewEndpoint.gp)))
        XCTAssertThrowsError(try policy.validate(post(AccountOverviewEndpoint.quota, body: Data("reset=anything".utf8))))
    }
}
