import Foundation
import Testing
import XCTest
@testable import ErosCore

struct TranslationLaunchPreferencesTests {
    @Test func build196PreferencesKeepAutoUpdateOff() throws {
        let saved = Data("""
            {"theme":"dark","rightToLeft":true,"vertical":false,"cacheMiB":128,"downloadConcurrency":2,
             "tagTranslationDisplay":"both","readerPrefetchPages":3}
            """.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: saved).validated()
        #expect(!AppPreferences().updatesTagTranslationOnLaunch)
        #expect(!preferences.updatesTagTranslationOnLaunch)
        #expect(preferences.theme == .dark)
        #expect(preferences.tagTranslationDisplay == .both)
        #expect(preferences.readerPrefetchPages == 3)
    }

    @Test(arguments: [true, false]) func autoUpdateOptInRoundTrips(_ enabled: Bool) throws {
        var preferences = AppPreferences()
        preferences.tagTranslationDisplay = .both
        preferences.updatesTagTranslationOnLaunch = enabled

        let saved = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: saved).validated()
        #expect(restored == preferences)
    }
}

final class TagTranslationPresentationTests:XCTestCase {
    func testThreeModes() {
        XCTAssertEqual(TagTranslationPresentation.text(original:"english",translated:"英语",mode:.original),"english")
        XCTAssertEqual(TagTranslationPresentation.text(original:"english",translated:"英语",mode:.translated),"英语")
        XCTAssertEqual(TagTranslationPresentation.text(original:"english",translated:"英语",mode:.both),"英语（english）")
    }
    func testMissingEmptyAndIdenticalTranslationsFallback() {
        for mode in TagTranslationDisplayMode.allCases {
            for translated in [nil,""," ","english"] as [String?] {
                XCTAssertEqual(TagTranslationPresentation.text(original:"english",translated:translated,mode:mode),"english")
            }
        }
    }
    func testSearchAlwaysUsesOriginalNamespaceAndTag() throws {
        let key=try TagTranslationKey(namespace:"artist",original:"some artist")
        for mode in TagTranslationDisplayMode.allCases {
            _ = TagTranslationPresentation.text(original:key.original,translated:"作者",mode:mode)
            XCTAssertEqual(TagTranslationPresentation.searchTerms(for:key),"artist:some artist")
        }
        XCTAssertEqual(TagTranslationPresentation.searchTerms(for:try TagTranslationKey(namespace:"group",original:"some artist")),"group:some artist")
    }
    func testCategoryMappingDoesNotGuessUnknownCategories() {
        XCTAssertEqual(TagTranslationPresentation.categoryKey("Artist CG")?.original,"artistcg")
        XCTAssertEqual(TagTranslationPresentation.categoryKey("Non-H")?.namespace,"reclass")
        XCTAssertNil(TagTranslationPresentation.categoryKey("Future Category"))
    }
    func testPreexistingPreferencesDefaultToOriginal() throws {
        let old=Data(#"{"theme":"dark","rightToLeft":true,"vertical":false,"cacheMiB":128,"downloadConcurrency":2}"#.utf8)
        let prefs=try JSONDecoder().decode(AppPreferences.self,from:old)
        XCTAssertEqual(prefs.tagTranslationDisplay,.original);XCTAssertEqual(prefs.theme,.dark)
        XCTAssertEqual(prefs.downloadConcurrency,2);XCTAssertTrue(prefs.rightToLeft)
    }
    func testPreferenceRoundTripPreservesOtherSettings() throws {
        for mode in TagTranslationDisplayMode.allCases {
            var prefs=AppPreferences();prefs.tagTranslationDisplay=mode;prefs.cacheMiB=512;prefs.downloadConcurrency=3
            let restored=try JSONDecoder().decode(AppPreferences.self,from:JSONEncoder().encode(prefs))
            XCTAssertEqual(restored,prefs)
        }
    }
    func testPresentationDoesNotMutateOriginalOrderOrIdentity() throws {
        let originals=["zebra","alpha"]
        let keys=try originals.map{try TagTranslationKey(namespace:"artist",original:$0)}
        let before=keys.map(\.original).sorted()
        for mode in TagTranslationDisplayMode.allCases {
            _ = originals.map{TagTranslationPresentation.text(original:$0,translated:"译文",mode:mode)}
            XCTAssertEqual(keys.map(\.original).sorted(),before);XCTAssertEqual(originals,["zebra","alpha"])
        }
    }
    func testArbitraryTextIsNotConvertedToMarkupOrLinks() {
        let value="[link](https://example.invalid) <plain>"
        XCTAssertEqual(TagTranslationPresentation.text(original:"original",translated:value,mode:.translated),value)
    }
}
