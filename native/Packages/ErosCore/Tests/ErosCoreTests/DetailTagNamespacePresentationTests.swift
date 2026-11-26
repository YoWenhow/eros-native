import Testing
@testable import ErosCore

struct DetailTagNamespacePresentationTests {
    @Test(arguments: [
        ("reclass", "分类"), ("language", "语言"), ("parody", "原作"), ("character", "角色"),
        ("group", "社团"), ("artist", "作者"), ("cosplayer", "扮演"), ("male", "男性"),
        ("female", "女性"), ("mixed", "混合"), ("other", "其他"), ("location", "地点"),
        ("misc", "杂项"), ("temp", "临时")
    ])
    func knownNamespacesKeepOriginalAndBilingualModes(_ namespace: String, _ expected: String) throws {
        #expect(DetailTagNamespacePresentation(namespace: namespace, mode: .translated).text == expected)
        #expect(expected.count == 2)
        #expect(expected.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) })
        #expect(DetailTagNamespacePresentation(namespace: namespace, mode: .original).text == namespace)
        #expect(DetailTagNamespacePresentation(namespace: namespace, mode: .both).text == expected + "（" + namespace + "）")
        if namespace == "misc" || namespace == "temp" {
            #expect(throws: TagTranslationError.invalidKey) {
                try TagTranslationKey(namespace: namespace, original: "sample tag")
            }
        } else {
            let key = try TagTranslationKey(namespace: namespace, original: "sample tag")
            #expect(TagTranslationPresentation.searchTerms(for: key) == namespace + ":sample tag")
        }
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func missingNamespaceUsesTagFallback(_ namespace: String?) {
        for mode in TagTranslationDisplayMode.allCases {
            let label = DetailTagNamespacePresentation(namespace: namespace, mode: mode)
            #expect(label.text == "标签")
            #expect(label.accessibilityLabel == "标签")
        }
    }

    @Test(arguments: ["future", "Artist", " artist ", "<future>"])
    func unknownNamespacesRemainIdentifiableWithoutBecomingSearchKeys(_ namespace: String) {
        #expect(DetailTagNamespacePresentation(namespace: namespace, mode: .original).text == namespace)
        #expect(DetailTagNamespacePresentation(namespace: namespace, mode: .translated).text == "其他")
        #expect(DetailTagNamespacePresentation(namespace: namespace, mode: .both).text == "其他（" + namespace + "）")
        for mode in TagTranslationDisplayMode.allCases {
            #expect(DetailTagNamespacePresentation(namespace: namespace, mode: mode).accessibilityLabel.contains(namespace))
        }
        #expect(throws: TagTranslationError.invalidKey) {
            try TagTranslationKey(namespace: namespace, original: "sample tag")
        }
    }

    @Test func accessibilityExpandsCosplayerAbbreviation() {
        #expect(DetailTagNamespacePresentation(namespace: "cosplayer", mode: .original).accessibilityLabel == "cosplayer")
        #expect(DetailTagNamespacePresentation(namespace: "cosplayer", mode: .translated).accessibilityLabel == "角色扮演者")
        #expect(DetailTagNamespacePresentation(namespace: "cosplayer", mode: .both).accessibilityLabel == "角色扮演者（cosplayer）")
    }
}
