import Foundation
import ErosCore
import ErosNetworking
import ErosPersistence
import ErosServices

public struct FixtureScenario: Sendable {
    public let delay: TimeInterval
    public let paginationFailure: Bool
    public let authenticationExpired: Bool
    public let invalidShowKey: Bool
    public let emptyList: Bool
    public let listFailure: Bool
    public init(delay: TimeInterval = 0, paginationFailure: Bool = false, authenticationExpired: Bool = false, invalidShowKey: Bool = false, emptyList: Bool = false, listFailure: Bool = false) {
        self.delay = min(30,max(0,delay.isFinite ? delay : 0));self.paginationFailure = paginationFailure
        self.authenticationExpired = authenticationExpired;self.invalidShowKey = invalidShowKey
        self.emptyList = emptyList;self.listFailure = listFailure
    }
}

/// Deliberately shipped offline demonstration data, separate from T11 test fixtures.
/// No URLSession or network fallback exists in this target.
public actor FixtureTransport: HTTPTransport {
    public static let policy = NetworkPolicy(parsing: ParsingPolicy(ehHost: "eh.demo.invalid",exHost: "ex.demo.invalid",forumHost: "forums.demo.invalid"),mediaHosts: ["media.demo.invalid"])
    private var scenario: FixtureScenario
    private let clock: any Clock
    public private(set) var requestCount = 0
    public init(scenario: FixtureScenario = FixtureScenario(),clock: any Clock = SystemNetworkClock()) { self.scenario = scenario;self.clock = clock }
    public func configure(_ scenario: FixtureScenario) { self.scenario = scenario }
    private func resource(_ name: String) throws -> Data {
        guard let root = Bundle.module.url(forResource: "Resources",withExtension: nil) else { throw AppError.notFound }
        return try Data(contentsOf: root.appendingPathComponent(name))
    }
    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        try Self.policy.validate(request);try Task.checkCancellation()
        requestCount += 1
        let behavior = scenario
        if behavior.delay > 0 { try await clock.sleep(seconds: behavior.delay) }
        try Task.checkCancellation()
        func response(_ body: Data, _ mime: String = "text/html", _ status: Int = 200) throws -> HTTPResponse {
            try HTTPResponse(requestID: request.id,scope: request.scope,status: status,headers: ["Content-Type":mime],body: body,finalURL: request.url)
        }
        if behavior.authenticationExpired { return try response(Data(),"text/html",401) }
        let path = request.url.path
        if request.url.host == "media.demo.invalid" {
            guard request.method == .get, ["/page1.png","/page2.png","/page3.png"].contains(path) else { throw AppError.notFound }
            return try response(resource(String(path.dropFirst())),"image/png")
        }
        if path == "/" || path == "/watched" || path == "/popular" {
            guard request.method == .get else { throw AppError.invalidInput }
            if behavior.listFailure { throw AppError.transport(code: -1009) }
            let terms = URLComponents(url: request.url,resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "f_search" }?.value ?? ""
            if behavior.emptyList || (!terms.isEmpty && !"离线示例 三色页 日本語".localizedCaseInsensitiveContains(terms)) {
                return try response(Data("<html><body><div id='nb'></div><div class='ido'><div id='toppane'></div><div id='searchbox'><form><input name='f_search'></form></div><div><p>No hits found</p></div></div></body></html>".utf8))
            }
            let second = URLComponents(url: request.url,resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "page" && $0.value == "1" } == true
            if second && behavior.paginationFailure { throw AppError.parseMismatch }
            return try response(resource(second ? "list-last.html" : "list-first.html"))
        }
        if path == "/g/42/demotoken" || path == "/g/42/demotoken/" { return try response(resource("detail.html")) }
        if path.hasPrefix("/s/demoimage/42-"), let page = Int(path.split(separator: "-").last ?? ""), (1...3).contains(page) {
            return try response(resource("image\(page).html"))
        }
        if path == "/api.php", request.method == .post, let body = request.body,
           let object = try JSONSerialization.jsonObject(with: body) as? [String:Any], object["method"] as? String == "showpage",
           object["gid"] as? Int == 42, object["imgkey"] as? String == "demoimage", let page = object["page"] as? Int, (1...3).contains(page) {
            if behavior.invalidShowKey || object["showkey"] as? String != "demoshowkey" {
                return try response(Data(#"{"error":"Key mismatch"}"#.utf8),"application/json")
            }
            return try response(resource("showpage\(page).json"),"application/json")
        }
        throw AppError.notFound
    }
}

public struct FixtureGalleryRepository: GalleryRepository {
    private let base: LiveGalleryRepository
    public init(transport: FixtureTransport, sessions: any SessionProvider, clock: any Clock = SystemNetworkClock()) {
        base = LiveGalleryRepository(client: HTTPClient(transport: transport,clock: clock,policy: FixtureTransport.policy),sessions: sessions,policy: FixtureTransport.policy)
    }
    public func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> { try await base.list(request: request) }
    public func detail(request: GalleryRequest) async throws -> GalleryDetail { try await base.detail(request: request) }
    public func thumbnails(request: ReaderPagesRequest) async throws -> PagedResult<GalleryThumbnail> { try await base.thumbnails(request: request) }
    public func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { try await base.readerPages(request: request) }
}

extension AppContainer {
    public static func offline(databaseURL: URL, sessions: any SessionProvider, transport: FixtureTransport = FixtureTransport()) async throws -> AppContainer {
        let db = try await SQLiteDatabase.open(url: databaseURL)
        let client = HTTPClient(transport: transport,policy: FixtureTransport.policy)
        return AppContainer(galleries: FixtureGalleryRepository(transport: transport,sessions: sessions),images: LiveImagePageResolver(client: client,sessions: sessions,policy: FixtureTransport.policy),sessions: sessions,client: client,database: db)
    }
}
