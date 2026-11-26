import XCTest
import ErosCore

final class SearchAssistanceTests:XCTestCase {
    func testQuotedFormulaAndInsertionPreservePreviousClauses() throws {
        let key=try TagTranslationKey(namespace:"artist",original:"sample name")
        let formula=try XCTUnwrap(SearchAssistance.formula(key))
        XCTAssertEqual(formula,"artist:\"sample name$\"")
        XCTAssertEqual(SearchAssistance.inserting(formula,into:"language:english -artist:sam"),"language:english -artist:\"sample name$\"")
        XCTAssertEqual(SearchAssistance.fragment("language:english artist:\"sample na"),"artist:\"sample na")
        XCTAssertEqual(SearchAssistance.keys(in:"language:\"english$\" "+formula).map(\.original),["english","sample name"])
    }
    func testAliasesLiteralCharactersAndUnsafeFormula() throws {
        XCTAssertEqual(SearchAssistance.lookupParts("-g:\"some group$\"").0,"group")
        XCTAssertEqual(SearchAssistance.lookupParts("-g:\"some group$\"").1,"some group")
        XCTAssertNil(SearchAssistance.formula(try TagTranslationKey(namespace:"artist",original:"bad\"quote")))
        XCTAssertEqual(SearchAssistance.tokens("title:\"two words\" artist:name"),["title:\"two words\"","artist:name"])
    }
}
