import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import ErosCore
@testable import ErosNetworking

actor FakeClock: Clock {
    private(set) var delays: [Double] = []
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(seconds: TimeInterval) throws { try Task.checkCancellation();delays.append(seconds) }
}
actor FakeTransport: HTTPTransport {
    var responses: [Result<HTTPResponse,AppError>]
    private(set) var count = 0
    init(_ responses: [Result<HTTPResponse,AppError>]) { self.responses = responses }
    func send(request: HTTPRequest) throws -> HTTPResponse {
        try Task.checkCancellation();count += 1
        guard !responses.isEmpty else { throw AppError.invalidInput };return try responses.removeFirst().get()
    }
}
actor TestCredentials: RequestCredentials {
    var active: Set<UUID> = []
    var responseCount = 0
    var headerCount = 0
    func register(id: UUID, scope: SessionScope, cancel: @escaping @Sendable () -> Void) { active.insert(id) }
    func unregister(id: UUID) { active.remove(id) }
    func cookieHeader(url: URL, scope: SessionScope) -> String? {
        headerCount += 1
        if url.path.hasPrefix("/g/") { return "synthetic=initial; datatags=0" }
        return url.path == "/next" ? "synthetic=rotated" : "synthetic=initial"
    }
    func receive(headers: [String: String], url: URL, scope: SessionScope) { responseCount += 1 }
}

// Foundation may invoke URLProtocol from arbitrary threads; all test scenario state is lock-protected.
final class WireState: @unchecked Sendable {
    let lock = NSLock()
    typealias Reply = (Int, [String: String], Data)
    private var replies: [Reply] = []
    private var rangeReplies: [String: Reply] = [:]
    private var requests: [URLRequest] = []

    func reset(_ replies: [Reply], ranges: [String: Reply] = [:]) {
        lock.withLock {
            self.replies = replies
            rangeReplies = ranges
            requests = []
        }
    }

