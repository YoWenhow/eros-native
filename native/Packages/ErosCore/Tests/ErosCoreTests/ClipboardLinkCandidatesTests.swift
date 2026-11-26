import XCTest
@testable import ErosCore

final class ClipboardLinkCandidatesTests:XCTestCase {
    private let url="https://e-hentai.org/g/42/012345abcd/"
    func testShareTextNormalizationDuplicatesImagesAndMultipleChoices() throws {
        XCTAssertEqual(try ClipboardLinkCandidates.parse("分享："+url+"。").count,1)
        XCTAssertEqual(try ClipboardLinkCandidates.parse(url+" "+url.dropLast()).count,1)
        let values=try ClipboardLinkCandidates.parse(url+" https://exhentai.org/s/abcdef0123/43-2")
        XCTAssertEqual(values.count,2)
        guard case .image=values[1].target else{return XCTFail()}
        let wrapper="erosnative://open?url="+url.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
        XCTAssertEqual(try ClipboardLinkCandidates.parse(wrapper).first?.target,try ExternalLinkParser.parse(url))
    }
    func testEmptyUnsupportedForgedAndActionURLsNeverBecomeCandidates() {
        for text in ["","nothing","https://cdn.example.net/a.jpg","javascript:bad()",
                     "https://e-hentai.org.evil.test/g/42/012345abcd/","https://e-hentai.org/g/42/012345abcd/?act=delete"] {
            XCTAssertThrowsError(try ClipboardLinkCandidates.parse(text))
        }
    }
    func testInputAndCandidateBudgetsRejectWithoutSelectingFirst() {
        XCTAssertThrowsError(try ClipboardLinkCandidates.parse(String(repeating:"a",count:16385))) {
            XCTAssertEqual($0 as? ClipboardLinkError,.tooLarge)
        }
        let many=(1...11).map{"https://e-hentai.org/g/\($0)/012345abcd/"}.joined(separator:" ")
        XCTAssertThrowsError(try ClipboardLinkCandidates.parse(many)) {XCTAssertEqual($0 as? ClipboardLinkError,.tooMany)}
    }
}
