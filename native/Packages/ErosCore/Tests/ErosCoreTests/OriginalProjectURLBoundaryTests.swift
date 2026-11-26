import Foundation
import Testing
@testable import ErosCore

struct OriginalProjectURLBoundaryTests {
    private let gallery = "https://e-hentai.org/g/1234567/012345abcd/"
    private let external = "https://example.net/SYNTHETIC_SHARE_02"

    private func parse(_ body: String) throws -> GalleryComment {
        let html = "<div id='cdiv'><div class='c1'><div class='c6' id='comment_42'>" + body + "</div></div></div>"
        return try #require(GalleryCommentsParser().parse(html: html).items.first)
    }

    @Test(arguments: ["好的给我去", "前文", ""], ["好的不少", "好玩的当然要和朋友分享"])
    func chineseBesideBareGalleryURLStaysPlain(prefix: String, suffix: String) throws {
        let text = prefix + gallery + suffix
        let item = try parse(text)
        let runs = CommentBodyPresentation.segments(for: item)
        #expect(runs.compactMap(\.target) == [URL(string: gallery)!])
        #expect(runs.filter { $0.target != nil }.map(\.text) == [gallery])
        #expect(runs.map(\.text).joined() == text)
        #expect(try ClipboardLinkCandidates.parse(text).map(\.url.absoluteString) == [gallery])
    }

    @Test(arguments: ["\n", "\r\n", "<br>", ""])
    func externalURLDoesNotTakeChineseAfterIt(separator: String) throws {
        let item = try parse(external + separator + "好玩的，当然要和朋友分享")
        let runs = CommentBodyPresentation.segments(for: item)
        #expect(runs.compactMap(\.target) == [URL(string: external)!])
        #expect(runs.map(\.text).joined() == item.body)
    }

    @Test(arguments: [false, true])
    func actualAndEscapedAnchorMarkupKeepExactTargets(escaped: Bool) throws {
        let markup = "<a href=\"" + gallery + "\">" + gallery + "</a>;<br>"
        let input = escaped ? markup.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;") : markup
        let item = try parse(input)
        let runs = CommentBodyPresentation.segments(for: item)
        #expect(runs.compactMap(\.target).allSatisfy { $0 == URL(string: gallery) })
        #expect(runs.compactMap(\.target).count == (escaped ? 2 : 1))
        #expect(runs.map(\.text).joined() == item.body)
        #expect(try ClipboardLinkCandidates.parse(markup).map(\.url.absoluteString) == [gallery])
    }

    @Test
    func oldLiteralCachedRunGetsNewBoundaryWithoutDroppingProse() throws {
        let label = gallery + "好的不少"
        let target = try #require(URL(string: label))
        let item = GalleryComment(id: "42", author: nil, body: "前文" + label,
            bodySegments: [.text("前文"), .link(label: label, target: target)], postedAt: nil,
            score: nil, canVoteUp: nil, canVoteDown: nil, myVote: nil, canEdit: nil)
        let cached = try JSONDecoder().decode(GalleryComment.self, from: JSONEncoder().encode(item))
        let runs = CommentBodyPresentation.segments(for: cached)
        #expect(runs.compactMap(\.target) == [URL(string: gallery)!])
        #expect(runs.map(\.text).joined() == item.body)
    }

