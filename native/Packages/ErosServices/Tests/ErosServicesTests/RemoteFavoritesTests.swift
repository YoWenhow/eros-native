import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices
import ErosOfflineDemo

private actor FavoriteTransport: HTTPTransport {
    var group: String?
    var note = ""
    var ambiguous = false
    var unreadable = false
    var hold = false
    var gate: CheckedContinuation<Void, Never>?
    func holdPosts() { hold = true }
    func release() { hold = false; gate?.resume(); gate = nil }
    var posts = 0
    var reads = 0
    var body: String?
    func configure(ambiguous: Bool, unreadable: Bool) { self.ambiguous = ambiguous; self.unreadable = unreadable }
    func counters() -> (Int, Int) { (posts, reads) }
    func postedBody() -> String? { body }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == .post {
            posts += 1; if hold { await withCheckedContinuation { gate = $0 } }; body = request.body.flatMap { String(data: $0, encoding: .utf8) }
            let pairs = URLComponents(string: "https://eh.example.invalid/?" + (body ?? ""))?.queryItems ?? []
            group = pairs.first { $0.name == "favcat" }?.value
            if group == "favdel" { group = nil }
            note = pairs.first { $0.name == "favnote" }?.value ?? ""
            if ambiguous { throw AppError.httpStatus(503) }
        } else { reads += 1 }
        if unreadable && posts > 0 { throw AppError.parseMismatch }
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let rows = (0...9).map { n in
            "<div><div><input type=radio name=favcat value=\"\(n)\" \(String(n) == (group ?? "0") ? "checked" : "")></div><div></div><div>Group \(n)</div></div>"
        }.joined()
        let html = "<form id=galpop method=post action=\"\">" + rows + (group == nil ? "" : "<input type=radio name=favcat value=favdel>") + "<textarea name=favnote>\(escape(note))</textarea><input type=hidden name=update value=7><input type=submit name=apply value=Save></form>"
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200, headers: ["Content-Type":"text/html"], body: Data(html.utf8), finalURL: request.url)
    }
}

@MainActor final class RemoteFavoritesTests: XCTestCase {
    private let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    private func reference() throws -> GalleryReference { GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("synthetictoken")) }
    private func repository(_ transport: FavoriteTransport, _ provider: MutableSessionProvider) -> LiveFavoritesRepository {
        LiveFavoritesRepository(client: HTTPClient(transport: transport, policy: FixtureTransport.policy), sessions: provider, policy: FixtureTransport.policy)
    }
    func testConfirmedAddRemoveAndFormEncoding() async throws {
        let transport = FavoriteTransport(), provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let repo = repository(transport, provider), ref = try reference()
        let note = "中文 + & = note\n第二行  双空格"
        try await repo.mutate(request: FavoriteMutation(reference: ref, scope: scope, action: .add(groupID: "2", note: note)))
        let form = try await repo.popup(request: GalleryRequest(reference: ref, scope: scope))
        XCTAssertEqual(form.selectedGroup, "2"); XCTAssertEqual(form.note, note)
        let body = await transport.postedBody()
        XCTAssertTrue(body?.contains("%2B") == true); XCTAssertTrue(body?.contains("update=7") == true)
        try await repo.mutate(request: FavoriteMutation(reference: ref, scope: scope, action: .remove))
        let after = try await repo.popup(request: GalleryRequest(reference: ref, scope: scope))
        XCTAssertFalse(after.isFavorite)
        let counts = await transport.counters(); XCTAssertEqual(counts.0, 2)
    }
    func testAmbiguousPostReadsBackWithoutReplay() async throws {
        let transport = FavoriteTransport(), provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        await transport.configure(ambiguous: true, unreadable: false)
        try await repository(transport, provider).mutate(request: FavoriteMutation(reference: reference(), scope: scope, action: .add(groupID: "1", note: nil)))
        let counts = await transport.counters(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 2)
    }
    func testEditorReportsSuccessOnlyAfterVerifiedWrite() async throws {
        let transport = FavoriteTransport(), provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let editor = try RemoteFavoriteEditorModel(repository: repository(transport, provider), request: GalleryRequest(reference: reference(), scope: scope))
        let beforeLoad = await editor.save(.add(groupID: "3", note: "")); XCTAssertFalse(beforeLoad)
        await editor.load()
        let success = await editor.save(.add(groupID: "3", note: ""))
        XCTAssertTrue(success); XCTAssertEqual(editor.form?.selectedGroup, "3"); XCTAssertFalse(editor.unconfirmed)
        await provider.update(SessionState(scope: try scope.advanced(), authentication: .authenticated))
        let stale = await editor.save(.add(groupID: "2", note: "")); XCTAssertFalse(stale)
    }
    func testUnknownOutcomeLocksEditorUntilExplicitRead() async throws {
        let transport = FavoriteTransport(), provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let editor = try RemoteFavoriteEditorModel(repository: repository(transport, provider), request: GalleryRequest(reference: reference(), scope: scope))
        await editor.load(); XCTAssertFalse(try XCTUnwrap(editor.form).isFavorite)
        await transport.configure(ambiguous: true, unreadable: true)
        let success = await editor.save(.add(groupID: "3", note: "")); XCTAssertFalse(success); XCTAssertTrue(editor.unconfirmed)
        XCTAssertFalse(try XCTUnwrap(editor.form).isFavorite)
        await editor.save(.add(groupID: "3", note: ""))
        let counts = await transport.counters(); XCTAssertEqual(counts.0, 1)
        await transport.configure(ambiguous: false, unreadable: false)
        await editor.load(); XCTAssertFalse(editor.unconfirmed); XCTAssertEqual(editor.form?.selectedGroup, "3")
    }
    func testConcurrentMutationUsesOnePost() async throws {
        let transport = FavoriteTransport(), provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let repo = repository(transport, provider)
        let mutation = try FavoriteMutation(reference: reference(), scope: scope, action: .add(groupID: "1", note: nil))
        await transport.holdPosts()
        let first = Task { try await repo.mutate(request: mutation) }
        while (await transport.counters()).0 == 0 { await Task.yield() }
        do { try await repo.mutate(request: mutation); XCTFail() }
        catch FavoriteWriteFailure.pending {} catch { XCTFail("Unexpected error") }
        await transport.release(); try await first.value
        let counts = await transport.counters(); XCTAssertEqual(counts.0, 1)
    }
    func testGuestAndStaleScopeSendNoRequests() async throws {
        let transport = FavoriteTransport(), provider = MutableSessionProvider(SessionState(scope: scope, authentication: .guest))
        let repo = repository(transport, provider), request = try GalleryRequest(reference: reference(), scope: scope)
        do { _ = try await repo.popup(request: request); XCTFail() } catch { XCTAssertEqual(error as? AppError, .authenticationRequired) }
        await provider.update(SessionState(scope: try scope.advanced(), authentication: .authenticated))
        do { _ = try await repo.popup(request: request); XCTFail() } catch { XCTAssertEqual(error as? AppError, .staleSession) }
        let counts = await transport.counters(); XCTAssertEqual(counts.0 + counts.1, 0)
    }
}
