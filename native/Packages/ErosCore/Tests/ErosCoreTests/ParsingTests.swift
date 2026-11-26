import Foundation
import XCTest
import ErosCore

@MainActor
final class ParsingTests: XCTestCase {
    private let policy = ParsingPolicy(ehHost: "eh.example.invalid", exHost: "ex.example.invalid", forumHost: "forums.example.invalid")
    private struct Fixture {
        let response: HTTPResponse
        let context: RequestContext
        let expected: [String: Any]
        let html: String
    }
    private func load(_ id: String) throws -> Fixture {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["fixtures"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { $0["id"] as? String == id })
        let request = try XCTUnwrap(entry["request"] as? [String: Any])
        let info = try XCTUnwrap(entry["response"] as? [String: Any])
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), site: request["site"] as? String == "ex" ? .ex : .eh), generation: 1)
        let context = RequestContext(scope: scope, queryID: UUID())
        let body = try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(entry["input"] as? String)))
        let response = try HTTPResponse(requestID: UUID(), scope: scope,
            status: XCTUnwrap(info["status"] as? Int), headers: XCTUnwrap(info["headers"] as? [String: String]),
            body: body, finalURL: XCTUnwrap(URL(string: XCTUnwrap(info["finalURL"] as? String))))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(entry["expected"] as? String)))) as? [String: Any])
        return Fixture(response: response, context: context, expected: expected, html: try XCTUnwrap(String(data: body, encoding: .utf8)))
    }
    func testDetailTitlePresentationPreservesParserAndLegacyCacheContracts() throws {
        let fixture = try load("detail-basic")
        let detail = try GalleryDetailParser(policy: policy).parse(fixture.response, reference: ref())
        let titles = DetailTitlePresentation(sourceTitles: detail.sourceTitles, fallbackTitle: detail.summary.title)
        XCTAssertEqual(titles.primary, "合成原題")
        XCTAssertEqual(titles.secondary, "Synthetic title")
        XCTAssertEqual(detail.summary.title, "Synthetic title")
        XCTAssertEqual(detail.sourceTitles?.gn, "Synthetic title")
        XCTAssertEqual(detail.sourceTitles?.gj, "合成原題")
        XCTAssertEqual(detail.summary.sourceTitles, detail.sourceTitles)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        legacy.removeValue(forKey: "sourceTitles")
        legacy["originalTitle"] = "Unverified old original field"
        legacy["translatedTitle"] = "Unverified old translated field"
        let restored = try JSONDecoder().decode(GalleryDetail.self, from: JSONSerialization.data(withJSONObject: legacy))
        let fallback = DetailTitlePresentation(sourceTitles: restored.sourceTitles, fallbackTitle: restored.summary.title)
        XCTAssertNil(restored.sourceTitles)
        XCTAssertEqual(fallback.primary, "Synthetic title")
        XCTAssertNil(fallback.secondary)
        XCTAssertEqual(restored.originalTitle, "Unverified old original field")
        XCTAssertEqual(restored.translatedTitle, "Unverified old translated field")
    }

    private func ref(_ site: Site = .eh) throws -> GalleryReference {
        GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(42)), token: try SensitiveText("synthetictoken"))
    }
    private func response(_ fixture: Fixture, html: String? = nil, url: String? = nil,
                          status: Int? = nil, headers: [String: String]? = nil, scope: SessionScope? = nil) throws -> HTTPResponse {
        try HTTPResponse(requestID: fixture.response.requestID, scope: scope ?? fixture.response.scope,
            status: status ?? fixture.response.status, headers: headers ?? fixture.response.headers,
            body: html.map { Data($0.utf8) } ?? fixture.response.body,
            finalURL: url.flatMap(URL.init(string:)) ?? fixture.response.finalURL)
    }
    private func assertSubset(_ actual: Any, _ expected: Any, path: String = "", file: StaticString = #filePath, line: UInt = #line) {
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { XCTFail("object mismatch at \(path)", file: file, line: line); return }
            for (key, value) in expected {
                guard let found = actual[key] else { XCTFail("missing \(path).\(key)", file: file, line: line); continue }
                assertSubset(found, value, path: path + "." + key, file: file, line: line)
            }
        } else if let expected = expected as? [Any] {
            guard let actual = actual as? [Any] else { XCTFail("array mismatch \(path)", file: file, line: line); return }
            XCTAssertEqual(actual.count, expected.count, path, file: file, line: line)
            for (a, b) in zip(actual, expected) { assertSubset(a, b, path: path, file: file, line: line) }
        } else {
            XCTAssertEqual(actual as? NSObject, expected as? NSObject, path, file: file, line: line)
        }
    }
    private func summary(_ item: GallerySummary) -> [String: Any] {
        ["galleryID": item.reference.key.galleryID.value, "token": item.reference.token.value,
         "title": item.title, "coverURL": item.coverURL?.absoluteString as Any? ?? NSNull(),
         "category": item.category as Any? ?? NSNull(), "pageCount": item.pageCount?.value as Any? ?? NSNull(),
         "rating": item.rating as Any? ?? NSNull(), "uploader": item.uploader as Any? ?? NSNull()]
    }
    func testSearchTotalMetadataAcrossListLayoutsAndLegacyDecoding() throws {
        for id in ["list-numeric-first", "list-thumbnail-captured"] {
            let fixture = try load(id)
            let html = fixture.html.replacingOccurrences(of: "</body>", with: "<div class='searchtext'><p>Found about <strong>232,805</strong> results. Search options</p></div></body>")
            let page = try GalleryListParser(policy: policy).parse(response(fixture, html: html), context: fixture.context)
            XCTAssertEqual(page.totalCount, .approximate(232805))
            let data = try JSONEncoder().encode(page)
            XCTAssertEqual(try JSONDecoder().decode(PagedResult<GallerySummary>.self, from: data).totalCount, .approximate(232805))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "totalCount")
            XCTAssertNil(try JSONDecoder().decode(PagedResult<GallerySummary>.self, from: JSONSerialization.data(withJSONObject: object)).totalCount)
        }
        let empty = try load("list-empty-captured")
        XCTAssertEqual(try GalleryListParser(policy: policy).parse(empty.response, context: empty.context).totalCount, .exact(0))
    }
    func testResultCountPreservesServerPrecisionAndRejectsUnknownText() {
        let samples: [(String, GalleryResultCount)] = [
            ("Found 1,465,200 results.", .exact(1465200)),
            ("Found 1 result.", .exact(1)),
            ("Found about 232,805 results.", .approximate(232805)),
            ("Found 50,000+ results.", .atLeast(50000)),
            ("Found hundreds of results.", .hundreds),
            ("Found thousands of results.", .thousands),
            ("Found many results.", .many),
            ("Found 250,000+ results (estimated).", .atLeast(250000)),
            ("FOUND ABOUT 382,000 RESULTS", .approximate(382000)),
            ("about 743", .approximate(743)),
            ("about 10985", .approximate(10985)),
            ("Found about 10,985 results.", .approximate(10985)),
            ("Found at least 100,000 results.", .atLeast(100000)),
            ("Found tens of thousands of results. Search options", .tensOfThousands),
            ("Found hundreds of thousands of results", .hundredsOfThousands)]
        for (text, expected) in samples { XCTAssertEqual(GalleryResultCount.parse(text), expected) }
        for text in ["25 results per page", "Found -1 results.", "Found 12,34 results.", "Found 99999999999999999999999999 results.", "Unknown count"] {
            XCTAssertNil(GalleryResultCount.parse(text))
        }
        XCTAssertEqual(GalleryResultCount.approximate(123).displayText, "约 123 项")
    }
    func testCapturedFavoritesForBothSites() throws {
        for site in [Site.eh, .ex] {
            let name = site == .eh ? "eh" : "ex"
            let list = try load("favorites-captured-\(name)-list")
            let parser = FavoritesParser(policy: policy)
            XCTAssertEqual(try parser.groups(list.response, context: list.context).count, 10)
            let result = try parser.list(list.response, request: FavoritesListRequest(groupID: nil, context: list.context))
            XCTAssertEqual(result.items.count, 1)
            XCTAssertEqual(result.items.first?.reference.key.galleryID.value, 42)
            for kind in ["add", "edit"] {
                let f = try load("favorites-captured-\(name)-\(kind)")
                let request = try GalleryRequest(reference: try ref(site), scope: f.context.scope)
                let parsed = try parser.popup(f.response, request: request)
                XCTAssertEqual(parsed.groups.count, 10)
                XCTAssertEqual(parsed.isFavorite, kind == "edit")
                XCTAssertEqual(parsed.selectedGroup, kind == "edit" ? "0" : nil)
                XCTAssertEqual(parsed.fields["update"], "1")
                XCTAssertNotNil(parsed.fields["apply"])
                XCTAssertThrowsError(try parser.popup(response(f, url: "https://evil.example.invalid/gallerypopups.php?gid=42&t=synthetictoken&act=addfav"), request: request))
                XCTAssertThrowsError(try parser.popup(response(f, html: f.html.replacingOccurrences(of: "action=\"\"", with: "action=\"https://evil.example.invalid/\"")), request: request))
                XCTAssertThrowsError(try parser.popup(response(f, html: f.html.replacingOccurrences(of: "value=\"9\"", with: "value=\"0\"")), request: request))
            }
        }
    }
    func testFavoritesAcceptLinksFromThePairedSiteAndOpenOnTheSelectedSite() throws {
        for (site, other) in [("eh", "ex"), ("ex", "eh")] {
            let f = try load("favorites-captured-\(site)-list")
            let active = f.context.scope.storage.site
            let currentHost = policy.host(for: active)
            let otherHost = policy.host(for: active == .eh ? .ex : .eh)
            let html = f.html.replacingOccurrences(of: currentHost + "/g/", with: otherHost + "/g/")
            XCTAssertNotEqual(html, f.html, other)
            let page = try response(f, html: html)
            let items = try FavoritesParser(policy: policy).list(page,
                request: FavoritesListRequest(groupID: nil, context: f.context)).items
            XCTAssertEqual(items.map { $0.reference.key.site }, [active])
            XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(page, context: f.context))
        }
    }
    func testFavoriteTitleSearchRecognizesNoHitsInAPopulatedCategory() throws {
        let fixture = try load("favorites-captured-eh-list")
        let groups = (0...9).map { number in
            """
            <div class="fp" onclick="document.location='/favorites.php?favcat=\(number)&amp;f_search=sample'">
            <div>12</div><div></div><div>Group \(number)</div>
            </div>
            """
        }.joined()
        let page = """
            <html><body><div class="ido"><div class="nosel">\(groups)</div>
            <div><p>No hits found</p></div></div></body></html>
            """
        let response = try response(fixture, html: page)
        let parser = FavoritesParser(policy: policy)
        let filtered = try FavoritesListRequest(groupID: "2", titleQuery: "sample", context: fixture.context)
        let result = try parser.list(response, request: filtered)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.next)
        XCTAssertThrowsError(try parser.list(response,
            request: FavoritesListRequest(groupID: "2", context: fixture.context)))
    }
    func testListDisplayMetadataPreservesOrderAndUTCAndOldPayloads() throws {
        let f = try load("list-numeric-first")
        let html = f.html.replacingOccurrences(of: "<div class=\"gt\">synthetic</div>", with: "<div class=\"gt\" title=\"language:chinese\">chinese</div><div class=\"gtl\" title=\"artist:sample name\">sample name</div><div class=\"gt\">plain tag</div>")
        let item = try XCTUnwrap(GalleryListParser(policy: policy).parse(response(f, html: html), context: f.context).items.first)
        XCTAssertEqual(item.listTags, [TagGroup(namespace: "language", tags: ["chinese"]), TagGroup(namespace: "artist", tags: ["sample name"]), TagGroup(namespace: nil, tags: ["plain tag"])])
        XCTAssertEqual(item.postedAt?.timeIntervalSince1970, 1577836800)
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(GallerySummary.self, from: data), item)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "listTags"); old.removeValue(forKey: "postedAt")
        let restored = try JSONDecoder().decode(GallerySummary.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.listTags); XCTAssertNil(restored.postedAt)
        XCTAssertEqual(restored.reference, item.reference)
        let malformed = html.replacingOccurrences(of: "2020-01-01 00:00", with: "unknown date")
        XCTAssertNil(try GalleryListParser(policy: policy).parse(response(f, html: malformed), context: f.context).items.first?.postedAt)
    }
    func testThumbnailListDisplayMetadataIsOptional() throws {
        let f = try load("list-thumbnail-captured")
        let items = try GalleryListParser(policy: policy).parse(f.response, context: f.context).items
        XCTAssertFalse(items.isEmpty)
        XCTAssertNil(items.first?.postedAt) // Captured thumbnail mode does not include dates.
        let html = f.html.replacingOccurrences(of: "<div class=\"glnew\"></div>", with: "<div class=\"glnew\">2020-01-01 00:00</div>")
        let enriched = try GalleryListParser(policy: policy).parse(response(f, html: html), context: f.context)
        XCTAssertEqual(enriched.items.first?.postedAt?.timeIntervalSince1970, 1577836800)
    }
    func testNumericAndCursorListsAgainstGoldenProjections() throws {
        for id in ["list-numeric-first", "list-numeric-middle", "list-numeric-last", "list-cursor", "list-cursor-terminal", "list-lazy-missing-metadata", "list-duplicate", "list-thumbnail-captured"] {
            let f = try load(id)
            let parsed = try GalleryListParser(policy: policy).parse(f.response, context: f.context)
            try parsed.validate(current: f.context)
            let duplicates = Dictionary(grouping: parsed.items, by: \.id).filter { $0.value.count > 1 }.keys.map(\.galleryID.value).sorted()
            let actual: [String: Any] = [
                "items": parsed.items.map(summary), "duplicateGalleryIDs": duplicates,
                "nextHref": try parsed.next.map { try policy.navigationURL(cursor: $0, context: f.context).absoluteString } as Any? ?? NSNull(),
                "previousHref": try parsed.previous.map { try policy.navigationURL(cursor: $0, context: f.context).absoluteString } as Any? ?? NSNull()
            ]
            var expected = try XCTUnwrap(f.expected["data"] as? [String: Any])
            for key in ["nextHref", "previousHref"] {
                if let href = expected[key] as? String { expected[key] = URL(string: href, relativeTo: f.response.finalURL)?.absoluteURL.absoluteString }
            }
            assertSubset(actual, expected, path: id)
        }
    }
    func testThumbnailGridRejectsMalformedAndForeignReferences() throws {
        let f = try load("list-thumbnail-captured")
        for html in [f.html.replacingOccurrences(of: "gl4t glname glink", with: "unknown-title"),
                     f.html.replacingOccurrences(of: "/g/1/synthetic1/", with: "/g/invalid/synthetic1/"),
                     f.html.replacingOccurrences(of: "class=\"gl1t\"", with: "class=\"unknown-card\"")] {
            XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, html: html), context: f.context)) {
                XCTAssertEqual($0 as? AppError, .parseMismatch)
            }
        }
        let foreign = f.html.replacingOccurrences(of: "/g/1/synthetic1/", with: "https://foreign.example.invalid/g/1/synthetic1/")
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, html: foreign), context: f.context)) {
            XCTAssertEqual($0 as? AppError, .accessDenied)
        }
    }
    func testThumbnailMissingOptionalMetadataAndTerminalCursor() throws {
        let f = try load("list-thumbnail-captured")
        let html = f.html.replacingOccurrences(of: "class=\"ir\"", with: "class=\"no-rating\"")
            .replacingOccurrences(of: " pages", with: " unknown")
            .replacingOccurrences(of: "href=\"/?next=26\"", with: "")
        let result = try GalleryListParser(policy: policy).parse(response(f, html: html), context: f.context)
        XCTAssertEqual(result.items.count, 25); XCTAssertNil(result.next)
        XCTAssertTrue(result.items.allSatisfy { $0.rating == nil && $0.pageCount == nil && $0.uploader == nil })
    }
    func testThumbnailModeEmptyPageAndConflictingCards() throws {
        let f = try load("list-empty-captured")
        let html = f.html.replacingOccurrences(of: "value=\"l\"", with: "value=\"t\"")
        XCTAssertTrue(try GalleryListParser(policy: policy).parse(response(f, html: html), context: f.context).items.isEmpty)
        let conflict = html.replacingOccurrences(of: "</body>", with: "<div class=\"itg gld\"><div class=\"gl1t\"></div></div></body>")
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, html: conflict), context: f.context)) {
            XCTAssertEqual($0 as? AppError, .parseMismatch)
        }
    }
    func testListErrorsAndUnconfirmedEmptyFailClosed() throws {
        for (id, error) in [("list-wrong-page", AppError.parseMismatch), ("list-missing-id", .parseMismatch),
                            ("list-display-mode", .unsupportedContent), ("list-empty-unconfirmed", .parseMismatch),
                            ("login-html-unconfirmed", .parseMismatch)] {
            let f = try load(id)
            XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(f.response, context: f.context)) {
                XCTAssertEqual($0 as? AppError, error, id)
            }
        }
        // UNKNOWN remains UNKNOWN: this checks conservative rejection, not real no-results detection.
        XCTAssertEqual(try load("list-empty-unconfirmed").expected["outcome"] as? String, "unknown")
    }
    func testDetailsAgainstGoldenProjectionsAndSourceTitles() throws {
        for id in ["detail-basic", "detail-missing-metadata"] {
            let f = try load(id)
            let detail = try GalleryDetailParser(policy: policy).parse(f.response, reference: ref())
            var actual = summary(detail.summary)
            actual["displayTitle"] = detail.summary.title
            actual["titleGN"] = detail.sourceTitles?.gn as Any? ?? NSNull()
            actual["titleGJ"] = detail.sourceTitles?.gj as Any? ?? NSNull()
            actual["tags"] = detail.tags.map { ["namespace": $0.namespace as Any? ?? NSNull(), "tags": $0.tags] }
            assertSubset(actual, try XCTUnwrap(f.expected["data"]), path: id)
            XCTAssertNil(detail.translatedTitle)
            XCTAssertNil(detail.originalTitle)
            XCTAssertEqual(try JSONDecoder().decode(GalleryDetail.self, from: JSONEncoder().encode(detail)), detail)
        }
    }
    func testThreeThumbnailLayoutsAgainstGoldenProjections() throws {
        for id in ["thumbnails-small", "thumbnails-large", "thumbnails-modern"] {
            let f = try load(id)
            let parsed = try ThumbnailPageParser(policy: policy).parse(f.response, reference: ref(f.context.scope.storage.site), context: f.context, totalPages: NonnegativeCount(3))
            let actual: [String: Any] = ["pages": parsed.items.map {
                ["index": $0.page.index.value, "displayNumber": $0.page.index.displayNumber,
                 "pageURL": $0.page.pageURL.absoluteString, "thumbnailURL": $0.thumbnailURL?.absoluteString as Any? ?? NSNull(),
                 "offset": $0.horizontalOffset?.value as Any? ?? NSNull()]
            }]
            assertSubset(actual, try XCTUnwrap(f.expected["data"]), path: id)
            XCTAssertNil(parsed.items.first?.page.dimensions) // thumbnail size is not reader image size
            XCTAssertEqual(try JSONDecoder().decode(PagedResult<GalleryThumbnail>.self, from: JSONEncoder().encode(parsed)), parsed)
        }
    }
    func testCapturedHathThumbnailDimensionsAndOffsets() throws {
        for id in ["thumbnails-captured-eh", "thumbnails-captured-ex"] {
            let f = try load(id)
            let parsed = try ThumbnailPageParser(policy: policy).parse(f.response, reference: ref(f.context.scope.storage.site), context: f.context, totalPages: NonnegativeCount(id.hasSuffix("ex") ? 4 : 3))
            let actual: [String: Any] = ["pages": parsed.items.map {
                ["index": $0.page.index.value, "displayNumber": $0.page.index.displayNumber,
                 "pageURL": $0.page.pageURL.absoluteString, "thumbnailURL": $0.thumbnailURL?.absoluteString as Any? ?? NSNull(),
                 "offset": $0.horizontalOffset?.value as Any? ?? NSNull(),
                 "width": $0.thumbnailSize?.width as Any? ?? NSNull(), "height": $0.thumbnailSize?.height as Any? ?? NSNull()]
            }]
            assertSubset(actual, try XCTUnwrap(f.expected["data"]), path: id)
            XCTAssertEqual(parsed.items.first?.horizontalOffset?.value, 0)
        }
    }
    func testAuthenticationRestrictionAndHTTPClassification() throws {
        for (id, error) in [("login-redirect", AppError.authenticationRequired), ("access-denied", .accessDenied),
                            ("rate-limited", .rateLimited(retryAfter: 30)), ("gallery-removed", .httpStatus(404)),
                            ("banned-text", .accessDenied)] {
            let f = try load(id)
            XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(f.response, context: f.context)) {
                XCTAssertEqual($0 as? AppError, error, id)
            }
        }
    }
    func testNavigationAndGalleryLinksRejectCrossSiteAndCredentials() throws {
        let f = try load("list-cursor")
        for bad in ["https://attacker.invalid/?next=1", "http://eh.example.invalid/?next=1",
                    "https://user:secret@eh.example.invalid/?next=1", "https://eh.example.invalid:444/?next=1",
                    "https://eh.example.invalid/%0Aevil?next=1"] {
            let html = f.html.replacingOccurrences(of: "/?next=40&amp;f_search=synthetic", with: bad)
            XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, html: html), context: f.context)) {
                XCTAssertEqual($0 as? AppError, .accessDenied)
            }
        }
        let altered = f.html.replacingOccurrences(of: "/g/42/synthetictoken/", with: "https://ex.example.invalid/g/42/synthetictoken/")
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, html: altered), context: f.context))
        let cursor = PageCursor(context: f.context, opaque: try SensitiveText("url-v1:https://attacker.invalid/"))
        XCTAssertThrowsError(try policy.navigationURL(cursor: cursor, context: f.context))
    }
    func testResponseScopeMimeAndBodyCannotMasqueradeAsHTML() throws {
        let f = try load("list-numeric-first")
        let newer = SessionScope(storage: f.context.scope.storage, generation: 2)
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, scope: newer), context: f.context)) {
            XCTAssertEqual($0 as? AppError, .staleSession)
        }
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, headers: ["Content-Type": "image/jpeg"]), context: f.context)) {
            XCTAssertEqual($0 as? AppError, .unsupportedContent)
        }
        let binary = try HTTPResponse(requestID: UUID(), scope: f.context.scope, status: 200,
            headers: f.response.headers, body: Data([255, 254, 0]), finalURL: f.response.finalURL)
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(binary, context: f.context))
        XCTAssertThrowsError(try GalleryListParser(policy: policy).parse(response(f, html: "<html><table><tr><td>broken"), context: f.context))
    }
    func testDetailSummaryCarriesTagsAndPostedTimeForHistoryCards() throws {
        let f = try load("detail-basic")
        let html = f.html.replacingOccurrences(of: "<td>Length:</td>", with: "<td>Posted:</td><td>2020-01-01 00:00</td></tr><tr><td>Length:</td>")
        let detail = try GalleryDetailParser(policy: policy).parse(response(f, html: html), reference: ref())
        XCTAssertEqual(detail.summary.listTags, detail.tags)
        XCTAssertEqual(detail.summary.postedAt?.timeIntervalSince1970, 1577836800)
        let saved = try JSONDecoder().decode(GallerySummary.self, from: JSONEncoder().encode(detail.summary))
        XCTAssertEqual(saved.listTags?.first?.tags, ["japanese"])
    }
    func testDetailReferenceMismatchAndTitleFallback() throws {
        let f = try load("detail-basic")
        XCTAssertThrowsError(try GalleryDetailParser(policy: policy).parse(response(f, url: "https://eh.example.invalid/g/43/synthetictoken/"), reference: ref()))
        let alternate = f.html.replacingOccurrences(of: "<h1 id=\"gn\">Synthetic title</h1>", with: "")
        let detail = try GalleryDetailParser(policy: policy).parse(response(f, html: alternate), reference: ref())
        XCTAssertEqual(detail.summary.title, "合成原題")
        let missing = alternate.replacingOccurrences(of: "<h1 id=\"gj\">合成原題</h1>", with: "")
        XCTAssertThrowsError(try GalleryDetailParser(policy: policy).parse(response(f, html: missing), reference: ref()))
    }
    func testThumbnailIndexBoundsIdentityAndPagination() throws {
        let f = try load("thumbnails-small")
        let parser = ThumbnailPageParser(policy: policy)
        XCTAssertThrowsError(try parser.parse(f.response, reference: ref(), context: f.context, totalPages: NonnegativeCount(1)))
        for replacement in ["/s/syntheticimage/43-2", "/s/syntheticimage/42-0", "/s/syntheticimage/42-3"] {
            let html = f.html.replacingOccurrences(of: "/s/syntheticimage/42-2", with: replacement)
            XCTAssertThrowsError(try parser.parse(response(f, html: html), reference: ref(), context: f.context))
        }
        let html = f.html.replacingOccurrences(of: "</body>", with: "<table class=\"ptt\"><tbody><tr><td>&lt;</td><td class=\"ptds\">1</td><td><a href=\"?p=1\">2</a></td><td>&gt;</td></tr></tbody></table></body>")
        let result = try parser.parse(response(f, html: html), reference: ref(), context: f.context)
        XCTAssertEqual(try policy.navigationURL(cursor: XCTUnwrap(result.next), context: f.context).query, "p=1")
        XCTAssertNil(result.previous)
    }
    func testParserCancellationPropagates() async throws {
        let f = try load("list-numeric-first")
        let parser = GalleryListParser(policy: policy)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try parser.parse(f.response, context: f.context)
        }
        do { _ = try await task.value; XCTFail("Cancelled parsing must not return data") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCapturedNoResultsAndFalsePositiveGuards() throws {
        let f = try load("list-empty-captured")
        let parser = GalleryListParser(policy: policy)
        let result = try parser.parse(f.response, context: f.context)
        assertSubset(["items": result.items.map(summary), "nextHref": NSNull(), "previousHref": NSNull()],
                     try XCTUnwrap(f.expected["data"]), path: "list-empty-captured")
        XCTAssertNil(result.next)
        XCTAssertNil(result.previous)
        XCTAssertEqual(result.context, f.context)
        for html in [
            "<p>No hits found</p>",
            f.html.replacingOccurrences(of: "No hits found", with: "Sign in to continue"),
            f.html.replacingOccurrences(of: "id=\"searchbox\"", with: "id=\"not-search\""),
            f.html.replacingOccurrences(of: "</body>", with: "<table class=\"itg\"><tbody><tr><td class=\"gl3c glname\">contradictory entry</td></tr></tbody></table></body>"),
            f.html.replacingOccurrences(of: "</body>", with: "<div class=\"searchnav\"><a id=\"unext\" href=\"?next=1\">Next</a></div></body>")
        ] {
            XCTAssertThrowsError(try parser.parse(response(f, html: html), context: f.context)) {
                XCTAssertEqual($0 as? AppError, .parseMismatch)
            }
        }
        XCTAssertThrowsError(try parser.parse(response(f, status: 403), context: f.context)) {
            XCTAssertEqual($0 as? AppError, .accessDenied)
        }
        XCTAssertThrowsError(try parser.parse(response(f, url: "https://forums.example.invalid/index.php?act=Login&CODE=00"), context: f.context)) {
            XCTAssertEqual($0 as? AppError, .authenticationRequired)
        }
    }
}