    @Test
    func legacyBodyWithoutRunsUsesSameBoundary() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": "42", "body": "前文" + gallery + "后文"])
        let item = try JSONDecoder().decode(GalleryComment.self, from: data)
        #expect(CommentBodyPresentation.segments(for: item).compactMap(\.target) == [URL(string: gallery)!])
        #expect(CommentBodyPresentation.segments(for: item).map(\.text).joined() == item.body)
    }

    @Test(arguments: ["https://example.net/中文/名字%20值", "https://example.net/?q=中文", "https://example.net/%E4%B8%AD%E6%96%87"])
    func actualHrefIsNotReinterpretedAsBareText(href: String) throws {
        let item = try parse("<a href=\"" + href + "\">" + href + "</a>正文")
        let runs = CommentBodyPresentation.segments(for: item)
        #expect(runs.compactMap(\.target) == [URL(string: href)!])
        #expect(runs.filter { $0.target != nil }.map(\.text) == [href])
        #expect(runs.map(\.text).joined() == item.body)
        let restored = try JSONDecoder().decode(GalleryComment.self, from: JSONEncoder().encode(item))
        #expect(CommentBodyPresentation.segments(for: restored).compactMap(\.target) == [URL(string: href)!])
    }

    @Test(arguments: ["?act=delete", "?action=remove", "?p=1"])
    func queryProtectionsSurviveBareBoundaries(query: String) {
        #expect(throws: ClipboardLinkError.noSupportedLink) {
            try ClipboardLinkCandidates.parse(gallery + query + "正文")
        }
    }

    @Test(arguments: [Site.eh, Site.ex])
    func bothSiteDetailParsersUseTheBoundary(site: Site) throws {
        let host = site == .eh ? "e-hentai.org" : "exhentai.org"
        let url = "https://" + host + "/g/1234567/012345abcd/"
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: site), generation: 1)
        let reference = GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(1234567)),
            token: try SensitiveText("012345abcd"))
        let html = "<h1 id='gn'>SYNTHETIC</h1><div id='gdd'></div><div id='cdiv'><div class='c1'><div class='c6' id='comment_42'>前文" + url + "后文</div></div></div>"
        let response = try HTTPResponse(requestID: UUID(), scope: scope, status: 200, headers: ["Content-Type": "text/html"],
            body: Data(html.utf8), finalURL: URL(string: url)!)
        let item = try #require(GalleryDetailParser().parse(response, reference: reference).comments?.items.first)
        #expect(CommentBodyPresentation.segments(for: item).compactMap(\.target) == [URL(string: url)!])
    }

    @Test
    func adjacentDetectedAndRealAnchorRunsKeepTheirOrigins() throws {
        let item = try parse(gallery + "<a href=\"" + gallery + "\">" + gallery + "</a>后文")
        let runs = CommentBodyPresentation.segments(for: item)
        #expect(runs.filter { $0.target != nil }.map(\.origin) == [.detected, .anchor])
        #expect(runs.map(\.text).joined() == item.body)
    }

    @Test
    func previousVersionCanDecodeNewAnchorMetadata() throws {
        let href = "https://example.net/中文/名字"
        let item = try parse(" <a href=\"" + href + "\"> " + href + " </a> ")
        let runs = try #require(item.bodySegments)
        let legacy = try JSONDecoder().decode([LegacySegment].self, from: JSONEncoder().encode(runs))
        #expect(legacy.compactMap(\.target) == [URL(string: href)!])
        #expect(runs.compactMap(\.target) == [URL(string: href)!])
        #expect(runs.filter { $0.target != nil }.allSatisfy { $0.origin == .anchor })
    }

    @Test
    func newVersionDecodesActualLegacyLinkWithoutOrigin() throws {
        let label = gallery + "后文"
        let encoded = try JSONEncoder().encode([LegacySegment.link(label: label, target: URL(string: label)!)])
        let restored = try JSONDecoder().decode([CommentBodySegment].self, from: encoded)
        #expect(restored.first?.origin == nil)
        let item = GalleryComment(id: "42", author: nil, body: label, bodySegments: restored,
            postedAt: nil, score: nil, canVoteUp: nil, canVoteDown: nil, myVote: nil, canEdit: nil)
        #expect(CommentBodyPresentation.segments(for: item).compactMap(\.target) == [URL(string: gallery)!])
        #expect(CommentBodyPresentation.segments(for: item).map(\.text).joined() == label)
    }

    private enum LegacySegment: Codable {
        case text(String)
        case link(label: String, target: URL)
        var target: URL? { if case .link(_, let value) = self { return value }; return nil }
    }

    @Test(arguments: ["https://example.net/中文/名字", "https://example.net/?q=中文"])
    func oldAmbiguousUnicodeHrefIsPreserved(href: String) throws {
        let encoded = try JSONEncoder().encode([LegacySegment.link(label: href, target: URL(string: href)!)])
        let restored = try JSONDecoder().decode([CommentBodySegment].self, from: encoded)
        let item = GalleryComment(id: "42", author: nil, body: href, bodySegments: restored,
            postedAt: nil, score: nil, canVoteUp: nil, canVoteDown: nil, myVote: nil, canEdit: nil)
        #expect(CommentBodyPresentation.segments(for: item).compactMap(\.target) == [URL(string: href)!])
    }

    @Test(arguments: ["act", "action"])
    func legacyUnsafeQueryIsCheckedBeforeBoundaryRepair(parameter: String) throws {
        let label = gallery + "正文?" + parameter + "=delete"
        let encoded = try JSONEncoder().encode([LegacySegment.link(label: label, target: URL(string: label)!)])
        let restored = try JSONDecoder().decode([CommentBodySegment].self, from: encoded)
        let item = GalleryComment(id: "42", author: nil, body: label, bodySegments: restored,
            postedAt: nil, score: nil, canVoteUp: nil, canVoteDown: nil, myVote: nil, canEdit: nil)
        #expect(CommentBodyPresentation.segments(for: item).compactMap(\.target).isEmpty)
        #expect(CommentBodyPresentation.segments(for: item).map(\.text).joined() == label)
    }
}
