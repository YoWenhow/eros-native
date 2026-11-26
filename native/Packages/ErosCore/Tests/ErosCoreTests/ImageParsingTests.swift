import Foundation
import XCTest
import ErosCore

@MainActor
final class ImageParsingTests: XCTestCase {
    let policy = ParsingPolicy(ehHost: "eh.example.invalid", exHost: "ex.example.invalid", forumHost: "forums.example.invalid")
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testCapturedReaderPagesFindMetadataAfterNavigation() throws {
        for site in [Site.eh, .ex] {
            let id = "image-captured-" + site.rawValue
            let capturedScope = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: site), generation: 1)
            let reference = GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(42)), token: try SensitiveText("synthetictoken"))
            let url = URL(string: "https://\(site.rawValue).example.invalid/s/syntheticimage/42-1")!
            let request = try ImageResolutionRequest(page: ReaderPage(reference: reference, index: PageIndex(0), pageURL: url), scope: capturedScope, reason: .initial)
            let response = try response(id, scope: capturedScope, url: url.absoluteString)
            let parsed = try ImagePageParser(policy: policy).parseDetailed(response, request: request, resolvedAt: .distantPast)
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: file("Expected/\(id).json")) as? [String: Any])
            let data = try XCTUnwrap(expected["data"] as? [String: Any])
            XCTAssertEqual(parsed.image.page.dimensions?.width, data["width"] as? Int)
            XCTAssertEqual(parsed.image.page.dimensions?.height, data["height"] as? Int)
            XCTAssertEqual(parsed.pageCount, data["pageCount"] as? Int)
            XCTAssertEqual(parsed.image.url.absoluteString, data["imageURL"] as? String)
            XCTAssertEqual(parsed.image.page.index.value, 0)
        }
    }
    func testReaderPeerPortParsingAndAmbiguousDimensions() throws {
        let original = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self)
        for port in [8080, 11181, 65535] {
            let url = "https://peerabc.syntheticxyz.hath.network:\(port)/h/synthetic/path/image.jpg"
            let body = original.replacingOccurrences(of: "https://cdn.example.invalid/image.jpg", with: url)
            let parsed = try htmlFromBody(body)
            XCTAssertEqual(parsed.image.url.port, port)
        }
        let duplicate = original.replacingOccurrences(of: "<div class=\"sn\">", with: "<div>other.jpg :: 2 x 3</div><div class=\"sn\">")
        assertError(.parseMismatch) { _ = try htmlFromBody(duplicate) }
        for url in ["http://peerabc.syntheticxyz.hath.network:8080/h/a/b", "https://peerabc.syntheticxyz.hath.network:1023/h/a/b", "https://peerabc.syntheticxyz.hath.network:65536/h/a/b", "https://cdn.example.invalid:8080/h/a/b"] {
            assertError(.parseMismatch) { _ = try htmlFromBody(original.replacingOccurrences(of: "https://cdn.example.invalid/image.jpg", with: url)) }
        }
    }
    private func htmlFromBody(_ body: String) throws -> ParsedImagePage {
        try ImagePageParser(policy: policy).parse(response("image-bootstrap", body: Data(body.utf8)), request: request(), resolvedAt: .distantPast)
    }
    func testDetailedFailureStagesDoNotChangeLegacyParserErrors() throws {
        let original = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self)
        let cases: [(String, ImageParseStage)] = [
            (original.replacingOccurrences(of: "id=\"i5\"", with: "id=\"missing\""), .gallery),
            (original.replacingOccurrences(of: "class=\"sn\"", with: "class=\"missing\""), .pagination),
            (original.replacingOccurrences(of: "800 x 1200", with: "unknown"), .dimensions),
            (original.replacingOccurrences(of: "id=\"img\"", with: "id=\"missing\""), .media)
        ]
        for (html, stage) in cases {
            let input = try response("image-bootstrap", body: Data(html.utf8))
            do { _ = try ImagePageParser(policy: policy).parseDetailed(input, request: request(), resolvedAt: Date()); XCTFail() }
            catch let error as ImagePageFailure { XCTAssertEqual(error.stage, stage) }
            do { _ = try ImagePageParser(policy: policy).parse(input, request: request(), resolvedAt: Date()); XCTFail() }
            catch { XCTAssertEqual(error as? AppError, .parseMismatch) }
        }
    }
    func request(_ index: Int = 0, reason: ImageResolutionReason = .initial, scope override: SessionScope? = nil) throws -> ImageResolutionRequest {
        let ref = GalleryReference(key: GalleryKey(site: .eh, galleryID: try GalleryID(42)), token: try SensitiveText("synthetictoken"))
        return try ImageResolutionRequest(page: ReaderPage(reference: ref, index: PageIndex(index), pageURL: URL(string: "https://eh.example.invalid/s/syntheticimage/42-\(index + 1)")!), scope: override ?? scope, reason: reason)
    }
    func file(_ path: String) throws -> Data {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: root.appendingPathComponent(path))
    }
    func response(_ id: String, status: Int = 200, body: Data? = nil, mime: String? = nil, scope override: SessionScope? = nil, url: String? = nil) throws -> HTTPResponse {
        let json = id.hasPrefix("showpage")
        return try HTTPResponse(requestID: UUID(), scope: override ?? scope, status: status,
            headers: ["Content-Type": mime ?? (json ? "application/json" : "text/html")],
            body: body ?? file((json ? "JSON/" : "HTML/") + id + (json ? ".json" : ".html")),
            finalURL: URL(string: url ?? (json ? "https://eh.example.invalid/api.php" : "https://eh.example.invalid/s/syntheticimage/42-1"))!)
    }
    func html(_ id: String = "image-bootstrap") throws -> ParsedImagePage {
        try ImagePageParser(policy: policy).parse(response(id), request: request(), resolvedAt: .distantPast)
    }
    func assertError(_ expected: AppError, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual($0 as? AppError, expected, file: file, line: line) }
    }
    func testSixGoldenFixtures() throws {
        for id in ["image-bootstrap", "image-no-showkey", "image-quota", "showpage-success", "showpage-key-mismatch", "showpage-bad-dimensions"] {
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: file("Expected/\(id).json")) as? [String: Any])
            func parse() throws -> ParsedImagePage {
                if id.hasPrefix("showpage") { return try ShowPageParser(policy: policy).parse(response(id), request: request(1), resolvedAt: .distantPast) }
                return try html(id)
            }
            if let code = expected["errorCode"] as? String {
                let error: AppError = code == "imageExpired" ? .imageExpired : code == "quotaExceeded" ? .quotaExceeded : .parseMismatch
                assertError(error) { _ = try parse() }; continue
            }
            let parsed = try parse(), data = try XCTUnwrap(expected["data"] as? [String: Any])
            let actual: [String: Any] = ["index": parsed.image.page.index.value, "imageURL": parsed.image.url.absoluteString,
                "width": parsed.image.page.dimensions!.width, "height": parsed.image.page.dimensions!.height,
                "pageCount": parsed.pageCount as Any? ?? NSNull(), "showKey": parsed.showKey?.value as Any? ?? NSNull(),
                "sourceID": parsed.sourceID?.value as Any? ?? NSNull(), "nextStrategy": parsed.showKey == nil ? "html-bootstrap" : "showpage"]
            for (key, value) in data { XCTAssertEqual(actual[key] as? NSObject, value as? NSObject, "\(id):\(key)") }
            XCTAssertEqual(parsed.image.headers, [:])
        }
    }
    func testBootstrapMissingKeyAndChangedKey() throws {
        var flow = try ImageResolutionPolicy(request: request(), parsing: policy)
        guard case .html = try flow.start() else { return XCTFail() }
        _ = try flow.accept(response("image-no-showkey"), resolvedAt: .distantPast)
        XCTAssertNil(flow.context?.showKey)
        var next = try ImageResolutionPolicy(request: request(), context: flow.context, parsing: policy)
        guard case .html = try next.start() else { return XCTFail() }
        let changed = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self).replacingOccurrences(of: "syntheticshowkey", with: "syntheticnewkey")
        _ = try next.accept(response("image-bootstrap", body: Data(changed.utf8)), resolvedAt: .distantPast)
        XCTAssertEqual(next.context?.showKey?.value, "syntheticnewkey")
        assertError(.invalidInput) { _ = try next.start() }
    }
    func testAPISuccessPreservesKeyAndStableIdentity() throws {
        var flow = try ImageResolutionPolicy(request: request(1), context: ImageResolutionContext(parsed: html()), parsing: policy)
        guard case let .showPage(url, body) = try flow.start() else { return XCTFail() }
        XCTAssertEqual(url.path, "/api.php")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["page"] as? Int, 2); XCTAssertEqual(obj["imgkey"] as? String, "syntheticimage")
        XCTAssertEqual(obj["showkey"] as? String, "syntheticshowkey")
        let parsed = try flow.accept(response("showpage-success"), resolvedAt: .distantPast)
        XCTAssertEqual(parsed.image.page.id, try request(1).page.id)
        XCTAssertEqual(flow.context?.showKey?.value, "syntheticshowkey")
        XCTAssertEqual(flow.attempts, 1)
    }
    func testUnsupportedAPIUsesOneHTMLFallbackButUnsupportedHTMLIsTerminal() throws {
        var flow = try ImageResolutionPolicy(request: request(), context: ImageResolutionContext(parsed: html()), parsing: policy)
        guard case .showPage = try flow.start() else { return XCTFail() }
        guard case .html = try flow.recover(from: .unsupportedContent) else { return XCTFail() }
        assertError(.unsupportedContent) { _ = try flow.recover(from: .unsupportedContent) }
        XCTAssertEqual(flow.attempts, 2)
        var htmlOnly = try ImageResolutionPolicy(request: request(), parsing: policy)
        _ = try htmlOnly.start()
        assertError(.unsupportedContent) { _ = try htmlOnly.recover(from: .unsupportedContent) }
    }
    func testKeyMismatchAndForbiddenFallbackAreBounded() throws {
        for error in [AppError.imageExpired, .accessDenied] {
            var flow = try ImageResolutionPolicy(request: request(), context: ImageResolutionContext(parsed: html()), parsing: policy)
            _ = try flow.start()
            let failed = try response("showpage-key-mismatch", status: error == .accessDenied ? 403 : 200)
            assertError(error) { _ = try flow.accept(failed, resolvedAt: .distantPast) }
            guard case .html = try flow.recover(from: error) else { return XCTFail() }
            XCTAssertNil(flow.context)
            assertError(.accessDenied) { _ = try flow.accept(response("image-bootstrap", status: 403), resolvedAt: .distantPast) }
            assertError(.accessDenied) { _ = try flow.recover(from: .accessDenied) }
            assertError(.invalidInput) { _ = try flow.recover(from: .imageExpired) }
            XCTAssertEqual(flow.attempts, 2)
        }
    }
    func testExpiredURLAndSourceChangeUseHTML() throws {
        let context = try ImageResolutionContext(parsed: html())
        for reason in [ImageResolutionReason.expiredURL, .invalidShowKey, .changeSource, .retryDownloadSource] {
            var flow = try ImageResolutionPolicy(request: request(reason: reason), context: context, parsing: policy)
            guard case let .html(url) = try flow.start() else { return XCTFail() }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let selectsNode = reason == .changeSource || reason == .retryDownloadSource
            XCTAssertEqual(items?.first(where: { $0.name == "nl" })?.value, selectsNode ? "syntheticsource" : nil)
            _ = try flow.accept(response("image-bootstrap"), resolvedAt: .distantPast)
            XCTAssertEqual(flow.context?.sourceID?.value, "syntheticsource")
        }
        var wrongPage = try ImageResolutionPolicy(request: request(1, reason: .changeSource), context: context, parsing: policy)
        assertError(.invalidInput) { _ = try wrongPage.start() }
        var retryAnotherPage = try ImageResolutionPolicy(request: request(1, reason: .retryDownloadSource), context: context, parsing: policy)
        guard case let .html(url) = try retryAnotherPage.start() else { return XCTFail() }
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "nl" }))

        let requested = try request(reason: .retryDownloadSource)
        var parts = try XCTUnwrap(URLComponents(url: requested.page.pageURL, resolvingAgainstBaseURL: false))
        parts.queryItems = [URLQueryItem(name: "nl", value: "stale"), URLQueryItem(name: "other", value: "preserved")]
        let page = try ReaderPage(reference: requested.page.reference, index: requested.page.index, pageURL: XCTUnwrap(parts.url))
        let retry = try ImageResolutionRequest(page: page, scope: scope, reason: .retryDownloadSource)
        var noKey = try ImageResolutionPolicy(request: retry, context: nil, parsing: policy)
        guard case let .html(clean) = try noKey.start() else { return XCTFail() }
        XCTAssertEqual(URLComponents(url: clean, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "other", value: "preserved")])
    }
    func testSessionInvalidationAndTerminalErrors() throws {
        let context = try ImageResolutionContext(parsed: html())
        var flow = try ImageResolutionPolicy(request: request(scope: scope.advanced()), context: context, parsing: policy)
        guard case .html = try flow.start() else { return XCTFail() }
        assertError(.staleSession) { _ = try flow.accept(response("image-bootstrap"), resolvedAt: .distantPast) }
        for error in [AppError.quotaExceeded, .authenticationRequired, .rateLimited(retryAfter: nil), .cancelled, .parseMismatch] {
            var flow = try ImageResolutionPolicy(request: request(), context: context, parsing: policy)
            _ = try flow.start()
            assertError(error) { _ = try flow.recover(from: error) }
            XCTAssertEqual(flow.attempts, 1); XCTAssertNil(flow.context)
        }
    }
    func testMalformedIdentityAndMediaGuards() throws {
        let original = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self)
        for (from, to) in [("/g/42/", "/g/43/"), ("<span>1</span>", "<span>2</span>"), ("800 x 1200", "0 x 1200"), ("https://cdn.example.invalid/image.jpg", "javascript:alert(1)"), ("id=\"img\"", "id=\"other\"")] {
            assertError(.parseMismatch) { _ = try ImagePageParser(policy: policy).parse(response("image-bootstrap", body: Data(original.replacingOccurrences(of: from, with: to).utf8)), request: request(), resolvedAt: .distantPast) }
        }
        assertError(.parseMismatch) { _ = try ShowPageParser(policy: policy).parse(response("showpage-success"), request: request(), resolvedAt: .distantPast) }
        for bad in ["true", "0", "1.5", "-1", "1e300"] {
            var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: file("JSON/showpage-success.json")) as? [String: Any])
            obj["x"] = try JSONSerialization.jsonObject(with: Data(bad.utf8), options: [.fragmentsAllowed])
            assertError(.parseMismatch) { _ = try ShowPageParser(policy: policy).parse(response("showpage-success", body: JSONSerialization.data(withJSONObject: obj)), request: request(1), resolvedAt: .distantPast) }
        }
    }
    func testHTMLIsNeverAcceptedAsDownloadedImage() throws {
        for mime in ["text/html", "application/json", "image/jpeg"] {
            assertError(.unsupportedContent) { try ImageResolutionPolicy.validateImageResponse(response("image-bootstrap", mime: mime), scope: scope) }
        }
        for (status, error) in [(403, AppError.imageExpired), (410, .imageExpired), (509, .quotaExceeded), (401, .authenticationRequired)] {
            assertError(error) { try ImageResolutionPolicy.validateImageResponse(response("image-bootstrap", status: status), scope: scope) }
        }
        assertError(.unsupportedContent) { _ = try ShowPageParser(policy: policy).parse(response("showpage-success", mime: "text/html"), request: request(1), resolvedAt: .distantPast) }
    }
    func testOriginalLinkOptionalSourceAndJSONQuota() throws {
        let base = String(decoding: try file("HTML/image-bootstrap.html"), as: UTF8.self)
        let modified = base.replacingOccurrences(of: "</body>", with: "<a href='/fullimg.php?gid=42&amp;page=1'>Original</a></body>")
            .replacingOccurrences(of: "return nl('syntheticsource')", with: "")
        let parsed = try ImagePageParser(policy: policy).parse(response("image-bootstrap", body: Data(modified.utf8)), request: request(), resolvedAt: .distantPast)
        XCTAssertEqual(parsed.originalURL?.absoluteString, "https://eh.example.invalid/fullimg.php?gid=42&page=1")
        XCTAssertNil(parsed.sourceID)
        let json = String(decoding: try file("JSON/showpage-success.json"), as: UTF8.self).replacingOccurrences(of: "image.jpg", with: "509s.gif")
        assertError(.quotaExceeded) { _ = try ShowPageParser(policy: policy).parse(response("showpage-success", body: Data(json.utf8)), request: request(1), resolvedAt: .distantPast) }
        for status in [401, 429, 509] {
            let expected: AppError = status == 401 ? .authenticationRequired : status == 429 ? .rateLimited(retryAfter: nil) : .quotaExceeded
            assertError(expected) { _ = try ShowPageParser(policy: policy).parse(response("showpage-success", status: status), request: request(1), resolvedAt: .distantPast) }
        }
        assertError(.authenticationRequired) { _ = try ImagePageParser(policy: policy).parse(response("image-bootstrap", url: "https://forums.example.invalid/index.php?act=Login"), request: request(), resolvedAt: .distantPast) }
        let otherAccount = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        var flow = try ImageResolutionPolicy(request: request(scope: otherAccount), context: ImageResolutionContext(parsed: html()), parsing: policy)
        guard case .html = try flow.start() else { return XCTFail() }
    }
    func testCancellationPropagatesWithoutRetry() async throws {
        let response = try response("image-bootstrap"), request = try request(), parsing = policy
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var flow = try ImageResolutionPolicy(request: request, parsing: parsing)
            do { _ = try flow.start(); XCTFail("cancelled start succeeded") } catch is CancellationError {} catch { XCTFail("wrong cancellation error") }
            do { _ = try ImagePageParser(policy: parsing).parse(response, request: request, resolvedAt: .distantPast); XCTFail("cancelled parse succeeded") } catch is CancellationError {} catch { XCTFail("wrong cancellation error") }
        }
        try await task.value
    }
}
