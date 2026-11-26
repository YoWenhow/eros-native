import Foundation
import Testing
import ErosCore
@testable import ErosNetworking

struct GalleryTitleAPITests {
    @Test(arguments: [Site.eh, Site.ex])
    func readsOnlyTheActiveSiteAndMatchesEachResponseByIDAndToken(_ site: Site) async throws {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: site), generation: 1)
        let first = try reference(42, "token-first", site: site)
        let second = try reference(43, "token-second", site: site)
        let missing = try reference(44, "token-missing", site: site)
        let transport = TitleAPITransport()
        let policy = NetworkPolicy(allowGalleryTitleReads: true)
        let titles = try await GalleryTitleAPI.load([first, second, missing], scope: scope,
            client: HTTPClient(transport: transport, policy: policy))
        #expect(titles[first] == GallerySourceTitles(gn: "A & B", gj: "日本語"))
        #expect(titles[second] == GallerySourceTitles(gn: "Other", gj: nil))
        #expect(titles[missing] == nil)
        let request = try #require(await transport.request)
        #expect(request.url.host == (site == .eh ? "api.e-hentai.org" : "exhentai.org"))
        #expect(throws: AppError.accessDenied) { try NetworkPolicy().validate(request) }

        let read = HTTPRequest(id: request.id, scope: scope,
            url: request.url.appending(queryItems: [URLQueryItem(name: "extra", value: "1")]),
            method: request.method, headers: request.headers, body: request.body)
        #expect(throws: AppError.accessDenied) { try policy.validate(read) }
        let write = HTTPRequest(id: request.id, scope: scope, url: request.url, method: .post,
            headers: request.headers, body: Data(#"{"method":"rategallery","gidlist":[[42,"token-first"]]}"#.utf8))
        #expect(throws: AppError.accessDenied) { try policy.validate(write) }
    }

    private func reference(_ id: Int64, _ token: String, site: Site) throws -> GalleryReference {
        try GalleryReference(key: GalleryKey(site: site, galleryID: GalleryID(id)), token: SensitiveText(token))
    }
}

private actor TitleAPITransport: HTTPTransport {
    private(set) var request: HTTPRequest?

    func send(request: HTTPRequest) throws -> HTTPResponse {
        self.request = request
        let body = """
            {"gmetadata":[
              {"gid":43,"token":"token-second","title":"Other","title_jpn":" "},
              {"gid":42,"token":"wrong","title":"Unrelated"},
              {"gid":44,"error":"Key missing"},
              {"gid":42,"token":"token-first","title":"A &amp; B","title_jpn":"&#26085;本語"}
            ]}
            """
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
            headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(body.utf8), finalURL: request.url)
    }
}
