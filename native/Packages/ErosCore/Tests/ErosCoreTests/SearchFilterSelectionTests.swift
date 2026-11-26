import Foundation
import XCTest
import ErosCore

final class SearchFilterSelectionTests: XCTestCase {
    func testMissingFieldsDecodeToCompatibleDefaults() throws {
        let decoder = JSONDecoder()
        for json in ["{}", "{\"filters\":{}}", "{\"excludedCategories\":[]}"] {
            XCTAssertEqual(try decoder.decode(SearchFilterSelection.self, from: Data(json.utf8)), SearchFilterSelection())
        }
        let value = try decoder.decode(SearchFilterSelection.self, from: Data("{\"filters\":{\"requireTorrent\":true}}".utf8))
        XCTAssertEqual(value.activeCount, 1); XCTAssertEqual(value.filters?.includeExpunged, false)
        XCTAssertEqual(try decoder.decode(SearchFilterSelection.self, from: JSONEncoder().encode(value)), value)
    }
    func testInvalidStoredValuesAreNotSilentlyAccepted() {
        for json in ["{\"filters\":{\"requireTorrent\":1}}", "{\"filters\":{\"minimumRating\":6}}", "{\"filters\":{\"minimumPageCount\":5,\"maximumPageCount\":1}}", "{\"excludedCategories\":[\"unknown\"]}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(SearchFilterSelection.self, from: Data(json.utf8)))
        }
    }
    func testCountAndSerializationExcludeQueryMetadata() throws {
        var draft = SearchFilterDraft(); draft.excludedCategories = [.manga, .misc]
        draft.requireTorrent = true; draft.includeExpunged = true; draft.disableLanguageFilter = true
        draft.disableUploaderFilter = true; draft.disableTagFilter = true; draft.ratingEnabled = true
        draft.pageRangeEnabled = true; draft.minimumPageCount = "0"; draft.maximumPageCount = "10"
        let selection = try SearchFilterSelection(query: draft.normalizedQuery(replacing: GalleryQuery(terms: "private", source: .watched)))
        XCTAssertEqual(selection.activeCount, 9)
        let data = try JSONEncoder().encode(selection)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["excludedCategories", "filters"]))
        XCTAssertEqual(selection.query(terms: "next").source, .browse)
        XCTAssertEqual(selection.query(terms: "next").terms, "next")
    }
}
