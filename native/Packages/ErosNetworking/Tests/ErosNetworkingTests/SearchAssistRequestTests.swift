import Foundation
import XCTest
import ErosCore
import ErosNetworking

final class SearchAssistRequestTests:XCTestCase {
    func testFavoriteCompactModeOnInitialAndCursorRequests() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        let context=RequestContext(scope:scope,queryID:UUID())
        let initial=try EndpointBuilder().favorites(FavoritesListRequest(groupID:"2",context:context))
        XCTAssertTrue(initial.url.absoluteString.contains("inline_set=dm_l"))
        let cursor=try PageCursor(context:context,opaque:SensitiveText("url-v1:https://e-hentai.org/favorites.php?favcat=2&next=123&inline_set=dm_t"))
        let next=try EndpointBuilder().favorites(FavoritesListRequest(groupID:"2",context:context,cursor:cursor))
        let values=URLComponents(url:next.url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        XCTAssertEqual(values.filter{$0.name == "inline_set"}.map(\.value),["dm_l"])
        XCTAssertEqual(values.first{$0.name == "next"}?.value,"123")
    }
    func testFavoriteTitleSearchUsesTheSelectedFolderAndLiteralPhraseOnEveryPage() throws {
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let context = RequestContext(scope: scope, queryID: UUID())
        let cursor = try PageCursor(context: context, opaque: SensitiveText(
            "url-v1:https://e-hentai.org/favorites.php?favcat=8&f_search=favnote%3Aother&sf=on&next=123&inline_set=dm_t"))
        for page in [nil, cursor] {
            let input = try FavoritesListRequest(groupID: "2", titleQuery: "  星 + \"海\"  ", context: context, cursor: page)
            let request = try EndpointBuilder().favorites(input)
            let parts = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            let values = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(values["f_search"] ?? nil, "title:\"星 + 海\"")
            XCTAssertEqual(values["favcat"] ?? nil, "2")
            XCTAssertEqual(values["next"] ?? nil, page == nil ? nil : "123")
            XCTAssertEqual(values["inline_set"] ?? nil, "dm_l")
            XCTAssertNil(values["sf"])
            XCTAssertTrue(parts.percentEncodedQuery?.contains("%2B") == true)
        }
    }
    func testSuggestionInputBoundsAndJSONEncoding() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        XCTAssertThrowsError(try EndpointBuilder().tagSuggestions(text:"",scope:scope))
        XCTAssertThrowsError(try EndpointBuilder().tagSuggestions(text:String(repeating:"x",count:257),scope:scope))
        let value="artist:some \" & + 中文"
        let request=try EndpointBuilder().tagSuggestions(text:value,scope:scope)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(request.body)) as? [String:String])
        XCTAssertEqual(json["text"],value);XCTAssertEqual(request.url.path,"/api.php")
    }
}
