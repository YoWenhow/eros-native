import Foundation
import Testing
import ErosCore

struct ReaderPrefetchPreferencesTests {
    // The pre-P2X09 payload uses the existing native.preferences.v1 keys.
    private let build168Fields = """
        "theme":"dark","rightToLeft":true,"vertical":false,"cacheMiB":0,"downloadConcurrency":3,
        "tagTranslationDisplay":"both","readerLayout":{"mode":"doublePage","coverAlone":false}
        """

    @Test func olderPreferencesKeepTheirValuesAndDefaultToTwoPages() throws {
        let v1 = Data("""
            {"theme":"light","rightToLeft":false,"vertical":true,"cacheMiB":64,"downloadConcurrency":2}
            """.utf8)
        let original = try JSONDecoder().decode(AppPreferences.self, from: v1).validated()
        var expected = AppPreferences()
        expected.theme = .light
        expected.vertical = true
        expected.cacheMiB = 64
        expected.downloadConcurrency = 2
        #expect(original == expected)
        #expect(original.readerPrefetchPages == 2)

        let newer = try decode("{\(build168Fields)}")
        expected.theme = .dark
        expected.rightToLeft = true
        expected.vertical = false
        expected.cacheMiB = 0
        expected.downloadConcurrency = 3
        expected.tagTranslationDisplay = .both
        expected.readerLayout = ReaderLayoutPreferences(mode: .doublePage, coverAlone: false)
        #expect(newer == expected)
        #expect(newer.readerPrefetchPages == 2)
    }

    @Test(arguments: 0...5) func validCountsRoundTripIncludingZero(_ pages: Int) throws {
        var preferences = try decode("{\(build168Fields)}")
        try preferences.setReaderPrefetchPages(pages)
        let data = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: data).validated()
        #expect(restored.readerPrefetchPages == pages)
        #expect(restored == preferences)
    }

    @Test(arguments: [-1, 6, Int.min, Int.max]) func rejectedChangesKeepThePreviousChoice(_ invalid: Int) throws {
        var preferences = try decode("{\(build168Fields),\"readerPrefetchPages\":0}")
        let previous = preferences
        #expect(throws: AppError.invalidInput) {
            try preferences.setReaderPrefetchPages(invalid)
        }
        #expect(preferences == previous)
    }

    @Test(arguments: ["-1", "6", "1.5", "\"2\"", "true", "null", "[]", "{}"])
    func rejectsInvalidPersistedCounts(_ literal: String) {
        #expect(throws: (any Error).self) {
            try decode("{\(build168Fields),\"readerPrefetchPages\":\(literal)}")
        }
    }

    private func decode(_ json: String) throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8)).validated()
    }
}
