import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking

private actor CommentReadTransport: HTTPTransport {
    let status: Int
    let body: String
    var requests: [HTTPRequest] = []
    init(status: Int = 200, body: String) { self.status = status; self.body = body }
    func send(request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:status,
            headers:["Content-Type":"text/html"],body:Data(body.utf8),finalURL:request.url)
    }
}
@MainActor final class CommentReadContractTests: XCTestCase {
    let prefix = "<h1 id='gn'>SYNTHETIC</h1><div id='gdd'></div>"
    private func setup(site: Site, status: Int = 200, comments: String) throws -> (LiveGalleryRepository,CommentReadTransport,MutableSessionProvider,GalleryRequest) {
        let scope = SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:site),generation:1)
        let sessions = MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let transport = CommentReadTransport(status:status,body:prefix+comments)
        let client = HTTPClient(transport:transport,policy:NetworkPolicy())
        let repo = LiveGalleryRepository(client:client,sessions:sessions)
        let reference = GalleryReference(key:GalleryKey(site:site,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        return (repo,transport,sessions,try GalleryRequest(reference:reference,scope:scope))
    }
    func testBothSitesReadCommentsViaOneGETWithUploaderZero() async throws {
        for site in [Site.eh,Site.ex] {
            let (repo,transport,_,request) = try setup(site:site,comments:"<div id='cdiv'><div class='c1'><div class='c6' id='comment_0'>Uploader note</div></div></div>")
            let detail = try await repo.detail(request:request)
            XCTAssertEqual(detail.comments?.items.map(\.id),["0"])
            let requests = await transport.requests
            XCTAssertEqual(requests.count,1); XCTAssertEqual(requests.first?.method,.get)
            XCTAssertEqual(requests.first?.url.pathComponents,["/","g","42","synthetic"])
            XCTAssertEqual(requests.first?.scope,request.scope)
        }
    }
    func testDenialIsErrorNotEmptyAndOldScopeNeverRequests() async throws {
        for status in [401,403] {
            let (repo,_,_,request) = try setup(site:.ex,status:status,comments:"<div id='cdiv'>No comments</div>")
            do { _ = try await repo.detail(request:request); XCTFail("Denied request must not become empty success") }
            catch { XCTAssertEqual(error as? AppError,status == 401 ? .authenticationRequired : .accessDenied) }
        }
        let (repo,transport,sessions,request) = try setup(site:.eh,comments:"<div id='cdiv'>No comments</div>")
        await sessions.update(SessionState(scope:try request.scope.advanced(),authentication:.authenticated))
        do { _ = try await repo.detail(request:request); XCTFail() }
        catch { XCTAssertEqual(error as? AppError,.staleSession) }
        let count = await transport.requests.count; XCTAssertEqual(count,0)
    }
    func testExplicitEmptyAndUnknownMarkupRemainDifferentAtRepositoryBoundary() async throws {
        let (emptyRepo,_,_,emptyRequest) = try setup(site:.eh,comments:"<div id='cdiv'>No comments have been posted.</div>")
        let empty = try await emptyRepo.detail(request:emptyRequest)
        XCTAssertEqual(empty.comments?.items.count,0)
        let (unknownRepo,_,_,unknownRequest) = try setup(site:.eh,comments:"<div id='cdiv'>Unknown layout</div>")
        let unknown = try await unknownRepo.detail(request:unknownRequest)
        XCTAssertNil(unknown.comments); XCTAssertEqual(unknown.summary.title,"SYNTHETIC")
    }
}