    func next(_ request: URLRequest) -> Reply? {
        lock.withLock {
            requests.append(request)
            if let range = request.value(forHTTPHeaderField: "Range"),
               let reply = rangeReplies.removeValue(forKey: range) { return reply }
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
    func captured() -> [URLRequest] { lock.lock();defer { lock.unlock() };return requests }
}
final class StubProtocol: URLProtocol {
    static let state = WireState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (code,headers,body) = Self.state.next(request) else { client?.urlProtocol(self,didFailWithError: URLError(.timedOut));return }
        let response = HTTPURLResponse(url: request.url!,statusCode: code,httpVersion: "HTTP/1.1",headerFields: headers)!
        client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self,didLoad: body);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ArchiveProgressCapture: @unchecked Sendable {
    private let lock=NSLock()
    private var values:[ArchiveByteProgress]=[]
    func record(_ value:ArchiveByteProgress) { lock.lock();values.append(value);lock.unlock() }
    func latest()->ArchiveByteProgress? { lock.lock();defer{lock.unlock()};return values.last }
    func count()->Int { lock.lock();defer{lock.unlock()};return values.count }
}

@MainActor
final class NetworkingTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()),site: .eh),generation: 1)
    let policy = NetworkPolicy(parsing: ParsingPolicy(ehHost: "eh.example.invalid",exHost: "ex.example.invalid",forumHost: "forums.example.invalid"),mediaHosts: ["cdn.example.invalid"])
    func request(method: HTTPMethod = .get, url: String = "https://eh.example.invalid/", headers: [String:String] = ["Accept":"text/html"]) -> HTTPRequest {
        HTTPRequest(id: UUID(),scope: scope,url: URL(string: url)!,method: method,headers: headers)
    }
    func response(_ request: HTTPRequest, status: Int = 200, mime: String = "text/html", body: String = "<html>synthetic</html>", extra: [String:String] = [:], url: URL? = nil, scope: SessionScope? = nil) throws -> HTTPResponse {
        try HTTPResponse(requestID: request.id,scope: scope ?? request.scope,status: status,headers: extra.merging(["Content-Type":mime]) { a,_ in a },body: Data(body.utf8),finalURL: url ?? request.url)
    }
    func testCompactCursorReplacesOldModeAndKeepsSearchAndScope() throws {
        let context = RequestContext(scope: scope, queryID: UUID())
        let cursor = PageCursor(context: context, opaque: try SensitiveText("url-v1:https://eh.example.invalid/?next=42&f_search=a%2Bb&inline_set=dm_t"))
        let request = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: GalleryQuery(), context: context, cursor: cursor))
        let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "inline_set" }.map(\.value), ["dm_l"])
        XCTAssertEqual(items.first { $0.name == "f_search" }?.value, "a+b")
        XCTAssertEqual(items.first { $0.name == "next" }?.value, "42")
        XCTAssertEqual(request.scope, scope)
    }
    func testSearchCursorPreservesFormEncodingAndFilters() throws {
        let context = RequestContext(scope: scope, queryID: UUID())
        let query = "f_search=artist:sample+language:%22chinese%24%22+title:a%2Bb&f_cats=960&next=42"
        let cursor = PageCursor(context: context, opaque: try SensitiveText("url-v1:https://eh.example.invalid/?" + query + "&inline%5Fset=dm_t"))
        let request = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: GalleryQuery(), context: context, cursor: cursor))
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                       query + "&inline_set=dm_l")
    }
    func testSearchEncodingCategoriesAndFilters() throws {
        let query = try GalleryQuery(terms: "female:\"日本語 + 中文\" -tag:a&b%",excludedCategories: ["Manga","Western","Manga"],filters: SearchFilters(requireTorrent: true,minimumRating: NonnegativeCount(4),minimumPageCount: NonnegativeCount(10),maximumPageCount: NonnegativeCount(20)))
        let req = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: query,context: RequestContext(scope: scope,queryID: UUID())))
        let items = URLComponents(url: req.url,resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "f_search" }?.value,query.terms)
        XCTAssertTrue(req.url.absoluteString.contains("%2B"));XCTAssertFalse(req.url.absoluteString.contains("%2525"))
        XCTAssertEqual(items.first { $0.name == "f_cats" }?.value,"516")
        for (key,value) in ["advsearch":"1","f_sto":"on","f_srdd":"4","f_spf":"10","f_spt":"20"] { XCTAssertEqual(items.first { $0.name == key }?.value,value) }
        XCTAssertEqual(items.filter { $0.name == "inline_set" }.map(\.value), ["dm_l"])
        XCTAssertFalse(items.contains { $0.name == "page" })
    }

    func testF01bListEndpointEncodingAndToplistSiteBoundary() throws {
        let builder=EndpointBuilder(policy:policy)
        let context=RequestContext(scope:scope,queryID:UUID())
        let filters=try SearchFilters(requireTorrent:true)
        let popular=try builder.list(GalleryListRequest(query:GalleryQuery(terms:"must not leak",excludedCategories:["Manga"],source:.popular,filters:filters),context:context))
        XCTAssertEqual(popular.url.path,"/popular");XCTAssertEqual(popular.url.query, "inline_set=dm_l")
        let watched=try builder.list(GalleryListRequest(query:GalleryQuery(terms:"synthetic+tag",source:.watched,filters:filters),context:context))
        XCTAssertEqual(watched.url.path,"/watched")
        let params=URLComponents(url:watched.url,resolvingAgainstBaseURL:false)?.queryItems
        XCTAssertEqual(params?.first{$0.name == "f_search"}?.value,"synthetic+tag")
        XCTAssertEqual(params?.first{$0.name == "f_sto"}?.value,"on")
        for period in ["11","12","13","15"] {
            let value=try builder.list(GalleryListRequest(query:GalleryQuery(source:.toplist(period:period)),context:context))
            XCTAssertEqual(value.url.path,"/toplist.php");XCTAssertEqual(value.url.query,"tl="+period)
        }
        XCTAssertThrowsError(try builder.list(GalleryListRequest(query:GalleryQuery(source:.toplist(period:"999")),context:context)))
        let ex=SessionScope(storage:StorageScope(accountID:scope.storage.accountID,site:.ex),generation:2)
        XCTAssertThrowsError(try builder.list(GalleryListRequest(query:GalleryQuery(source:.toplist(period:"11")),context:RequestContext(scope:ex,queryID:UUID())))) {
            XCTAssertEqual($0 as? AppError,.scopeMismatch)
        }
    }
    func testF02aNormalizedDraftWireParametersAndDisabledValues() throws {
        let expression = "language:\"中文 日本語\" + %25 & #"
        var draft = SearchFilterDraft()
        draft.excludedCategories = Set(SearchCategory.allCases)
        draft.requireTorrent = true; draft.includeExpunged = true
        draft.disableLanguageFilter = true; draft.disableUploaderFilter = true; draft.disableTagFilter = true
        draft.ratingEnabled = true; draft.minimumRating = .five
        draft.pageRangeEnabled = true; draft.minimumPageCount = "0"; draft.maximumPageCount = "100"
        for site in [Site.eh, .ex] {
            let context = RequestContext(scope: SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: site), generation: 1), queryID: UUID())
            let query = try draft.normalizedQuery(replacing: GalleryQuery(terms: expression))
            let request = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: query, context: context))
            let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(values, ["inline_set":"dm_l", "f_search":expression, "f_cats":"1023", "advsearch":"1", "f_sto":"on", "f_sh":"on", "f_sfl":"on", "f_sfu":"on", "f_sft":"on", "f_sr":"on", "f_srdd":"5", "f_sp":"on", "f_spf":"0", "f_spt":"100"])
        }
        draft.reset(); draft.minimumRating = .five; draft.minimumPageCount = "bad"; draft.maximumPageCount = "-1"
        let query = try draft.normalizedQuery(replacing: GalleryQuery(terms: expression))
        let context = RequestContext(scope: scope, queryID: UUID())
        let request = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: query, context: context))
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "inline_set", value: "dm_l"), URLQueryItem(name: "f_search", value: expression)])
    }

    func testF03aTypedSourceRequestsUseOnlyTheirEndpointParameters() throws {
        let context = RequestContext(scope: scope, queryID: UUID())
        for selection in LibrarySourceSelection.all {
            let request = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: selection.query, context: context))
            switch selection {
            case .browse: XCTAssertEqual(request.url.path, "/"); XCTAssertEqual(request.url.query, "inline_set=dm_l")
            case .popular: XCTAssertEqual(request.url.path, "/popular"); XCTAssertEqual(request.url.query, "inline_set=dm_l")
            case .watched: XCTAssertEqual(request.url.path, "/watched"); XCTAssertEqual(request.url.query, "inline_set=dm_l")
            case .toplist(let period):
                XCTAssertEqual(request.url.path, "/toplist.php"); XCTAssertEqual(request.url.query, "tl=" + period.rawValue)
            }
            XCTAssertEqual(request.scope, scope)
        }
    }

    func testImageByteTelemetryUsesActualReceiverBytes() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let transport=BoundedImageTransport(policy:policy,maximumBytes:8,configuration:config)
        let request=request(url:"https://cdn.example.invalid/img",headers:["Accept":"image/*"])
        let owner=TransferOwner.reader(request.scope,try GalleryID(999),try PageIndex(0))
        TransferProgress.shared.begin(id:request.id.uuidString,owner:owner)
        defer { TransferProgress.shared.finish(id:request.id.uuidString) }
        StubProtocol.state.reset([(200,["Content-Type":"image/png","Content-Length":"4"],Data([1,2,3,4]))])
        _ = try await transport.send(request:request)
        let value=TransferProgress.shared.snapshot(owner:owner)
        XCTAssertEqual(value.received,4);XCTAssertEqual(value.fraction,1)
    }
    private func preparedArchive() throws -> PreparedArchive {
        let address=try ArchivePreparationAddress(
            url:URL(string:"https://abcdefghijklmnopqrst.hath.network/archive/42/"
                + String(repeating:"a",count:40) + "/synthetic/1")!,gallery:GalleryID(42))
        let readyRequest=address.request(scope:scope)
        let readyHTML="<div id='db'><p>The file was successfully prepared, and is ready for download. "
            + "<a href='?start=1'>Click Here To Start Downloading</a></p></div>"
        let readyResponse=try HTTPResponse(requestID:readyRequest.id,scope:scope,status:200,
            headers:["Content-Type":"text/html"],body:Data(readyHTML.utf8),finalURL:address.url)
        return try ArchivePreparationParser().parse(readyResponse,
            request:readyRequest,address:address)
    }

    func testArchiveByteTelemetryPrefersExactResponseLengthAndFallsBackToQuote() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[StubProtocol.self]
        let transport=ArchiveFileTransport(maximumBytes:100,configuration:config)
        let prepared = try preparedArchive()
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:directory) }
        let body=Data([0x50,0x4b,0x03,0x04] + Array(repeating:UInt8(0),count:18))
        for (headers,estimated) in [(["Content-Type":"application/zip","Content-Length":"22"],false),
                                    (["Content-Type":"application/zip"],true)] {
            let capture=ArchiveProgressCapture()
            StubProtocol.state.reset([(200,headers,body)])
            let file=try await transport.download(prepared,in:directory,estimatedBytes:100) {
                capture.record($0)
            }
            XCTAssertEqual(try Data(contentsOf:file),body)
            let last=try XCTUnwrap(capture.latest())
            XCTAssertGreaterThanOrEqual(capture.count(),2)
            XCTAssertEqual(last.received,22)
            XCTAssertEqual(last.delta,22)
            XCTAssertEqual(last.expected,estimated ? 100 : 22)
            XCTAssertEqual(last.isEstimated,estimated)
            try FileManager.default.removeItem(at:file)
        }
    }
    func testArchiveRangeDownloadWritesExactOffsetsAndReportsTotal() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let transport = ArchiveFileTransport(maximumBytes: 512, configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data([0x50, 0x4b, 0x03, 0x04] + Array(4...63))
        let offsets = [0...0, 1...21, 22...42, 43...63]
        let replies: [String: WireState.Reply] = Dictionary(uniqueKeysWithValues: offsets.map { range in
            let from = range.lowerBound, to = range.upperBound
            return ("bytes=\(from)-\(to)", (206, [
                "Content-Type": "application/zip", "Content-Length": "\(range.count)",
                "Content-Range": "bytes \(from)-\(to)/\(body.count)", "ETag": "\"fixture\""
            ], body.subdata(in: from..<(to + 1))))
        })
        StubProtocol.state.reset([], ranges: replies)
        let progress = ArchiveProgressCapture()
        let result = try await transport.download(preparedArchive(), in: directory, threads: 3, submit: nil) {
            progress.record($0)
        }
        XCTAssertEqual(try Data(contentsOf: result), body)
        XCTAssertEqual(progress.latest()?.received, 64)
        XCTAssertEqual(progress.latest()?.expected, 64)
        XCTAssertEqual(progress.latest()?.isEstimated, false)
        let sent = StubProtocol.state.captured()
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Range"), "bytes=0-0")
        XCTAssertEqual(Set(sent.compactMap { $0.value(forHTTPHeaderField: "Range") }), Set(replies.keys))
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(sent.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "If-Range") == "\"fixture\"" })
        XCTAssertTrue(sent.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    func testArchiveRangeFallbackAndInvalidSegmentCleanup() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let transport = ArchiveFileTransport(maximumBytes: 512, configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data([0x50, 0x4b, 0x03, 0x04] + Array(repeating: UInt8(0), count: 18))
        let prepared = try preparedArchive()

        StubProtocol.state.reset([(200, ["Content-Length": "22"], body)])
        let fallback = try await transport.download(prepared, in: directory, threads: 3, submit: nil)
        XCTAssertEqual(try Data(contentsOf: fallback), body)
        XCTAssertEqual(StubProtocol.state.captured().count, 1)
        try FileManager.default.removeItem(at: fallback)

        StubProtocol.state.reset([], ranges: [
            "bytes=0-0": (206, ["Content-Range": "bytes 0-0/22", "Content-Length": "1"], Data([0x50])),
            "bytes=1-11": (206, ["Content-Range": "bytes 2-12/22", "Content-Length": "11"], Data(repeating: 0, count: 11)),
            "bytes=12-21": (206, ["Content-Range": "bytes 12-21/22", "Content-Length": "10"], Data(repeating: 0, count: 10))
        ])
        do {
            _ = try await transport.download(prepared, in: directory, threads: 2, submit: nil)
            XCTFail("Mismatch in Content-Range was accepted")
        } catch {
            XCTAssertEqual(error as? ArchiveFileTransportError, .invalidResponse)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testArchiveSubmissionDenialMakesNoRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let transport = ArchiveFileTransport(maximumBytes: 100, configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        StubProtocol.state.reset([])
        do {
            _ = try await transport.download(preparedArchive(), in: directory, threads: 3, submit: { _ in
                throw AppError.staleSession
            })
            XCTFail("The gate denied submission")
        } catch {
            XCTAssertEqual(error as? AppError, .staleSession)
        }
        XCTAssertTrue(StubProtocol.state.captured().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testArchiveTotalRejectsOversizeAndDoesNotInventPercent() throws {
        XCTAssertEqual(try ArchiveTransferTotal.choose(responseLength:-1,contentLength:nil,
            estimate:nil,maximumBytes:100),ArchiveTransferTotal(bytes:nil,isEstimated:false))
        XCTAssertEqual(try ArchiveTransferTotal.choose(responseLength:-1,contentLength:"22",
            estimate:100,maximumBytes:100),ArchiveTransferTotal(bytes:22,isEstimated:false))
        XCTAssertThrowsError(try ArchiveTransferTotal.choose(responseLength:101,
            contentLength:nil,estimate:20,maximumBytes:100)) {
            XCTAssertEqual($0 as? ArchiveFileTransportError,.tooLarge)
        }
    }
    func testBoundedImageTransportLimitsKnownAndUnknownLength() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let transport = BoundedImageTransport(policy: policy, maximumBytes: 8, configuration: config)
        let request = request(url: "https://cdn.example.invalid/img", headers: ["Accept":"image/*"])
        for headers in [["Content-Length":"20"], [:]] {
            StubProtocol.state.reset([(200, headers, Data(repeating: 1, count: 20))])
            do { _ = try await transport.send(request: request); XCTFail("oversized body accepted") }
            catch { XCTAssertEqual(error as? AppError, .unsupportedContent) }
        }
        StubProtocol.state.reset([(200, ["Content-Type":"image/png"], Data([1,2,3,4]))])
        let response = try await transport.send(request: request)
        XCTAssertEqual(response.body, Data([1,2,3,4]))
        XCTAssertNil(StubProtocol.state.captured().first?.value(forHTTPHeaderField: "Cookie"))
    }
    func testBoundedImageRedirectsSameHostButRejectsAccountHost() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let transport = BoundedImageTransport(policy: policy, maximumBytes: 8, configuration: config)
        let request = request(url: "https://cdn.example.invalid/img", headers: ["Accept":"image/*"])
        StubProtocol.state.reset([(302, ["Location":"/next"], Data()), (200, ["Content-Type":"image/png"], Data([1]))])
        let response = try await transport.send(request: request)
        XCTAssertEqual(response.finalURL.path, "/next"); XCTAssertEqual(response.requestID, request.id)
        StubProtocol.state.reset([(302, ["Location":"https://eh.example.invalid/next"], Data())])
        do { _ = try await transport.send(request: request); XCTFail() } catch { XCTAssertEqual(error as? ReaderAccessFailure, ReaderAccessFailure(.redirectHost)) }
        XCTAssertEqual(StubProtocol.state.captured().count, 1)
    }
    func testApprovedMediaRedirectStripsHeadersForStaticAndPeerHosts() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let mediaPolicy = NetworkPolicy(parsing: policy.parsing, mediaHosts: ["cdn.example.invalid", "other.example.invalid"], allowHathReaderImages: true)
        let pairs = [("https://cdn.example.invalid/img", "https://other.example.invalid/img"),
                     ("https://peerabc.syntheticxyz.hath.network:8080/h/a/b", "https://peerdef.syntheticuvw.hath.network:11181/h/a/b")]
        for (source, target) in pairs {
            StubProtocol.state.reset([(302, ["Location":target], Data()), (200, ["Content-Type":"image/png"], Data([1]))])
            let transport = BoundedImageTransport(policy: mediaPolicy, maximumBytes: 8, configuration: config)
            let request = request(url: source, headers: ["Accept":"image/*", "X-Synthetic":"local-only", "Referer":"https://eh.example.invalid/synthetic"])
            let response = try await transport.send(request: request)
            XCTAssertEqual(response.finalURL.absoluteString, target)
            let sent = StubProtocol.state.captured(); XCTAssertEqual(sent.count, 2)
            XCTAssertNil(sent.last?.value(forHTTPHeaderField: "X-Synthetic"))
            XCTAssertNil(sent.last?.value(forHTTPHeaderField: "Referer"))
            XCTAssertNil(sent.last?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(sent.last?.value(forHTTPHeaderField: "Authorization"))
        }
    }
    func testMediaRedirectRejectsUnknownHostsDowngradesAndLoops() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let transport = BoundedImageTransport(policy: policy, maximumBytes: 8, configuration: config)
        let request = request(url: "https://cdn.example.invalid/img", headers: ["Accept":"image/*"])
        for target in ["https://unknown.example.invalid/img", "http://cdn.example.invalid/img", "https://cdn.example.invalid:444/img", "https://user:pass@cdn.example.invalid/img"] {
            StubProtocol.state.reset([(302, ["Location":target], Data())])
            do { _ = try await transport.send(request: request); XCTFail() }
            catch { XCTAssertEqual(error as? ReaderAccessFailure, ReaderAccessFailure(.redirectAddress)) }
            XCTAssertEqual(StubProtocol.state.captured().count, 1)
        }
        StubProtocol.state.reset(Array(repeating: (302, ["Location":"/img"], Data()), count: 4))
        do { _ = try await transport.send(request: request); XCTFail() }
        catch { XCTAssertEqual(error as? ReaderAccessFailure, ReaderAccessFailure(.redirectLimit)) }
        XCTAssertEqual(StubProtocol.state.captured().count, 4)
    }
    func testSearchExpressionRoundTripsOnBothSites() throws {
        for site in [Site.eh, .ex] {
            let target = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: site), generation: 1)
            for terms in ["two words", "中文", "日本語", "language:chinese", "\"quoted phrase\" -tag:excluded", "a+b & c% #fragment ?next=7", "  spaced  "] {
                let query = GalleryQuery(terms: terms)
                let request = try EndpointBuilder(policy: policy).list(GalleryListRequest(query: query, context: RequestContext(scope: target, queryID: UUID())))
                let parts = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(parts.host, site == .ex ? "ex.example.invalid" : "eh.example.invalid")
                XCTAssertNil(parts.fragment)
                XCTAssertEqual(parts.queryItems?.filter { $0.name == "f_search" }.count, 1)
                XCTAssertEqual(parts.queryItems?.first { $0.name == "f_search" }?.value, query.terms)
                XCTAssertFalse(parts.queryItems?.contains { $0.name == "next" } ?? true)
            }
        }
    }
    func testHathSpritesRequireOptInAndImageRequest() throws {
        let policy = NetworkPolicy(allowHathThumbnailSprites: true)
        let url = URL(string: "https://abcdefghij.hath.network/c2/syntheticSignature/42-0.webp")!
        XCTAssertThrowsError(try NetworkPolicy().validate(url, scope: scope, allowMedia: true))
        XCTAssertThrowsError(try policy.validate(url, scope: scope))
        XCTAssertNoThrow(try policy.validate(url, scope: scope, allowMedia: true))
        XCTAssertNoThrow(try policy.validate(request(url: url.absoluteString, headers: ["Accept":"image/*"])))
        XCTAssertThrowsError(try policy.validate(request(url: url.absoluteString)))
    }
    func testHathSpritePolicyRejectsLookalikesAndUnrelatedPaths() throws {
        let policy = NetworkPolicy(allowHathThumbnailSprites: true)
        for url in [
            "https://abcdefghij.hath.network.evil.invalid/c2/sig/42-0.webp",
            "https://sub.abcdefghij.hath.network/c2/sig/42-0.webp",
            "https://hath.network/c2/sig/42-0.webp",
            "https://abcdefghij.hath.network/fullimg/42.webp",
            "https://abcdefghij.hath.network/c2/sig/42-0.php",
            "https://abcdefghij.hath.network/c2/sig/42-0.webp?token=secret",
            "https://abcdefghij.hath.network/c2/sig/42-0.webp#fragment",
            "http://abcdefghij.hath.network/c2/sig/42-0.webp",
            "https://abcdefghij.hath.network:444/c2/sig/42-0.webp",
            "https://user:pass@abcdefghij.hath.network/c2/sig/42-0.webp"
        ] { XCTAssertThrowsError(try policy.validate(URL(string: url)!, scope: scope, allowMedia: true)) }
    }
    func testSourcesCursorAndEndpointIdentity() throws {
        let builder = EndpointBuilder(policy: policy), context = RequestContext(scope: scope,queryID: UUID())
        let popular = try builder.list(GalleryListRequest(query: GalleryQuery(terms: "ignored",source: .popular),context: context))
        XCTAssertEqual(popular.url.path,"/popular");XCTAssertEqual(popular.url.query, "inline_set=dm_l")
        let top = try builder.list(GalleryListRequest(query: GalleryQuery(source: .toplist(period: "15")),context: context));XCTAssertEqual(top.url.query,"tl=15")
        let cursor = PageCursor(context: context,opaque: try SensitiveText("url-v1:https://eh.example.invalid/?next=42&f_search=a%2Bb"))
        let next = try builder.list(GalleryListRequest(query: GalleryQuery(),context: context,cursor: cursor));XCTAssertEqual(next.url.query,"next=42&f_search=a%2Bb&inline_set=dm_l")
        let ref = try GalleryReference(key: GalleryKey(site: .eh,galleryID: GalleryID(42)),token: SensitiveText("synthetictoken"))
        let detail = try builder.detail(GalleryRequest(reference: ref,scope: scope),thumbnailPage: 2);XCTAssertEqual(detail.url.path,"/g/42/synthetictoken");XCTAssertEqual(detail.url.query,"p=2")
        let page = try ReaderPage(reference: ref,index: PageIndex(1),pageURL: URL(string: "https://eh.example.invalid/s/synthetic/42-2")!)
        let show = try builder.showPage(page,scope: scope,showKey: SensitiveText("synthetic-key"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: show.body!) as? [String:Any]);XCTAssertEqual(obj["page"] as? Int,2);XCTAssertEqual(show.method,.post)
        let changed = try builder.imagePage(page,scope: scope,sourceID: SensitiveText("a+b&c"));XCTAssertEqual(URLComponents(url: changed.url,resolvingAgainstBaseURL: false)?.queryItems?.first?.value,"a+b&c")
    }
    func testPolicyRejectsCredentialsAndForeignHosts() throws {
        XCTAssertTrue(policy.isLogin(URL(string:"https://eh.example.invalid/bounce_login.php?b=d")!))
        XCTAssertFalse(policy.isLogin(URL(string:"https://evil.invalid/bounce_login.php")!))
        for url in ["http://eh.example.invalid/","https://evil.invalid/","https://ex.example.invalid/","https://u:p@eh.example.invalid/","https://eh.example.invalid:444/"] { XCTAssertThrowsError(try policy.validate(request(url: url))) }
        for header in ["Cookie","Authorization","Host","Proxy-Authorization"] { XCTAssertThrowsError(try policy.validate(request(headers: [header:"synthetic"]))) }
        XCTAssertThrowsError(try EndpointBuilder(policy: policy).media(url: URL(string: "https://other.invalid/a.jpg")!,scope: scope))
        let media = try EndpointBuilder(policy: policy).media(url: URL(string: "https://cdn.example.invalid/a.jpg")!,scope: scope);XCTAssertNoThrow(try policy.validate(media))
    }
    func testResponseKindsStatusesAndSessionMismatch() throws {
        let req = request(), classifier = ResponseClassifier(policy: policy)
        for (status,error) in [(401,AppError.authenticationRequired),(403,.accessDenied),(404,.httpStatus(404)),(429,.rateLimited(retryAfter: 12)),(509,.quotaExceeded)] {
            XCTAssertThrowsError(try classifier.validate(response(req,status: status,extra: ["Retry-After":"12"]),request: req,kind: .html,now: .distantPast)) { XCTAssertEqual($0 as? AppError,error) }
        }
        XCTAssertThrowsError(try classifier.validate(response(req,scope: scope.advanced()),request: req,kind: .html,now: .distantPast)) { XCTAssertEqual($0 as? AppError,.staleSession) }
        XCTAssertThrowsError(try classifier.validate(response(req,status: 302,extra: ["Location":"https://forums.example.invalid/index.php?act=Login"]),request: req,kind: .html,now: .distantPast)) { XCTAssertEqual($0 as? AppError,.authenticationRequired) }
        XCTAssertThrowsError(try classifier.validate(response(req,mime: "image/jpeg"),request: req,kind: .image,now: .distantPast)) { XCTAssertEqual($0 as? AppError,.unsupportedContent) }
        XCTAssertThrowsError(try classifier.validate(response(req,mime: "application/json",body: "<html>error</html>"),request: req,kind: .json,now: .distantPast)) { XCTAssertEqual($0 as? AppError,.parseMismatch) }
        XCTAssertNoThrow(try classifier.validate(response(req,mime: "application/json",body: "{}"),request: req,kind: .json,now: .distantPast))
    }
    func testRetryAfterDateAndLimits() throws {
        XCTAssertEqual(ResponseClassifier.retryAfter("Thu, 01 Jan 1970 00:00:12 GMT",now: Date(timeIntervalSince1970: 0)),12)
        XCTAssertNil(ResponseClassifier.retryAfter("NaN",now: .distantPast));XCTAssertNil(ResponseClassifier.retryAfter("-1",now: .distantPast))
        XCTAssertNil(RetryPolicy().delay(request: request(),error: .rateLimited(retryAfter: 120),retries: 0))
        XCTAssertNil(RetryPolicy().delay(request: request(),error: .transport(code: -1200),retries: 0))
        XCTAssertNil(RetryPolicy().delay(request: request(url: "https://eh.example.invalid/?inline_set=dm_l"),error: .httpStatus(503),retries: 0))
    }
    func testFakeRetryScheduleAndBound() async throws {
        let req = request(), clock = FakeClock()
        let transport = try FakeTransport([.success(response(req,status: 503,extra: ["Retry-After":"3"])),.failure(.transport(code: -1001)),.success(response(req))])
        _ = try await HTTPClient(transport: transport,clock: clock,policy: policy).send(req,expecting: .html)
        let delays = await clock.delays, count = await transport.count;XCTAssertEqual(delays,[3,2]);XCTAssertEqual(count,3)
        let failed = FakeTransport(Array(repeating: .failure(.transport(code: -1001)),count: 4))
        do { _ = try await HTTPClient(transport: failed,clock: FakeClock(),policy: policy).send(req,expecting: .html);XCTFail() } catch { XCTAssertEqual(error as? AppError,.transport(code: -1001)) }
        let attempts = await failed.count;XCTAssertEqual(attempts,3)
    }
    func testMediaCallerCanOwnTransportRetryWithoutChangingDefaultPolicy() async throws {
        let transport=FakeTransport([.failure(.transport(code:-1001)),.failure(.transport(code:-1001))]), clock=FakeClock()
        do { _ = try await HTTPClient(transport:transport,clock:clock,policy:policy).send(request(),expecting:.html,retryTransportFailures:false); XCTFail() }
        catch { XCTAssertEqual(error as? AppError,.transport(code:-1001)) }
        let count=await transport.count, delays=await clock.delays
        XCTAssertEqual(count,1); XCTAssertTrue(delays.isEmpty)
    }
    func testPOSTAndTerminalErrorsNeverRetry() async throws {
        for (method,error) in [(HTTPMethod.post,AppError.transport(code: -1001)),(.post,.httpStatus(503)),(.get,.accessDenied),(.get,.quotaExceeded),(.get,.authenticationRequired)] {
            let transport = FakeTransport([.failure(error)]), clock = FakeClock()
            do { _ = try await HTTPClient(transport: transport,clock: clock,policy: policy).send(request(method: method),expecting: .html);XCTFail() } catch {}
            let count = await transport.count, delays = await clock.delays;XCTAssertEqual(count,1);XCTAssertTrue(delays.isEmpty)
        }
    }
    func testURLSessionWiringAndRedirectBoundary() async throws {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [StubProtocol.self]
        let transport = URLSessionTransport(policy: policy,configuration: config)
        StubProtocol.state.reset([(302,["Location":"/next","Set-Cookie":"synthetic=value; Secure; Path=/"],Data()),(200,["Content-Type":"text/html"],Data("<html>ok</html>".utf8))])
        let result = try await transport.send(request: request());XCTAssertEqual(result.finalURL.path,"/next")
        let captured = StubProtocol.state.captured();XCTAssertEqual(captured.count,2);XCTAssertNil(captured[0].value(forHTTPHeaderField: "Cookie"));XCTAssertNil(captured[1].value(forHTTPHeaderField: "Cookie"))
        StubProtocol.state.reset([(302,["Location":"https://ex.example.invalid/"],Data())])
        do { _ = try await transport.send(request: request());XCTFail() } catch { XCTAssertEqual(error as? AppError,.accessDenied) }
        XCTAssertEqual(StubProtocol.state.captured().count,1)
        StubProtocol.state.reset([(307,["Location":"/next"],Data())])
        let post = try await transport.send(request: request(method: .post));XCTAssertEqual(post.status,307);XCTAssertEqual(StubProtocol.state.captured().count,1)
    }
    func testThumbnailHashCookieIsScopedToGalleryReads() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let transport = URLSessionTransport(policy: policy, configuration: config, credentials: TestCredentials())
        let html: WireState.Reply = (200, ["Content-Type": "text/html"], Data("<html>ok</html>".utf8))
        StubProtocol.state.reset([(302, ["Location": "/s/synthetic/42-1"], Data()), html, html, html])
        let gallery = "https://eh.example.invalid/g/42/synthetic/?p=1"
        _ = try await transport.send(request: request(url: gallery))
        _ = try await transport.send(request: request(url: "https://eh.example.invalid/mpv/42/synthetic/"))
        _ = try await transport.send(request: request(method: .post, url: gallery))
        XCTAssertEqual(StubProtocol.state.captured().map { $0.value(forHTTPHeaderField: "Cookie") },
                       ["synthetic=initial; datatags=1", "synthetic=initial", "synthetic=initial", "synthetic=initial; datatags=0"])
    }

    func testCancellationAndGateRelease() async throws {
        let gate = RequestGate(limit: 1);try await gate.acquire()
        let waiting = Task { try await gate.acquire() }
        while await gate.waitingCount == 0 { await Task.yield() }
        waiting.cancel()
        do { try await waiting.value;XCTFail() } catch is CancellationError {} catch { XCTFail() }
        await gate.release();try await gate.acquire();await gate.release()
        let req = request(), transport = FakeTransport([]), client = HTTPClient(transport: transport,policy: policy)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await client.send(req,expecting: .html);XCTFail() } catch is CancellationError {} catch { XCTFail() }
        };await task.value
        let count = await transport.count;XCTAssertEqual(count,0)
    }
    func testCredentialProviderRechecksEachHopAndUnregisters() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let credentials = TestCredentials()
        let transport = URLSessionTransport(policy: policy, configuration: config, credentials: credentials)
        StubProtocol.state.reset([(302,["Location":"/next"],Data()),(200,["Content-Type":"text/html"],Data("<html>ok</html>".utf8))])
        _ = try await transport.send(request: request())
        let captured = StubProtocol.state.captured()
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "Cookie"), "synthetic=initial")
        XCTAssertEqual(captured[1].value(forHTTPHeaderField: "Cookie"), "synthetic=rotated")
        let responses = await credentials.responseCount, active = await credentials.active
        XCTAssertEqual(responses, 2); XCTAssertTrue(active.isEmpty)
        StubProtocol.state.reset([(302,["Location":"https://ex.example.invalid/"],Data())])
        do { _ = try await transport.send(request: request()); XCTFail() } catch AppError.accessDenied {} catch { XCTFail() }
        XCTAssertEqual(StubProtocol.state.captured().count, 1)
        let remaining = await credentials.active; XCTAssertTrue(remaining.isEmpty)
    }
}
