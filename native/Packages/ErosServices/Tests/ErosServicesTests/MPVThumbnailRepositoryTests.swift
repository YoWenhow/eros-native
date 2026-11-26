import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking

private actor ThumbnailSession: SessionProvider {
    var scope: SessionScope
    init(_ scope:SessionScope){self.scope=scope}
    func current()->SessionState{SessionState(scope:scope,authentication:.authenticated)}
    func advance() throws {scope=try scope.advanced()}
}
private actor ThumbnailTransport: HTTPTransport {
    var bootstrapCalls=0
    let mpv:Bool
    let corrupt:Bool
    let changeSession:ThumbnailSession?
    let hashes: [Int: String]
    let directoryKeys: [String]
    init(mpv: Bool, corrupt: Bool, changeSession: ThumbnailSession?, hashes: [Int: String], directoryKeys: [String]) {
        self.mpv = mpv
        self.corrupt = corrupt
        self.changeSession = changeSession
        self.hashes = hashes
        self.directoryKeys = directoryKeys
    }
    func send(request:HTTPRequest) async throws -> HTTPResponse {
        let html:String
        if request.url.path.hasPrefix("/mpv/") {
            bootstrapCalls += 1
            if let changeSession {try await changeSession.advance()}
            let items = directoryKeys.enumerated().map { index, key in
                ["n": "page-\(index + 1)", "k": key, "t": "unused"]
            }
            let list = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
            html = """
                <script>var gid=\(corrupt ? 43 : 42);var mpvkey="syntheticmpv";var imagelist=\(list);var api_url="https://api.e-hentai.org/api.php";</script>
                """
        } else {
            let cards = (1...directoryKeys.count).map { n in
                let href=mpv ? "/mpv/42/synthetic/#page\(n)" : "/s/actualkey\(n)/42-\(n)"
                let hash = hashes[n].map { " data-orghash='\($0)'" } ?? ""
                return "<a href='\(href)'><div title='Page \(n): synthetic.jpg'\(hash)><img src='https://ehgt.org/w/synthetic-\(n).jpg'></div></a>"
            }.joined()
            html="<h1 id='gn'>Synthetic</h1><div id='gdd'><table><tbody><tr><td>Length:</td><td>\(directoryKeys.count) pages</td></tr></tbody></table></div><div id='gdt'>\(cards)</div>"
        }
        return try HTTPResponse(requestID:request.id,scope:request.scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:request.url)
    }
}
final class MPVThumbnailRepositoryTests:XCTestCase,@unchecked Sendable {
    private func setup(mpv: Bool = true, corrupt: Bool = false, stale: Bool = false, hashes: [Int: String] = [:],
                       directoryKeys: [String] = ["actualkey1", "actualkey2"])
        throws -> (LiveGalleryRepository, ThumbnailTransport, ReaderPagesRequest) {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let sessions = ThumbnailSession(scope)
        let transport = ThumbnailTransport(mpv: mpv, corrupt: corrupt, changeSession: stale ? sessions : nil,
                                           hashes: hashes, directoryKeys: directoryKeys)
        let repo=LiveGalleryRepository(client:HTTPClient(transport:transport),sessions:sessions)
        let reference=GalleryReference(key:GalleryKey(site:.eh,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic"))
        return(repo,transport,try ReaderPagesRequest(reference:reference,context:RequestContext(scope:scope,queryID:UUID())))
    }
    func testDisplayDoesNotRequireBootstrapButReaderGetsRealOrdinaryKeys() async throws {
        let(repo,transport,request)=try setup()
        let thumbs=try await repo.thumbnails(request:request)
        XCTAssertEqual(thumbs.items.count,2)
        let before=await transport.bootstrapCalls;XCTAssertEqual(before,0)
        let pages=try await repo.readerPages(request:request)
        XCTAssertEqual(pages.items.map(\.pageURL.path),["/s/actualkey1/42-1","/s/actualkey2/42-2"])
        XCTAssertTrue(pages.items.allSatisfy{$0.pageURL.fragment == nil})
        XCTAssertEqual(pages.items.map(\.thumbnail?.url), thumbs.items.map(\.thumbnailURL))
        XCTAssertTrue(pages.items.allSatisfy { $0.thumbnail != nil })
        let after=await transport.bootstrapCalls;XCTAssertEqual(after,1)
    }
    func testHashedMPVThumbnailsBypassUnusableDirectory() async throws {
        let (repo, transport, request) = try setup(corrupt: true, hashes: [
            1: String(repeating: "a", count: 40),
            2: String(repeating: "b", count: 40),
        ])
        let pages = try await repo.readerPages(request: request)
        XCTAssertEqual(pages.items.map(\.pageURL.path), ["/s/aaaaaaaaaa/42-1", "/s/bbbbbbbbbb/42-2"])
        let calls = await transport.bootstrapCalls
        XCTAssertEqual(calls, 0)
    }

    func testMixedMPVThumbnailsOnlyUseDirectoryKeysForMissingHashes() async throws {
        let (repo, transport, request) = try setup(hashes: [2: String(repeating: "b", count: 40)])
        let pages = try await repo.readerPages(request: request)
        XCTAssertEqual(pages.items.map(\.pageURL.path), ["/s/actualkey1/42-1", "/s/bbbbbbbbbb/42-2"])
        let calls = await transport.bootstrapCalls
        XCTAssertEqual(calls, 1)
    }

    func testReaderReturnsAll104PagesWhenMPVDirectoryHas98DistinctKeys() async throws {
        let keys = (1...98).map { "key\($0)" }
        let occurrences = keys + keys.prefix(6)
        let (repo, transport, request) = try setup(directoryKeys: occurrences)
        let pages = try await repo.readerPages(request: request)
        XCTAssertEqual(pages.items.count, 104)
        XCTAssertEqual(pages.items.map(\.index.value), Array(0..<104))
        XCTAssertEqual(pages.items.map(\.pageURL.path), occurrences.enumerated().map { index, key in
            "/s/\(key)/42-\(index + 1)"
        })
        let calls = await transport.bootstrapCalls
        XCTAssertEqual(calls, 1)
    }

    func testOrdinarySettingDoesNotFetchBootstrap() async throws {
        let(repo,transport,request)=try setup(mpv:false)
        let result=try await repo.readerPages(request:request);XCTAssertEqual(result.items.count,2)
        let calls=await transport.bootstrapCalls;XCTAssertEqual(calls,0)
    }
    func testBadOrStaleBootstrapNeverPublishesReaderPages() async throws {
        for stale in [false,true] {
            let(repo,_,request)=try setup(corrupt:!stale,stale:stale)
            do{_ = try await repo.readerPages(request:request);XCTFail()}catch{XCTAssertEqual(error as? AppError,stale ? .staleSession : .parseMismatch)}
        }
    }
}
