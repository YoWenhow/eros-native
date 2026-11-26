import XCTest
import ErosCore

final class SearchFilterDraftTests: XCTestCase {
    func testDefaultAndBlankBoundsNormalizeToNil() throws {
        var draft = SearchFilterDraft()
        XCTAssertNil(try draft.normalizedFilters())
        draft.pageRangeEnabled = true; draft.minimumPageCount = " "; draft.maximumPageCount = "\n"
        XCTAssertNil(try draft.normalizedFilters())
    }
    func testEachFlagCanBeEnabledAndDisabledIndependently() throws {
        let keys: [WritableKeyPath<SearchFilterDraft, Bool>] = [\.requireTorrent, \.includeExpunged, \.disableLanguageFilter, \.disableUploaderFilter, \.disableTagFilter]
        let expected: [KeyPath<SearchFilters, Bool>] = [\.requireTorrent, \.includeExpunged, \.disableLanguageFilter, \.disableUploaderFilter, \.disableTagFilter]
        for (index, key) in keys.enumerated() {
            var draft = SearchFilterDraft(); draft[keyPath: key] = true
            let filters = try XCTUnwrap(draft.normalizedFilters())
            for (other, flag) in expected.enumerated() { XCTAssertEqual(filters[keyPath: flag], other == index) }
            draft[keyPath: key] = false; XCTAssertNil(try draft.normalizedFilters())
        }
    }
    func testRatingWhitelistAndDisabledValue() throws {
        XCTAssertEqual(SearchMinimumRating.allCases.map(\.rawValue), [2, 3, 4, 5])
        for rating in SearchMinimumRating.allCases {
            var draft = SearchFilterDraft(); draft.minimumRating = rating; draft.ratingEnabled = true
            XCTAssertEqual(try draft.normalizedFilters()?.minimumRating?.value, rating.rawValue)
            draft.ratingEnabled = false; XCTAssertNil(try draft.normalizedFilters())
        }
    }
    func testPageBoundsZeroEqualOpenAndIntegerLimit() throws {
        for (low, high, expectedLow, expectedHigh) in [("0", "0", 0, 0), (" 0007 ", "", 7, nil), ("", String(Int.max), nil, Int.max)] as [(String, String, Int?, Int?)] {
            var draft = SearchFilterDraft(); draft.pageRangeEnabled = true
            draft.minimumPageCount = low; draft.maximumPageCount = high
            let filters = try XCTUnwrap(draft.normalizedFilters())
            XCTAssertEqual(filters.minimumPageCount?.value, expectedLow); XCTAssertEqual(filters.maximumPageCount?.value, expectedHigh)
        }
    }
    func testInvalidAndOverflowTextIdentifiesField() {
        for value in ["-1", "+1", "1.5", "1e3", "１２", "1 2", "abc", String(Int.max) + "0"] {
            var draft = SearchFilterDraft(); draft.pageRangeEnabled = true; draft.minimumPageCount = value
            XCTAssertThrowsError(try draft.normalizedFilters()) { XCTAssertEqual($0 as? SearchFilterDraftError, .invalidMinimumPageCount) }
            draft.minimumPageCount = ""; draft.maximumPageCount = value
            XCTAssertThrowsError(try draft.normalizedFilters()) { XCTAssertEqual($0 as? SearchFilterDraftError, .invalidMaximumPageCount) }
        }
    }
    func testReversedRangeAndDisabledInvalidHiddenText() throws {
        var draft = SearchFilterDraft(); draft.pageRangeEnabled = true
        draft.minimumPageCount = "10"; draft.maximumPageCount = "9"
        XCTAssertThrowsError(try draft.normalizedFilters()) { XCTAssertEqual($0 as? SearchFilterDraftError, .reversedPageRange) }
        draft.minimumPageCount = "invalid"; draft.pageRangeEnabled = false
        XCTAssertNil(try draft.normalizedFilters()); XCTAssertEqual(draft.minimumPageCount, "invalid")
    }
    func testQueryRoundTripAndEditingIsolation() throws {
        let filters = try SearchFilters(requireTorrent: true, includeExpunged: true, minimumRating: NonnegativeCount(4), minimumPageCount: NonnegativeCount(0), maximumPageCount: NonnegativeCount(100), disableLanguageFilter: true, disableUploaderFilter: true, disableTagFilter: true)
        let query = GalleryQuery(terms: "language:\"中文 日本語\" + %25 -tag:test", excludedCategories: ["Manga"], source: .watched, filters: filters)
        var draft = try SearchFilterDraft(query: query)
        XCTAssertEqual(try draft.normalizedQuery(replacing: query), query)
        draft.requireTorrent = false; draft.excludedCategories.insert(.misc)
        XCTAssertTrue(query.filters!.requireTorrent); XCTAssertEqual(query.excludedCategories, ["Manga"])
        let result = try draft.normalizedQuery(replacing: query)
        XCTAssertEqual(result.terms, query.terms); XCTAssertEqual(result.source, query.source); XCTAssertEqual(result.sort, query.sort)
        XCTAssertEqual(result.excludedCategories, ["Misc", "Manga"])
        draft.reset(); XCTAssertEqual(draft, SearchFilterDraft()); XCTAssertEqual(query.filters, filters)
    }
    func testIncludedCategoriesRoundTripSavedExclusionsAndReset() throws {
        let oldQuery = GalleryQuery(excludedCategories: ["Manga", "Western"])
        var draft = try SearchFilterDraft(query: oldQuery)
        XCTAssertEqual(draft.includedCategories.count, 8)
        XCTAssertFalse(draft.includedCategories.contains(.manga))
        XCTAssertFalse(draft.includedCategories.contains(.western))
        XCTAssertEqual(try draft.normalizedQuery(replacing: oldQuery), oldQuery)

        draft.includedCategories = [.manga, .western]
        let query = try draft.normalizedQuery(replacing: oldQuery)
        XCTAssertEqual(query.excludedCategories, ["Misc", "Doujinshi", "Artist CG", "Game CG", "Image Set", "Cosplay", "Asian Porn", "Non-H"])
        XCTAssertEqual(try SearchFilterDraft(query: query).includedCategories, [.manga, .western])

        draft.includedCategories = []
        XCTAssertEqual(try draft.normalizedQuery(replacing: oldQuery).excludedCategories.count, 10)
        draft.reset()
        XCTAssertEqual(draft.includedCategories, Set(SearchCategory.allCases))
        XCTAssertTrue(try draft.normalizedQuery(replacing: oldQuery).excludedCategories.isEmpty)
    }

    func testCategoryNormalizationAndUnsupportedInput() throws {
        let query = GalleryQuery(excludedCategories: ["Manga", "Misc", "Manga"])
        XCTAssertEqual(try SearchFilterDraft(query: query).normalizedQuery(replacing: query).excludedCategories, ["Misc", "Manga"])
        XCTAssertThrowsError(try SearchFilterDraft(query: GalleryQuery(excludedCategories: ["unknown"]))) { XCTAssertEqual($0 as? SearchFilterDraftError, .unsupportedCategory) }
        for rating in [0, 1, 6] {
            XCTAssertThrowsError(try SearchFilterDraft(query: GalleryQuery(filters: SearchFilters(minimumRating: NonnegativeCount(rating))))) { XCTAssertEqual($0 as? SearchFilterDraftError, .unsupportedRating) }
        }
    }
}
